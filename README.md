# OpenTelemetry POC

![Components diagram](diagram.png)

## Create the environment: the lazy mode

```bash
./setup_environment.sh
```

After installation, you can access the following observability consoles:
- Elasticsearch: https://elasticsearch.localhost/
- Kibana: https://kibana.localhost/
- Grafana: https://grafana.localhost/
- Pyroscope: https://pyroscope.localhost
- Prometheus: https://prometheus.localhost
- AlertManager: https://alertmanager.localhost

To monitor the Kind cluster:

```bash
k9s --context kind-kind
```

## Create the environment: Step-by-Step mode

### Start local docker images registry

```bash
docker run -d -p 5000:5000 --restart=always --name registry registry:2
```

### Cluster creation

- Install requirements

```bash
brew install kind kubectl helm k9s
```

- Create Kind cluster

```bash
kind create cluster --config kind-config.yaml
```

- Install metrics server

```bash
# metrics server installation
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml --context kind-kind
# patch to work with Kind
kubectl patch deployment metrics-server -n kube-system --type 'json' -p '[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]' --context kind-kind
# verify
kubectl get pods -n kube-system | grep metrics-server
```

- Monitor Kind cluster

```bash
k9s --context kind-kind
```

- Install NGINX ingress conttroller

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/kind/deploy.yaml --context kind-kind
```

### Component Installation

#### Install CertManager:

- [CertManager](https://artifacthub.io/packages/helm/cert-manager/cert-manager)

```bash
# add the official repo
helm repo add jetstack https://charts.jetstack.io
helm repo update
# Install cert-manager
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.16.2 \
  -f values-certmanager.yaml \
  --kube-context kind-kind
```

Create a self-signed ClusterIssuer

```bash
kubectl apply -f cluster-issuer.yaml --context kind-kind
```

#### Install ElasticSearch & Kibana (Logs aggregation & visualization):

- [ElasticSearch](https://artifacthub.io/packages/helm/elastic/elasticsearch)
- [Kibana](https://artifacthub.io/packages/helm/elastic/kibana)

```bash
# add the official repo
helm repo add elastic https://helm.elastic.co
helm repo update
# Install elasticsearch
helm upgrade --install elasticsearch elastic/elasticsearch \
  --namespace logging \
  --create-namespace \
  --version 7.17.3 \
  --values values-elasticsearch.yaml \
  --kube-context kind-kind

# Install Kibana
helm upgrade --install kibana elastic/kibana \
  --namespace logging \
  --create-namespace \
  --version 7.17.3 \
  --values values-kibana.yaml \
  --kube-context kind-kind
```

Configure index patterns

```bash
# Composable index template
curl -X PUT "http://elasticsearch.localhost/_index_template/fluentbit-logs-template" \
-H "Content-Type: application/json" \
-d '{
  "index_patterns": ["fluentbit-*"],
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
        // Add other fields based on your log structure
      }
    }
  },
  "composed_of": [],
  "priority": 100,
  "data_stream": {}
}'
```

#### Install Fluentd (Logs collector agent):

- [Fluentd](https://artifacthub.io/packages/helm/fluent/fluentd)

```bash
# add the official repo
helm repo add fluent https://fluent.github.io/helm-charts
helm repo update
# InstallFluentd
helm upgrade --install fluentd fluent/fluentd \
  --namespace logging \
  --create-namespace \
  --version 0.5.2 \
  --values values-fluentd.yaml \
  --kube-context kind-kind
```

#### Install Tempo & Pyroscope (Tracing & Continous profiling):

- [Tempo](https://artifacthub.io/packages/helm/grafana/tempo)
- [Pyroscope](https://artifacthub.io/packages/helm/grafana/pyroscope)

```bash
# add the official repo
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
# install tempo
helm upgrade --install tempo grafana/tempo \
  --namespace observability \
  --create-namespace \
  --version 1.16.0 \
  --values values-tempo.yaml \
  --kube-context kind-kind
# install pyroscope
helm upgrade --install pyroscope grafana/pyroscope \
  --namespace observability \
  --create-namespace \
  --version 1.10.0 \
  --values values-pyroscope.yaml \
  --kube-context kind-kind
```


#### Install Prometheus, Alertmanager & Grafana (Metrics storage, alerting & visualization)

- [Prometheus Stack](https://artifacthub.io/packages/helm/prometheus-community/kube-prometheus-stack)

```bash
# add the official repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
# Install Promehteus
helm upgrade --install prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --version 67.4.0 \
  --values values-prometheus.yaml \
  --kube-context kind-kind
```

#### Install Opentelemetry Operator

- [OpenTelemetry Operattor](https://artifacthub.io/packages/helm/opentelemetry-helm/opentelemetry-operator)

```bash
# add the official repo
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
# Install OpenTelemetry Operator
helm upgrade --install opentelemetry open-telemetry/opentelemetry-operator \
  --namespace observability \
  --create-namespace \
  --version 0.75.1 \
  --values values-opentelemetry.yaml \
  --kube-context kind-kind
```

Create OpenTelemetry Collector:

```bash
kubectl apply -f otel-collector.yaml --context kind-kind
```

### Deploy example test services

```bash
cd spring-petclinic-microservices/
./mvnw clean install -P buildDocker
export REPOSITORY_PREFIX=localhost:5000
export VERSION=3.2.7
./scripts/tagImages.sh
./scripts/pushImages.sh
```

```bash
git remote add petclinicfork https://github.com/adomenech73/spring-petclinic-microservices 
git push petclinicfork otel-poc
```

## Clean-up

```bash
kind delete cluster
```
