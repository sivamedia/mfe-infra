#!/usr/bin/env bash
set -euo pipefail

INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$INFRA_ROOT"
K8S_ROOT="$INFRA_ROOT/k8s"

APPS=("orders" "products" "shell" "users")

INGRESS_MANIFEST="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.13.3/deploy/static/provider/cloud/deploy.yaml"

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

    local ingress_ip

    ingress_ip="$(
        kubectl get svc ingress-nginx-controller \
            -n ingress-nginx \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' \
            2>/dev/null || true
    )"

    if [[ -z "$ingress_ip" ]]; then
        ingress_ip="$(minikube ip)"
        echo "LoadBalancer IP unavailable. Using Minikube IP: $ingress_ip"
    else
        echo "Using Ingress LoadBalancer IP: $ingress_ip"
    fi

    for host in "${hosts[@]}"; do

        # Remove existing entries for this hostname.
        sudo sed -i "/[[:space:]]${host}[[:space:]]*$/d" "$hosts_file"

        # Add the current Ingress IP.
        echo "$ingress_ip $host" |
            sudo tee -a "$hosts_file" >/dev/null

        echo "Configured: $ingress_ip $host"
    done
}

log "Checking prerequisites"
require_cmd docker
require_cmd kubectl
require_cmd minikube
require_cmd sudo

echo "Docker:   $(docker --version)"
echo "kubectl:  $(kubectl version --client 2>/dev/null | head -n 1)"
echo "Minikube: $(minikube version --short 2>/dev/null || true)"

log "Checking Docker"
wait_for_docker

log "Checking Minikube"
if ! minikube status >/dev/null 2>&1; then
    echo "Starting Minikube..."
    minikube start --driver=docker
else
    echo "Minikube is already running."
fi

log "Checking Kubernetes"
wait_for_kubernetes

log "Building MFE Docker images"

declare -a IMAGE_NAMES=(
    "mfe-shell:1.0"
    "mfe-users:1.0"
    "mfe-products:1.0"
    "mfe-orders:1.0"
)

declare -a APP_NAMES=("shell" "users" "products" "orders")

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

    echo "Loading $image into Minikube..."
    minikube image load "$image"
done

log "Verifying MFE images in Minikube"
for image in "${IMAGE_NAMES[@]}"; do
    minikube image ls | grep -Fq "docker.io/library/$image" ||         fail "MFE image was not found inside Minikube: $image"
    echo "Found: docker.io/library/$image"
done

log "Creating MFE namespace"
kubectl apply -f "$K8S_ROOT/namespace.yaml"

log "Checking ingress-nginx"
if ! kubectl get ingressclass nginx >/dev/null 2>&1; then
    echo "NGINX Ingress controller is not installed. Installing..."
    kubectl apply -f "$INGRESS_MANIFEST"
else
    echo "NGINX Ingress controller is already installed."
fi

log "Waiting for ingress-nginx controller"
kubectl rollout status deployment/ingress-nginx-controller     -n ingress-nginx     --timeout=180s

log "Waiting for ingress admission webhook"
admission_ip=""
for i in {1..30}; do
    admission_ip="$(
        kubectl get endpointslice             -n ingress-nginx             -l kubernetes.io/service-name=ingress-nginx-controller-admission             -o jsonpath='{.items[0].endpoints[0].addresses[0]}'             2>/dev/null || true
    )"

    if [[ -n "$admission_ip" ]]; then
        echo "Ingress admission webhook is ready: $admission_ip"
        break
    fi

    echo "Waiting for admission webhook... ($i/30)"
    sleep 2

    [[ "$i" -lt 30 ]] || fail "Ingress admission webhook did not become ready."
done

log "Applying MFE deployments"
for app in "${APPS[@]}"; do
    file="$K8S_ROOT/$app/deployment.yaml"
    [[ -f "$file" ]] || fail "Deployment manifest not found: $file"
    kubectl apply -f "$file"
done

log "Applying MFE services"
for app in "${APPS[@]}"; do
    file="$K8S_ROOT/$app/service.yaml"
    [[ -f "$file" ]] || fail "Service manifest not found: $file"
    kubectl apply -f "$file"
done

log "Applying MFE ingress"
kubectl apply -f "$K8S_ROOT/ingress.yaml"

log "Waiting for MFE deployments"
for app in "${APPS[@]}"; do
    kubectl rollout status "deployment/$app" -n mfe --timeout=120s
done

add_hosts

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
echo "=== Ingress Service ==="
kubectl get svc -n ingress-nginx

cat <<'EOF'

============================================================
MFE URLs
============================================================

http://mfe.local
http://products.mfe.local
http://orders.mfe.local
http://users.mfe.local

============================================================
IMPORTANT
============================================================

For clean LoadBalancer URLs, keep this running
in another terminal:

    minikube tunnel

============================================================
EOF
