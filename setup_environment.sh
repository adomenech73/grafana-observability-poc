#!/bin/bash

set -e  # Exit immediately if a command exits with a non-zero status

# Define ANSI escape codes for bold text
BOLD=$(tput bold)
NORMAL=$(tput sgr0)  # Reset to normal
# Define ANSI escape codes for red text
REDC='\033[0;31m'
NORMALC='\033[0m'
# Versions
VERSION_CERTMANAGER=v1.16.2
VERSION_ELASTICSEARCH=7.17.3
VERSION_KIBANA=7.17.3
VERSION_FLUENTD=0.5.2
VERSION_JAEGER=2.57.0
VERSION_PROMETHEUS=26.0.0
VERSION_TEMPO=1.16.0
VERSION_PARCA=4.19.0
VERSION_OTEL_COLLECTOR=0.110.7
VERSION_GRAFANA=8.6.4

# Function to check if the local registry is already running
check_registry_running() {
  if docker ps -a | grep -q "local-registry"; then
    return 0 # Registry is already running
  else
    return 1 # Registry is not running
  fi
}

# Function to check OCI resgistry
check_registry_health() {
    local max_retries=30
    local count=0
    while ! curl -s http://localhost:5000/v2/ > /dev/null
    do
        sleep 1
        count=$((count+1))
        if [ $count -eq $max_retries ]; then
            echo "Failed to start local registry after $max_retries attempts"
            return 1
        fi
    done
    echo "Local registry is up and running"
    return 0
}

# Function to check and install brew packages
check_and_install_brew() {
    for package in "$@"; do
        if brew list -1 | grep -q "^${package}\$"; then
            echo "$package is already installed."
        else
            echo "Installing $package..."
            brew install "$package"
        fi
    done
}

# Function to check and add helm repositories
check_and_add_helm_repo() {
    local repo_name=$1
    local repo_url=$2

    if helm repo list | grep -q "^${repo_name}"; then
        echo "Helm repo $repo_name is already added."
    else
        echo "Adding Helm repo $repo_name..."
        helm repo add "$repo_name" "$repo_url"
    fi
}

# Set up a local OCI registry:
if ! check_registry_running; then
  echo "${BOLD}Seting-up local OCI registry...${NORMAL}"
  docker run -d -p 5000:5000 --name local-registry registry:2
fi

if check_registry_health; then
    echo "Registry setup successful"
else
    echo "${REDC}Registry setup failed${NORMALC}"
    exit 1
fi

# Function to check if a Kind cluster exists
check_kind_cluster() {
  local cluster_name=$1
  if kind get clusters | grep -q "$cluster_name"; then
    return 0 # Cluster exists
  else
    return 1 # Cluster does not exist
  fi
}

# Function to check if a Kubernetes resource exists and is in a specific state
check_for_resource() {
    local resource_type=$1
    local resource_name=$2
    local namespace=$3
    local state=$4

    if kubectl get "$resource_type" "$resource_name" -n "$namespace" --output=jsonpath='{.metadata.name}' &> /dev/null; then
        if [ -n "$state" ]; then
            # Check if the resource is in the specified state
            if kubectl get "$resource_type" "$resource_name" -n "$namespace" --output=jsonpath='{.status.conditions[?(@.type=="'"$state"'")].status}' &> /dev/null | grep -q "True"; then
                return 0 # Resource exists and is in the specified state
            else
                return 1 # Resource exists but is not in the specified state
            fi
        else
            return 0 # Resource exists, no state check
        fi
    else
        return 1 # Resource does not exist
    fi
}

# Function to wait for a Kubernetes resource to be ready
wait_for_resource() {
    local resource_type=$1
    local resource_name=$2
    local namespace=$3
    local state=$4
    # pod,node,sts:ready, deployment:available
    local timeout=${5:-300}  # Default timeout is 300 seconds

    echo "${BOLD}$(date '+%H:%M:%S') - Waiting for $resource_type $resource_name in namespace $namespace to be ready...${NORMAL}"
    if ! kubectl wait --for=condition="$state" "$resource_type/$resource_name" -n "$namespace" --timeout="${timeout}s"; then
        echo "${REDC}Failed to wait for $resource_type $resource_name in namespace $namespace.${NORMALC}"
        exit 1
    fi
}

# Function to create an index template and validate the response, only if it does not exist
create_index_template() {
  local template_name=$1
  local json_data=$2

  # Check if the index template already exists
  if curl -s -o /dev/null -w "%{http_code}" -X HEAD "http://elasticsearch.localhost/_index_template/$template_name"; then
    echo "Index template $template_name already exists."
    return 0
  fi

  echo "Creating index template: $template_name..."
  response=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "http://elasticsearch.localhost/_index_template/$template_name" \
    -H "Content-Type: application/json" \
    -d "$json_data")

  if [ "$response" -eq 200 ]; then
    echo "Index template $template_name created successfully."
    return 0
  else
    echo "${REDC}Failed to create index template $template_name. HTTP status code: $response${NORMALC}"
    return 1
  fi
}


#-------------------------------------------------MAIN-------------------------------------------------------

# Install requirements
echo "${BOLD}Installing requirements...${NORMAL}"
check_and_install_brew kind kubernetes-cli helm go k9s

# Requirements setup: Add Helm repositories at once and update them later.
echo "${BOLD}Setting up Helm repositories...${NORMAL}"

check_and_add_helm_repo jetstack https://charts.jetstack.io
check_and_add_helm_repo elastic https://helm.elastic.co
check_and_add_helm_repo fluent https://fluent.github.io/helm-charts
check_and_add_helm_repo prometheus-community https://prometheus-community.github.io/helm-charts
check_and_add_helm_repo grafana https://grafana.github.io/helm-charts
check_and_add_helm_repo jaegertracing https://jaegertracing.github.io/helm-charts
check_and_add_helm_repo parca https://parca-dev.github.io/helm-charts
check_and_add_helm_repo open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts

# Update all Helm repositories once after adding them.
echo "${BOLD}Updating Helm repositories...${NORMAL}"
helm repo update

# Create Kind cluster
echo "${BOLD}Creating Kind cluster...${NORMAL}"
if ! check_kind_cluster "kind"; then
  kind create cluster --config kind-config.yaml
  echo "Kind cluster created successfully."
else
  echo "Kind cluster already exists."
fi

# Check if Kind cluster exists
echo "Checking for Kind clusters..."
kind_clusters=$(kind get clusters)
if [[ -z "$kind_clusters" ]]; then
    echo "No Kind clusters found."
    exit 1
else
    echo "Found Kind clusters: $kind_clusters"
fi

# Install metrics server
if ! check_for_resource deployment metrics-server kube-system available; then
  echo "${BOLD}Installing metrics server...${NORMAL}"
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml --context kind-kind
  kubectl patch deployment metrics-server -n kube-system --type 'json' -p '[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]' --context kind-kind
fi
wait_for_resource deployment metrics-server kube-system available

# Monitor Kind cluster (optional)
echo "${BOLD}Now you can monitor the Kind cluster using k9s.${NORMAL}"
# Uncomment the following line if you want to automatically start k9s
# k9s --context kind-kind
# kubectl get events --sort-by='.metadata.creationTimestamp' -A -o wide -w --context kind-kind

# Install NGINX ingress controller
if ! check_for_resource job ingress-nginx-admission-patch ingress-nginx complete; then
  echo "${BOLD}Installing NGINX ingress controller...${NORMAL}"
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/kind/deploy.yaml --context kind-kind
fi
wait_for_resource deployment ingress-nginx-controller ingress-nginx available
wait_for_resource job ingress-nginx-admission-create ingress-nginx complete
wait_for_resource job ingress-nginx-admission-patch ingress-nginx complete

# Install CertManager
if ! check_for_resource deployment cert-manager-webhook cert-manager available; then
  echo "${BOLD}Installing CertManager...${NORMAL}"
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version "${VERSION_CERTMANAGER}" \
    --set installCRDs=true \
    --kube-context kind-kind
fi
wait_for_resource deployment cert-manager cert-manager available
wait_for_resource deployment cert-manager-cainjector cert-manager available
wait_for_resource deployment cert-manager-webhook cert-manager available

# Create self-signed ClusterIssuer
if ! check_for_resource ClusterIssuer selfsigned-cluster-issuer cert-manager ready; then
  echo "${BOLD}Creating self-signed ClusterIssuer...${NORMAL}"
  kubectl apply -f cluster-issuer.yaml --context kind-kind
fi
wait_for_resource ClusterIssuer selfsigned-cluster-issuer cert-manager ready

# Create Certificates
if ! check_for_resource Certificate jaeger-certs observability ready; then
  echo "${BOLD}Creating Certificates...${NORMAL}"
  kubectl apply -f certificates.yaml --context kind-kind
fi
wait_for_resource Certificate elasticsearch-certs elastic-stack ready
wait_for_resource Certificate kibana-certs elastic-stack ready
wait_for_resource Certificate fluentd-certs logging ready
wait_for_resource Certificate prometheus-certs monitoring ready
wait_for_resource Certificate grafana-certs monitoring ready
wait_for_resource Certificate jaeger-certs observability ready

# Paralel installation of Elastic, Kibana and Fluentd
if ! check_for_resource pod fluentd logging ready; then
  # Install Elasticsearch
  echo "${BOLD}Installing Elasticsearch...${NORMAL}"
  helm upgrade --install elasticsearch elastic/elasticsearch \
    --namespace elastic-stack \
    --create-namespace \
    --version "${VERSION_ELASTICSEARCH}" \
    --values values-elasticsearch.yaml \
    --kube-context kind-kind &  # Run in the background

  # Store the PID of the Elasticsearch installation
  elasticsearch_pid=$!

  # Install Kibana
  echo "${BOLD}Installing Kibana...${NORMAL}"
  helm upgrade --install kibana elastic/kibana \
    --namespace elastic-stack \
    --create-namespace \
    --version "${VERSION_KIBANA}" \
    --values values-kibana.yaml \
    --kube-context kind-kind &  # Run in the background

  # Store the PID of the Kibana installation
  kibana_pid=$!

  # Install Fluentd
  echo "${BOLD}Installing Fluentd...${NORMAL}"
  helm upgrade --install fluentd fluent/fluentd \
    --namespace logging \
    --create-namespace \
    --version "${VERSION_FLUENTD}" \
    --values values-fluentd.yaml \
    --kube-context kind-kind &

  # Store the PID of the Fluentd installation
  fluentd_pid=$!

  # Wait for both installations to complete
  wait $elasticsearch_pid
  wait $kibana_pid
  wait $fluentd_pid
fi
# Wait for Elasticsearch to be ready
wait_for_resource pod elasticsearch-master-0 elastic-stack ready 1500
# Wait for Kibana to be available
wait_for_resource deployment kibana-kibana elastic-stack available 1500


# Configure index patterns for Fluent Bit logs and Jaeger spans with validation.
fluentbit_template='{
  "index_patterns": [
    "fluentbit-*"
  ],
  "template": {
    "mappings": {
      "dynamic": true,
      "properties": {
        "@timestamp": {
          "type": "date"
        },
        "log": {
          "type": "text"
        },
        "service": {
          "type": "keyword"
        }
      }
    }
  }
}'

jaeger_template='{
  "index_patterns": [
    "jaeger-span-*"
  ],
  "template": {
    "mappings": {
      "dynamic": true,
      "properties": {
        "startTimeMillis": {
          "type": "date"
        }
      }
    }
  }
}'

create_index_template fluentbit-logs-template "$fluentbit_template"
create_index_template jaeger_template "$jaeger_template"

# Install Jaeger Operator
if ! check_for_resource deployment jaeger-operator observability available; then
  echo "${BOLD}Installing Jaeger Operator...${NORMAL}"
  helm upgrade --install jaeger-operator jaegertracing/jaeger-operator \
    --namespace observability \
    --create-namespace \
    --version "${VERSION_JAEGER}" \
    --values values-jaeger.yaml \
    --kube-context kind-kind
fi
# Wait for jaeger-operator to be available
wait_for_resource deployment jaeger-operator observability available

# Create Jaeger instance and RBAC permits
if ! check_for_resource deployment jaeger-query observability available; then
  echo "${BOLD}Creating Jaeger instance and RBAC permits...${NORMAL}"
  kubectl apply -f jaeger-operator-rbac.yaml --context kind-kind

  # Wait for jaeger-operator-webhook-service to be available
  #wait_for_resource service jaeger-operator-webhook-service observability available
  sleep 5

  kubectl apply -f jaeger-instance.yaml --context kind-kind
  sleep 10
fi
wait_for_resource deployment jaeger-collector observability available
wait_for_resource deployment jaeger-query observability available

# Paralel Installation of Prometheus and Grafana
if ! check_for_resource deployment grafana monitoring available; then
  # Install Prometheus
  echo "${BOLD}Installing Prometheus...${NORMAL}"
  helm upgrade --install prometheus prometheus-community/prometheus \
    --namespace monitoring \
    --create-namespace \
    --version "${VERSION_PROMETHEUS}" \
    --values values-prometheus.yaml
    --kube-context kind-kind &  # Run in the background

  # Store the PID of the Promehteus installation
  prometheus_pid=$!

  # Install Tempo
  echo "${BOLD}Installing Tempo...${NORMAL}"
  helm upgrade --install tempo grafana/tempo \
    --namespace observability 
    --create-namespace 
    --version "${VERSION_TEMPO}"
    --values values-tempo.yaml
    --kube-context kind-kind &

  # Store the PID of the Tempo installation
  tempo_pid=$!

  # Install Parca
  echo "${BOLD}Installing Parca...${NORMAL}"
  helm upgrade --install parca parca/parca \
    --namespace observability \
    --create-namespace \
    --version ${VERSION_PARCA} \
    --values values-parca.yaml \
    --kube-context kind-kind &

    # Store the PID of the Tempo installation
    parca_pid=$!

  # Install OpenTelemetry Collector
  echo "${BOLD}Installing OpenTelemetry Collector...${NORMAL}"
  helm upgrade --install opentelemetry open-telemetry/opentelemetry-collector \
    --namespace observability \
    --create-namespace \
    --version "${VERSION_OTEL_COLLECTOR}" \
    --values values-otel-collector.yaml \
    --kube-context kind-kind & # Run in the background

  # Store the PID of the OpenTelemetry Collector installation
  otel_collector_pid=$!

  # Install Grafana
  echo "${BOLD}Installing Grafana...${NORMAL}"
  helm upgrade --install grafana grafana/grafana \
    --namespace monitoring \
    --create-namespace \
    --version "${VERSION_GRAFANA}" \
    --values values-grafana.yaml \
    --kube-context kind-kind &  # Run in the background

  # Store the PID of the Grafana installation
  grafana_pid=$!

  sleep 2

  # Wait for all installations to complete
  wait $promehteus_pid
  wait $tempo_pid
  wait $parca_pid
  wait $otel_collector_pid
  wait $grafana_pid
fi
# Wait for kube-state-metrics to be available
wait_for_resource deployment prometheus-kube-state-metrics monitoring available
# Wait for prometheus-pushgateway to be available
wait_for_resource deployment prometheus-prometheus-pushgateway monitoring available
# Wait for prometheus-server to be available
wait_for_resource deployment prometheus-server monitoring available
# Wait for AlertManager to be ready
wait_for_resource pod prometheus-alertmanager-0 monitoring ready
# wait for tempo to be available
wait_for_resource pod tempo-0 observability ready
# Wait for parca to be available
wait_for_resource deployment parca observability available
# Wait for OpenTelemetry Collector to be available
wait_for_resource deployment opentelemetry-collector observability available
# Wait for grafana to be available
wait_for_resource deployment grafana monitoring available


echo "${BOLD}All components have been installed and configured successfully!${NORMAL}"
