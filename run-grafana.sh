#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="monitoring"
GRAFANA_SERVICE="grafana"
LOCAL_PORT="3000"

echo "============================================================"
echo "=== Starting Grafana"
echo "============================================================"

if ! minikube status >/dev/null 2>&1; then
    echo "ERROR: Minikube is not running."
    exit 1
fi

if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "Creating namespace: $NAMESPACE"
    kubectl create namespace "$NAMESPACE"
fi

if ! kubectl get deployment grafana -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "Grafana is not installed."
    echo
    echo "Install your Grafana deployment first."
    exit 1
fi

echo
echo "Grafana pod:"
kubectl get pods -n "$NAMESPACE" -l app=grafana

echo
echo "Grafana service:"
kubectl get svc -n "$NAMESPACE" "$GRAFANA_SERVICE"

echo
echo "Starting port-forward..."
echo
echo "Grafana URL:"
echo "  http://localhost:$LOCAL_PORT"
echo
echo "Press Ctrl+C to stop."
echo

kubectl port-forward \
    -n "$NAMESPACE" \
    "svc/$GRAFANA_SERVICE" \
    "$LOCAL_PORT:3000"