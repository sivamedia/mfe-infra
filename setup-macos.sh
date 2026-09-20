#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# MFE Infrastructure Setup - macOS Tahoe
# Run from mfe-infra:
#   ./setup-macos.sh
# ============================================================

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$INFRA_ROOT/.." && pwd)"
K8S_ROOT="$INFRA_ROOT/k8s"

APPS=("orders" "products" "shell" "users")

INGRESS_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.13.3/deploy/static/provider/cloud/deploy.yaml"

log() {
    echo
    echo "=== $1 ==="
}

fail() {
    echo "ERROR: $1" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 was not found. Install it first."
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

add_hosts() {
    local hosts_file="/etc/hosts"

    log "Configuring /etc/hosts"

    local hosts=(
        "mfe.local"
        "products.mfe.local"
        "orders.mfe.local"
        "users.mfe.local"
    )

    for host in "${hosts[@]}"; do
        if grep -Eq "^[[:space:]]*127\.0\.0\.1[[:space:]]+$host([[:space:]]|$)" "$hosts_file"; then
            echo "Already present: 127.0.0.1 $host"
        else
            echo "Adding: 127.0.0.1 $host"
            echo "127.0.0.1 $host" | sudo tee -a "$hosts_file" >/dev/null
        fi
    done
}

# ------------------------------------------------------------
# Prerequisites
# ------------------------------------------------------------

log "Checking prerequisites"

require_cmd docker
require_cmd kubectl

# ------------------------------------------------------------
# Platform-specific Docker startup
# ------------------------------------------------------------

PLATFORM="macos"

if [[ "$PLATFORM" == "macos" ]]; then

    log "Starting Docker Desktop"

    if [[ ! -d "/Applications/Docker.app" ]]; then
        fail "Docker Desktop was not found at /Applications/Docker.app."
    fi

    if ! pgrep -x "Docker" >/dev/null 2>&1; then
        echo "Starting Docker Desktop..."
        open -a Docker
    fi

    wait_for_docker

else
    fail "This script is for macOS Tahoe only."
fi

# ------------------------------------------------------------
# Kubernetes
# ------------------------------------------------------------

log "Checking Kubernetes"

CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"

if [[ -z "$CURRENT_CONTEXT" ]]; then
    fail "No kubectl context is configured."
fi

echo "Current Kubernetes context: $CURRENT_CONTEXT"

if kubectl get nodes --no-headers >/tmp/mfe_nodes 2>/dev/null; then
    if grep -Eq '[[:space:]]Ready([[:space:]]|$)' /tmp/mfe_nodes; then
        echo "Kubernetes is already ready."
        kubectl get nodes
    else
        rm -f /tmp/mfe_nodes
        wait_for_kubernetes
    fi
else
    rm -f /tmp/mfe_nodes
    wait_for_kubernetes
fi

rm -f /tmp/mfe_nodes

# ------------------------------------------------------------
# Build Docker images
# ------------------------------------------------------------

log "Building MFE Docker images"

declare -a IMAGE_NAMES=(
    "mfe-shell:1.0"
    "mfe-users:1.0"
    "mfe-products:1.0"
    "mfe-orders:1.0"
)

declare -a APP_NAMES=(
    "shell"
    "users"
    "products"
    "orders"
)

for index in "${!APP_NAMES[@]}"; do
    app="${APP_NAMES[$index]}"
    image="${IMAGE_NAMES[$index]}"

    dockerfile="$PROJECT_ROOT/$app/.dockerFile"
    context="$PROJECT_ROOT/$app"

    [[ -f "$dockerfile" ]] || fail "Dockerfile not found: $dockerfile"
    [[ -d "$context" ]] || fail "Build context not found: $context"

    echo
    echo "Building $image..."
    docker build -f "$dockerfile" -t "$image" "$context"
done

# ------------------------------------------------------------
# Namespace
# ------------------------------------------------------------

log "Creating MFE namespace"

kubectl apply -f "$K8S_ROOT/namespace.yaml"

# ------------------------------------------------------------
# ingress-nginx
# ------------------------------------------------------------

log "Checking ingress-nginx"

if ! kubectl get ingressclass nginx >/dev/null 2>&1; then
    echo "NGINX Ingress controller is not installed. Installing..."
    kubectl apply -f "$INGRESS_MANIFEST"
else
    echo "NGINX Ingress controller is already installed."
fi

echo "Waiting for ingress-nginx controller..."

kubectl rollout status \
    deployment/ingress-nginx-controller \
    -n ingress-nginx \
    --timeout=180s

# ------------------------------------------------------------
# Deployments
# ------------------------------------------------------------

log "Applying MFE deployments"

for app in "${APPS[@]}"; do
    file="$K8S_ROOT/$app/deployment.yaml"
    [[ -f "$file" ]] || fail "Deployment manifest not found: $file"

    kubectl apply -f "$file"
done

# ------------------------------------------------------------
# Services
# ------------------------------------------------------------

log "Applying MFE services"

for app in "${APPS[@]}"; do
    file="$K8S_ROOT/$app/service.yaml"
    [[ -f "$file" ]] || fail "Service manifest not found: $file"

    kubectl apply -f "$file"
done

# ------------------------------------------------------------
# Ingress
# ------------------------------------------------------------

log "Applying MFE ingress"

kubectl apply -f "$K8S_ROOT/ingress.yaml"

# ------------------------------------------------------------
# Wait for applications
# ------------------------------------------------------------

log "Waiting for MFE deployments"

for app in "${APPS[@]}"; do
    kubectl rollout status \
        "deployment/$app" \
        -n mfe \
        --timeout=120s
done

# ------------------------------------------------------------
# Hosts
# ------------------------------------------------------------

add_hosts

# ------------------------------------------------------------
# Final status
# ------------------------------------------------------------

log "MFE setup complete"

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

============================================================
EOF
