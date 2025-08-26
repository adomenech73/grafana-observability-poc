#!/bin/bash

# Create kind cluster if not exists
if ! kind get clusters | grep -q "petclinic-kind"; then
    echo "Creating kind cluster..."
    kind create cluster --name petclinic-kind --config kind-config.yaml
fi

# Set context
kubectl config use-context kind-petclinic-kind

# Create namespace
kubectl create namespace spring-petclinic --dry-run=client -o yaml | kubectl apply -f -

# Build and push images to kind (optional - if you want to use local builds)
# ./build-and-load-to-kind.sh

# Install Helm chart
helm upgrade --install spring-petclinic . \
  --namespace spring-petclinic \
  --set global.kind.useHostPorts=true \
  --set api-gateway.serviceType=NodePort \
  --set admin-server.serviceType=NodePort \
  --wait \
  --timeout 10m

# Wait for all pods to be ready
echo "Waiting for all pods to be ready..."
kubectl wait --for=condition=Ready pods --all -n spring-petclinic --timeout=300s

# Print access information
echo ""
echo "=== Spring PetClinic Microservices Deployment Complete ==="
echo "API Gateway: http://localhost:30080"
echo "Admin Server: http://localhost:30081"
echo "Discovery Server: http://localhost:30000 (if enabled)"
echo ""
echo "To check status: kubectl get all -n spring-petclinic"
echo "To view logs: kubectl logs -f deployment/<service-name> -n spring-petclinic"
