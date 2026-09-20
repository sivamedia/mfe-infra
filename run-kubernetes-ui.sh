#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="kubernetes-dashboard"
SERVICE="kubernetes-dashboard-kong-proxy"
LOCAL_PORT="8443"

echo "============================================================"
echo "=== Starting Kubernetes Dashboard"
echo "============================================================"

if ! minikube status >/dev/null 2>&1; then
    echo "ERROR: Minikube is not running."
    exit 1
fi

echo
echo "Starting Kubernetes Dashboard..."

if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "Kubernetes Dashboard is not installed."
    echo
    echo "Install it with:"
    echo
    echo "  minikube dashboard"
    exit 1
fi

echo
echo "Dashboard services:"
kubectl get svc -n "$NAMESPACE"

echo
echo "Starting Dashboard proxy..."
echo
echo "Kubernetes Dashboard URL:"
echo "  https://localhost:$LOCAL_PORT"
echo
echo "Press Ctrl+C to stop."
echo

kubectl port-forward \
    -n "$NAMESPACE" \
    "svc/$SERVICE" \
    "$LOCAL_PORT:443"