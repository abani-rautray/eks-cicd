#!/usr/bin/env bash
set -euo pipefail

ARGO_NAMESPACE="argocd"
ARGO_VERSION="stable"
LOCAL_PORT=8080

need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ missing: $1"; exit 1; }; }
need kubectl

echo "➤ Creating namespace ${ARGO_NAMESPACE}"
kubectl create namespace ${ARGO_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

echo "➤ Installing Argo CD (${ARGO_VERSION})"
kubectl apply -n ${ARGO_NAMESPACE} \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/${ARGO_VERSION}/manifests/install.yaml

echo "➤ Waiting for Argo CD server..."
kubectl -n ${ARGO_NAMESPACE} rollout status deploy/argocd-server --timeout=10m

echo "➤ Fetching admin password..."
ARGO_PASSWORD=$(kubectl -n ${ARGO_NAMESPACE} get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

echo "➤ Starting port-forward on https://localhost:${LOCAL_PORT}"
nohup kubectl -n ${ARGO_NAMESPACE} port-forward svc/argocd-server ${LOCAL_PORT}:443 \
  > argocd-portforward.log 2>&1 &

sleep 5

echo
echo "✅ Argo CD is ready 🚀"
echo "----------------------------------"
echo "URL      : https://localhost:${LOCAL_PORT}"
echo "Username : admin"
echo "Password : ${ARGO_PASSWORD}"
echo "----------------------------------"
echo
echo "ℹ️ Port-forward log: argocd-portforward.log"
echo "ℹ️ To stop port-forward:"
echo "    pkill -f \"kubectl -n ${ARGO_NAMESPACE} port-forward\""

kubectl get pods -n argocd -w