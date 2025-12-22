#!/usr/bin/env bash
# 05-smoke-test.sh — simple Karpenter provisioning test

set -euo pipefail

: "${KARPENTER_NAMESPACE:=karpenter}"

echo "➤ Creating 'inflate' deployment in default namespace for Karpenter smoke test"

kubectl apply -n default -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inflate
spec:
  replicas: 0
  selector:
    matchLabels:
      app: inflate
  template:
    metadata:
      labels:
        app: inflate
    spec:
      terminationGracePeriodSeconds: 0
      containers:
      - name: inflate
        image: public.ecr.aws/eks-distro/kubernetes/pause:3.9
        resources:
          requests:
            cpu: "1"
EOF

echo "➤ Scaling inflate deployment to 5 replicas..."
kubectl -n default scale deploy inflate --replicas 5

echo "➤ Waiting for pods to reach Running state (timeout 5m)..."
kubectl -n default wait --for=condition=Available deployment/inflate --timeout=5m || {
  echo "⚠️ Pods not yet running — check Karpenter controller logs for details"
  kubectl -n "${KARPENTER_NAMESPACE}" logs deploy/karpenter -c controller --tail=40 || true
  exit 1
}

echo "✅ Pods scheduled successfully!"
echo "   Nodes created by Karpenter:"
kubectl get nodes -Lkarpenter.sh/capacity-type -o wide

echo
echo "   You can watch Karpenter in real-time with:"
echo "     kubectl -n ${KARPENTER_NAMESPACE} logs deploy/karpenter -c controller -f"
echo
echo "   To clean up:"
echo "     kubectl delete deploy inflate -n default"
