#!/bin/bash
set -e

echo "==> Step 1: Build images with Podman"
podman build -t headroom-proxy:latest ./proxy
podman build -t headroom-gui:latest ./gui

echo "==> Step 2: Find kind cluster name"
KIND_CLUSTER=$(kind get clusters 2>/dev/null | head -1)
if [ -z "$KIND_CLUSTER" ]; then
  echo "No kind cluster found. Using podman machine ssh method."
  USE_KIND=false
else
  echo "Found kind cluster: $KIND_CLUSTER"
  USE_KIND=true
fi

echo "==> Step 3: Load images into Kubernetes node"
if [ "$USE_KIND" = true ]; then
  podman save headroom-proxy:latest -o /tmp/headroom-proxy.tar
  podman save headroom-gui:latest   -o /tmp/headroom-gui.tar
  kind load image-archive /tmp/headroom-proxy.tar --name "$KIND_CLUSTER"
  kind load image-archive /tmp/headroom-gui.tar   --name "$KIND_CLUSTER"
  echo "Images loaded into kind cluster: $KIND_CLUSTER"
else
  podman save headroom-proxy:latest -o /tmp/headroom-proxy.tar
  podman save headroom-gui:latest   -o /tmp/headroom-gui.tar
  podman machine ssh -- "sudo ctr -n k8s.io images import /tmp/headroom-proxy.tar" || \
  podman machine ssh -- "sudo crictl -r unix:///run/containerd/containerd.sock images import /tmp/headroom-proxy.tar"
  podman machine ssh -- "sudo ctr -n k8s.io images import /tmp/headroom-gui.tar" || \
  podman machine ssh -- "sudo crictl -r unix:///run/containerd/containerd.sock images import /tmp/headroom-gui.tar"
fi

echo "==> Step 4: Apply Kubernetes manifests"
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/proxy-deployment.yaml
kubectl apply -f k8s/proxy-service.yaml
kubectl apply -f k8s/gui-deployment.yaml
kubectl apply -f k8s/gui-service.yaml

echo "==> Step 5: Wait for pods to be ready"
kubectl rollout status deployment/headroom-proxy -n headroom --timeout=120s
kubectl rollout status deployment/headroom-gui   -n headroom --timeout=120s

echo ""
echo "==> Done! All pods running."
kubectl get all -n headroom

echo ""
echo "==> To access the GUI, run in a new terminal:"
echo "    kubectl port-forward -n headroom svc/headroom-proxy 8787:8787 &"
echo "    kubectl port-forward -n headroom svc/headroom-gui   3000:80"
echo "    Then open: http://localhost:3000"
