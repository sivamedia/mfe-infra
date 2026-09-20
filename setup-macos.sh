#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# MFE Infrastructure Setup - macOS Tahoe
#
# Run from mfe-infra:
#
#   ./setup-macos.sh
#
# ============================================================

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$INFRA_ROOT/.." && pwd)"
K8S_ROOT="$INFRA_ROOT/k8s"

APPS=("orders" "products" "shell" "users")

INGRESS_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.13.3/deploy/static/provider/cloud/deploy.yaml"

IMAGE_NAMES=(
    "mfe-shell:1.0"
    "mfe-users:1.0"
    "mfe-products:1.0"
    "mfe-orders:1.0"
)

APP_NAMES=(
    "shell"
    "users"
    "products"
    "orders"
)

log() {
    echo
    echo "============================================================"
    echo "=== $1"
    echo "============================================================"
}

fail() {
    echo
    echo "ERROR: $1" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || \
        fail "$1 was not found. Install it first."
}

wait_for_docker() {
    for i in $(seq 1 60); do
        if docker info >/dev/null 2>&1; then
            echo "Docker Engine is ready."
            return
        fi

        echo "Waiting for Docker Engine... ($i/60)"
        sleep 2
    done

    fail "Docker Engine did not become ready within 2 minutes."
}

wait_for_kubernetes() {
    for i in $(seq 1 60); do
        if kubectl get nodes --no-headers >/tmp/mfe_nodes 2>/dev/null; then
            if grep -Eq '[[:space:]]Ready([[:space:]]|$)' /tmp/mfe_nodes; then
                rm -f /tmp/mfe_nodes
                echo "Kubernetes is ready."
                kubectl get nodes
                return
            fi
        fi

        echo "Waiting for Kubernetes... ($i/60)"
        sleep 2
    done

    rm -f /tmp/mfe_nodes
    fail "Kubernetes did not become Ready within 2 minutes."
}

wait_for_ingress_admission() {
    log "Waiting for ingress admission webhook"

    local admission_ip=""

    for i in $(seq 1 60); do
        admission_ip="$(
            kubectl get endpointslice \
                -n ingress-nginx \
                -l kubernetes.io/service-name=ingress-nginx-controller-admission \
                -o jsonpath='{.items[0].endpoints[0].addresses[0]}' \
                2>/dev/null || true
        )"

        if [[ -n "$admission_ip" ]]; then
            echo "Ingress admission webhook is ready: $admission_ip"
            return
        fi

        echo "Waiting for admission webhook... ($i/60)"
        sleep 2
    done

    fail "Ingress admission webhook did not become ready."
}

verify_mfe_images() {
    log "Verifying MFE images in Minikube"

    for image in "${IMAGE_NAMES[@]}"; do
        if ! minikube image ls | grep -Fq "docker.io/library/$image"; then
            fail "MFE image was not found inside Minikube: $image"
        fi

        echo "Found: docker.io/library/$image"
    done
}

add_hosts() {
    local hosts_file="/etc/hosts"

    log "Configuring /etc/hosts"

    local hosts=(
        "mfe.local"
        "products.mfe.local"
        "orders.mfe.local"
        "users.mfe.local"
    )

    local ingress_ip=""

    ingress_ip="$(
        kubectl get svc ingress-nginx-controller \
            -n ingress-nginx \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' \
            2>/dev/null || true
    )"

    if [[ -z "$ingress_ip" ]]; then
        ingress_ip="$(minikube ip)"
        echo "LoadBalancer IP unavailable."
        echo "Using Minikube IP: $ingress_ip"
    else
        echo "Using Ingress LoadBalancer IP: $ingress_ip"
    fi

    for host in "${hosts[@]}"; do
        sudo sed -i '' \
            "/[[:space:]]${host}[[:space:]]*$/d" \
            "$hosts_file"

        echo "$ingress_ip $host" | sudo tee -a "$hosts_file" >/dev/null

        echo "Configured: $ingress_ip $host"
    done
}

# ============================================================
# Prerequisites
# ============================================================

log "Checking prerequisites"

require_cmd docker
require_cmd kubectl
require_cmd minikube
require_cmd sudo

echo "Docker:   $(docker --version)"
echo "kubectl:  $(kubectl version --client 2>/dev/null | head -n 1)"
echo "Minikube: $(minikube version --short 2>/dev/null || true)"

# ============================================================
# Docker Desktop
# ============================================================

log "Starting Docker Desktop"

if [[ ! -d "/Applications/Docker.app" ]]; then
    fail "Docker Desktop was not found at /Applications/Docker.app."
fi

if ! pgrep -x "Docker" >/dev/null 2>&1; then
    echo "Starting Docker Desktop..."
    open -a Docker
fi

wait_for_docker

# ============================================================
# Minikube / Kubernetes
# ============================================================

log "Checking Minikube"

if ! minikube status >/dev/null 2>&1; then
    echo "Minikube is not running."
    echo "Starting Minikube..."

    minikube start --driver=docker
else
    echo "Minikube is already running."
fi

log "Checking Kubernetes"

if ! kubectl get nodes --no-headers >/tmp/mfe_nodes 2>/dev/null; then
    rm -f /tmp/mfe_nodes
    wait_for_kubernetes
else
    if grep -Eq '[[:space:]]Ready([[:space:]]|$)' /tmp/mfe_nodes; then
        echo "Kubernetes is already ready."
        kubectl get nodes
        rm -f /tmp/mfe_nodes
    else
        rm -f /tmp/mfe_nodes
        wait_for_kubernetes
    fi
fi

# ============================================================
# Build Docker images
# ============================================================

log "Building MFE Docker images"

for index in "${!APP_NAMES[@]}"; do

    app="${APP_NAMES[$index]}"
    image="${IMAGE_NAMES[$index]}"

    dockerfile="$PROJECT_ROOT/$app/.dockerFile"
    context="$PROJECT_ROOT/$app"

    [[ -f "$dockerfile" ]] || \
        fail "Dockerfile not found: $dockerfile"

    [[ -d "$context" ]] || \
        fail "Build context not found: $context"

    echo
    echo "Building $image..."

    docker build \
        -f "$dockerfile" \
        -t "$image" \
        "$context"

    echo
    echo "Loading $image into Minikube..."

    minikube image load "$image"

done

# ============================================================
# Verify images
# ============================================================

verify_mfe_images

# ============================================================
# MFE namespace
# ============================================================

log "Creating MFE namespace"

kubectl apply \
    -f "$K8S_ROOT/namespace.yaml"

# ============================================================
# ingress-nginx
# ============================================================

log "Checking ingress-nginx"

if ! kubectl get ingressclass nginx >/dev/null 2>&1; then

    echo "NGINX Ingress controller is not installed."
    echo "Installing..."

    kubectl apply \
        -f "$INGRESS_MANIFEST"

else

    echo "NGINX Ingress controller is already installed."

fi

# ============================================================
# Wait for ingress controller
# ============================================================

log "Waiting for ingress-nginx controller"

kubectl rollout status \
    deployment/ingress-nginx-controller \
    -n ingress-nginx \
    --timeout=180s

# ============================================================
# Wait for admission webhook
# ============================================================

wait_for_ingress_admission

# ============================================================
# MFE deployments
# ============================================================

log "Applying MFE deployments"

for app in "${APPS[@]}"; do

    file="$K8S_ROOT/$app/deployment.yaml"

    [[ -f "$file" ]] || \
        fail "Deployment manifest not found: $file"

    kubectl apply -f "$file"

done

# ============================================================
# MFE services
# ============================================================

log "Applying MFE services"

for app in "${APPS[@]}"; do

    file="$K8S_ROOT/$app/service.yaml"

    [[ -f "$file" ]] || \
        fail "Service manifest not found: $file"

    kubectl apply -f "$file"

done

# ============================================================
# MFE ingress
# ============================================================

log "Applying MFE ingress"

kubectl apply \
    -f "$K8S_ROOT/ingress.yaml"

# ============================================================
# Wait for MFE deployments
# ============================================================

log "Waiting for MFE deployments"

for app in "${APPS[@]}"; do

    kubectl rollout status \
        "deployment/$app" \
        -n mfe \
        --timeout=120s

done

# ============================================================
# Configure hosts
# ============================================================

add_hosts

# ============================================================
# Final status
# ============================================================

log "MFE setup complete"

echo
echo "=== Kubernetes Nodes ==="
kubectl get nodes

echo
echo "=== MFE Pods ==="
kubectl get pods -n mfe

echo
echo "=== MFE Services ==="
kubectl get svc -n mfe

echo
echo "=== MFE Ingress ==="
kubectl get ingress -n mfe

echo
echo "=== Ingress Controller ==="
kubectl get pods -n ingress-nginx

echo
echo "=== Metrics ==="
kubectl top pods -n mfe 2>/dev/null || \
    echo "Metrics not available yet."

cat <<'EOF'

============================================================
MFE URLs
============================================================

Shell:
  http://mfe.local

Products:
  http://products.mfe.local

Orders:
  http://orders.mfe.local

Users:
  http://users.mfe.local

Module Federation manifests:

  http://products.mfe.local/mf-manifest.json
  http://orders.mfe.local/mf-manifest.json
  http://users.mfe.local/mf-manifest.json

============================================================
Useful commands
============================================================

kubectl get pods -n mfe
kubectl get svc -n mfe
kubectl get ingress -n mfe
kubectl get pods -n ingress-nginx

kubectl top nodes
kubectl top pods -n mfe

============================================================
IMPORTANT
============================================================

For LoadBalancer access, keep this running in another
terminal:

  minikube tunnel

============================================================
EOF