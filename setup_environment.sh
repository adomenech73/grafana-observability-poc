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
VERSION_PROMETHEUS=67.4.0
VERSION_TEMPO=1.16.0
VERSION_PYROSCOPE=1.10.0
VERSION_OPENTELEMETRY=0.75.1

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
  if curl -k -s -o /dev/null -w "%{http_code}" -X HEAD "https://elasticsearch.localhost/_index_template/$template_name"; then
    echo "Index template $template_name already exists."
    return 0
  fi

  echo "Creating index template: $template_name..."
  response=$(curl -k -s -o /dev/null -w "%{http_code}" -X PUT "https://elasticsearch.localhost/_index_template/$template_name" \
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
# Run a local Docker registry for OCI images if it doesn't exist
if ! check_registry_running; then
  echo "Starting local Docker registry..."
  docker run -d -p 5000:5000 --restart=always --name local-registry registry:2
else
  echo "Local Docker registry is already running."
fi

# Install requirements
echo "${BOLD}Installing requirements...${NORMAL}"
check_and_install_brew kind kubernetes-cli helm go k9s

# Requirements setup: Add Helm repositories at once and update them later.
echo "${BOLD}Setting up Helm repositories...${NORMAL}"

check_and_add_helm_repo jetstack https://charts.jetstack.io
check_and_add_helm_repo minio-operator https://operator.min.io
check_and_add_helm_repo elastic https://helm.elastic.co
check_and_add_helm_repo fluent https://fluent.github.io/helm-charts
check_and_add_helm_repo prometheus-community https://prometheus-community.github.io/helm-charts
check_and_add_helm_repo grafana https://grafana.github.io/helm-charts
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

# installation of CertManager
if ! check_for_resource deployment cert-manager-webhook cert-manager; then
  echo "${BOLD}Installing CertManager...${NORMAL}"
  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version "${VERSION_CERTMANAGER}" \
    -f values-certmanager.yaml \
    --kube-context kind-kind
fi

wait_for_resource deployment cert-manager cert-manager available
wait_for_resource deployment cert-manager-cainjector cert-manager available
wait_for_resource deployment cert-manager-webhook cert-manager available

# Provision CertManager elements
# Create self-signed ClusterIssuer
if ! check_for_resource ClusterIssuer selfsigned-cluster-issuer cert-manager ready; then
  echo "${BOLD}Creating self-signed ClusterIssuer...${NORMAL}"
  kubectl apply -f cluster-issuer.yaml --context kind-kind
fi
wait_for_resource ClusterIssuer selfsigned-cluster-issuer cert-manager ready

# Paralel installation of Elastic, Kibana and Fluentd
if ! check_for_resource pod fluentd logging ready; then
  # Install Elasticsearch
  echo "${BOLD}Installing Elasticsearch...${NORMAL}"
  helm upgrade --install elasticsearch elastic/elasticsearch \
    --namespace logging \
    --create-namespace \
    --version "${VERSION_ELASTICSEARCH}" \
    --values values-elasticsearch.yaml \
    --kube-context kind-kind &  # Run in the background

  # Store the PID of the Elasticsearch installation
  elasticsearch_pid=$!

  # Install Kibana
  echo "${BOLD}Installing Kibana...${NORMAL}"
  helm upgrade --install kibana elastic/kibana \
    --namespace logging \
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
wait_for_resource pod elasticsearch-master-0 logging ready 1500
# Wait for Kibana to be available
wait_for_resource deployment kibana-kibana logging available 1500

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

create_index_template fluentbit-logs-template "$fluentbit_template"

# Paralel Installation of Tempo and Parca
if ! check_for_resource pod pyroscope-0 observability ready; then
  # Install Tempo
  echo "${BOLD}Installing Tempo...${NORMAL}"
  helm upgrade --install tempo grafana/tempo \
    --namespace observability \
    --create-namespace \
    --version "${VERSION_TEMPO}" \
    --values values-tempo.yaml \
    --kube-context kind-kind &

  # Store the PID of the Tempo installation
  tempo_pid=$!

  # Install Pyroscope
  echo "${BOLD}Installing Pyroscope...${NORMAL}"
  helm upgrade --install pyroscope grafana/pyroscope \
    --namespace observability \
    --create-namespace \
    --version ${VERSION_PYROSCOPE} \
    --values values-pyroscope.yaml \
    --kube-context kind-kind &

    # Store the PID of the Tempo installation
    pyroscope_pid=$!

  sleep 5

  # Wait for all installations to complete
  wait $tempo_pid
  wait $pyroscope_pid
fi
# wait for tempo to be available
wait_for_resource pod tempo-0 observability ready
# Wait for pyroscope to be available
wait_for_resource pod pyroscope-alloy-0 observability ready
wait_for_resource pod pyroscope-0 observability ready

# Installation of kube-prometheus-stack
echo "${BOLD}Installing Prometheus Stack...${NORMAL}"
helm upgrade --install prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --version "${VERSION_PROMETHEUS}" \
  --values values-prometheus.yaml \
  --kube-context kind-kind
# Wait for prometheus-operator to be available
wait_for_resource deployment prometheus-stack-kube-prom-operator monitoring available
# Wait for kube-state-metrics to be available
wait_for_resource deployment prometheus-stack-kube-state-metrics monitoring available
# Wait for grafana to be available
wait_for_resource deployment prometheus-stack-grafana monitoring available
# Wait for AlertManager to be ready
wait_for_resource pod alertmanager-prometheus-stack-kube-prom-alertmanager-0 monitoring ready
# Wait for Prometheus operated to be ready
wait_for_resource pod prometheus-prometheus-stack-kube-prom-prometheus-0 monitoring ready

# Install OpenTelemetry Operator
echo "${BOLD}Installing OpenTelemetry Operator...${NORMAL}"
helm upgrade --install opentelemetry open-telemetry/opentelemetry-operator \
  --namespace observability \
  --create-namespace \
  --version "${VERSION_OPENTELEMETRY}" \
  --values values-opentelemetry.yaml \
  --kube-context kind-kind

# Wait for opentelemetry-operator to be available
wait_for_resource deployment opentelemetry-opentelemetry-operator observability available

if ! check_for_resource deployment opentelemetry-collector observability available; then
  echo "${BOLD}Creating OpenTelemetry Collector...${NORMAL}"
  kubectl apply -f otel-collector.yaml --context kind-kind
fi

echo "${BOLD}All components have been installed and configured successfully!${NORMAL}"
