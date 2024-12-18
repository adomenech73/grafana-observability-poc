# OpenTelemetry POC

## The lazy mode

```bash
./setup.sh
```

At the end of the script execution sevaral consoles should be available

- [ElasticSearch](http://elasticsearch.localhost/)
- [Kibana](http://kibana.localhost/)
- [Grafana](http://grafana.localhost/)
- [Jaeger](http://jaeger.localhost/)

## Step-by-Step mode

### Cluster creation

- Install requirements

```bash
brew install kind kubectl helm go k9s
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

### Requirements setup

- [CertManager](https://artifacthub.io/packages/helm/cert-manager/cert-manager)

Installation

```bash
# add the official repo
helm repo add jetstack https://charts.jetstack.io
helm repo update
# Install cert-manager
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.16.2 \
  --set installCRDs=true \
  --kube-context kind-kind
```

Create a self-signed ClusterIssuer

```bash
kubectl apply -f cluster-issuer.yaml --context kind-kind
```

- [ElasticSearch](https://artifacthub.io/packages/helm/elastic/elasticsearch)

Installation

```bash
# add the official repo
helm repo add elastic https://helm.elastic.co
helm repo update
# Install elasticsearch
helm install elasticsearch elastic/elasticsearch \
    --namespace elastic-stack \
    --create-namespace \
    --version 7.17.3 \
    --values values-elasticsearch.yaml \
    --kube-context kind-kind
# Install Kibana
helm install kibana elastic/kibana \
  --version 7.17.3 \
  --namespace elastic-stack \
  --create-namespace \
  --values values-kibana.yaml \
  --kube-context kind-kind
```

Configure index patterns

- Logs index pattern

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

- Jaeger span index pattern

```bash
# Composable index template
curl -X PUT "http://elasticsearch.localhost/_index_template/jaeger_template" \
-H "Content-Type: application/json" \
-d '{
  "index_patterns": ["jaeger-span-*"],
  "template": {
    "mappings": {
      "dynamic": true,
      "properties": {
        "startTimeMillis": {
          "type": "date"
        }
        // Add other field mappings as needed
      }
    }
  }
}'
```

```bash
kubectl exec -it elasticsearch-master-0 \
    -n elastic-stack --context kind-kind \
    -- curl -X GET "localhost:9200/_cat/indices?v"
```

- [Prometheus](https://artifacthub.io/packages/helm/prometheus-community/prometheus)

Installation

```bash
# add the official repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
# Install Promehteus
helm install prometheus prometheus-community/prometheus \
  --namespace monitoring \
  --create-namespace \
  --version 26.0.0 \
  --set server.persistentVolume.enabled=false \
  --set alertmanager.persistentVolume.enabled=false \
  --kube-context kind-kind
```

- [Grafana](https://artifacthub.io/packages/helm/grafana/grafana)

Installation

```bash
# add the official repo
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
# Install Grafana
helm install grafana grafana/grafana \
    --namespace monitoring \
    --version 8.6.4 \
    --values values-grafana.yaml \
    --kube-context kind-kind
```

- [Jaeger Operator](https://artifacthub.io/packages/helm/jaegertracing/jaeger-operator)

Installation

```bash
# add the official repo
helm repo add jaegertracing https://jaegertracing.github.io/helm-charts
helm repo update
# Install Jaeger Operator
helm install jaeger-operator jaegertracing/jaeger-operator \
  --namespace observability \
  --create-namespace \
  --version 2.57.0 \
  --values values-jaeger.yaml \
  --kube-context kind-kind
```

Create Jaeger instance

```bash
# Give Jaeger Operator RBAC permits
kubectl apply -f jaeger-operator-rbac.yaml --context kind-kind
# Create Jeger Instance
kubectl apply -f jaeger-instance.yaml --context kind-kind
```

### Deploy example test services

```bash
./mvnw clean install -P buildDocker
export REPOSITORY_PREFIX=localhost:5000
export VERSION=3.2.7
./scripts/tagImages.sh
./scripts/pushImages.sh
```

### OpenTelemetry components setup

## Clean-up

```bash
kind delete cluster
```
