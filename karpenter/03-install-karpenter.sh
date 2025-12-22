#!/usr/bin/env bash
# 03-karpenter-3.sh — Hardened Karpenter install + Pod Identity + Controller policy ensure

set -euo pipefail

: "${CLUSTER_NAME:=karpenter-demo}"
: "${AWS_DEFAULT_REGION:=us-east-1}"
: "${KARPENTER_VERSION:=1.8.1}"
: "${KARPENTER_NAMESPACE:=karpenter}"
: "${AWS_PARTITION:=aws}"

: "${CLUSTER_TAG_KEY:=kubernetes.io/cluster/${CLUSTER_NAME}}"
: "${CLUSTER_TAG_VALUE:=shared}"           # lowercase
: "${DISCOVERY_TAG_KEY:=karpenter.sh/discovery}"
: "${DISCOVERY_TAG_VALUE:=${CLUSTER_NAME}}"

CTRL_ROLE_NAME="${CLUSTER_NAME}-karpenter"
NODE_ROLE_NAME="KarpenterNodeRole-${CLUSTER_NAME}"

need(){ command -v "$1" >/dev/null 2>&1 || { echo "❌ missing: $1"; exit 1; }; }
need aws; need kubectl; need helm

echo "➤ Checking cluster access..."
kubectl version --client >/dev/null 2>&1 || { echo "❌ Cannot connect to cluster"; exit 1; }

echo "➤ Region: ${AWS_DEFAULT_REGION}  Cluster: ${CLUSTER_NAME}"
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
echo "   Account: ${AWS_ACCOUNT_ID}"

echo "➤ Ensuring CoreDNS is ready..."
kubectl -n kube-system rollout status deploy/coredns --timeout=5m || true

# ---- Ensure controller IAM role and trust (Pod Identity) ----
echo "➤ Verifying IAM role for controller: ${CTRL_ROLE_NAME}"
ROLE_ARN="$(aws iam get-role --role-name "${CTRL_ROLE_NAME}" --query 'Role.Arn' --output text 2>/dev/null || true)"
if [[ -z "${ROLE_ARN}" || "${ROLE_ARN}" == "None" ]]; then
  echo "❌ IAM role ${CTRL_ROLE_NAME} not found. Run 01-create first."
  exit 1
fi
echo "   Role ARN: ${ROLE_ARN}"

echo "➤ Ensuring trust policy allows pods.eks.amazonaws.com"
CURRENT_TRUST_JSON="$(aws iam get-role --role-name "${CTRL_ROLE_NAME}" --query 'Role.AssumeRolePolicyDocument' --output json)"
if echo "$CURRENT_TRUST_JSON" | grep -q '"pods.eks.amazonaws.com"' && echo "$CURRENT_TRUST_JSON" | grep -q '"sts:AssumeRole"'; then
  echo "   ✓ Trust OK"
else
  read -r -d '' TRUST_JSON <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "EKSPodIdentityTrust",
    "Effect": "Allow",
    "Principal": { "Service": "pods.eks.amazonaws.com" },
    "Action": ["sts:AssumeRole","sts:TagSession"]
  }]
}
JSON
  aws iam update-assume-role-policy --role-name "${CTRL_ROLE_NAME}" --policy-document "${TRUST_JSON}"
  echo "   ✓ Trust updated"
fi

# ---- Ensure eks-pod-identity-agent addon ----
echo "➤ Ensuring eks-pod-identity-agent addon"
if ! aws eks describe-addon --cluster-name "${CLUSTER_NAME}" --addon-name eks-pod-identity-agent --region "${AWS_DEFAULT_REGION}" >/dev/null 2>&1; then
  aws eks create-addon --cluster-name "${CLUSTER_NAME}" --addon-name eks-pod-identity-agent --region "${AWS_DEFAULT_REGION}" >/dev/null
fi

# ---- Ensure Pod Identity association ----
echo "➤ Ensuring Pod Identity association (karpenter/karpenter → ${CTRL_ROLE_NAME})"
ASSOC_ID="$(aws eks list-pod-identity-associations --cluster-name "${CLUSTER_NAME}" --region "${AWS_DEFAULT_REGION}" \
  --query "associations[?namespaceServiceAccount=='${KARPENTER_NAMESPACE}/karpenter'].associationId | [0]" --output text 2>/dev/null || true)"
if [[ -n "${ASSOC_ID}" && "${ASSOC_ID}" != "None" ]]; then
  echo "   ✓ Association present: ${ASSOC_ID}"
else
  set +e
  OUT="$(aws eks create-pod-identity-association --cluster-name "${CLUSTER_NAME}" --namespace "${KARPENTER_NAMESPACE}" \
       --service-account karpenter --role-arn "${ROLE_ARN}" --region "${AWS_DEFAULT_REGION}" 2>&1)"
  RC=$?; set -e
  if [[ $RC -eq 0 ]] || echo "$OUT" | grep -q 'ResourceInUseException'; then
    echo "   ✓ Association ensured"
  else
    echo "❌ Failed to ensure association: $OUT"; exit $RC
  fi
fi

# ---- Ensure controller policy exists (via Karpenter CFN in this region) & attached ----
echo "➤ Ensuring controller policy exists and attached"
POL_ARN=$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='KarpenterControllerPolicy-${CLUSTER_NAME}'].Arn" --output text)
if [[ -z "${POL_ARN}" || "${POL_ARN}" == "None" ]]; then
  echo "   ↻ Creating controller policy via CloudFormation in ${AWS_DEFAULT_REGION}…"
  TMP="$(mktemp)"
  curl -fsSL "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml" > "$TMP"
  aws --region "${AWS_DEFAULT_REGION}" cloudformation deploy \
    --stack-name "Karpenter-${CLUSTER_NAME}" \
    --template-file "$TMP" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides "ClusterName=${CLUSTER_NAME}"
  rm -f "$TMP"
  POL_ARN=$(aws iam list-policies --scope Local \
    --query "Policies[?PolicyName=='KarpenterControllerPolicy-${CLUSTER_NAME}'].Arn" --output text)
fi

# Attach if not already
if ! aws iam list-attached-role-policies --role-name "${CTRL_ROLE_NAME}" \
     --query "AttachedPolicies[?PolicyArn=='${POL_ARN}'] | length(@)" --output text | grep -q '^1$'; then
  aws iam attach-role-policy --role-name "${CTRL_ROLE_NAME}" --policy-arn "${POL_ARN}"
  echo "   ✓ Attached ${POL_ARN}"
else
  echo "   ✓ Already attached"
fi

# --------------------- INSTALL CRDs ---------------------
echo "➤ Installing Karpenter CRDs (OCI)…"
helm upgrade --install karpenter-crd oci://public.ecr.aws/karpenter/karpenter-crd \
  --version "${KARPENTER_VERSION}" \
  --namespace "${KARPENTER_NAMESPACE}" --create-namespace \
  --wait --timeout 10m

# --------------------- INSTALL CONTROLLER ---------------------
echo "➤ Installing Karpenter controller…"
set +e
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace "${KARPENTER_NAMESPACE}" --create-namespace \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.interruptionQueue=Karpenter-${CLUSTER_NAME}" \
  --set "aws.defaultRegion=${AWS_DEFAULT_REGION}" \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --wait --timeout 10m --atomic
RC=$?; set -e
if [[ $RC -ne 0 ]]; then
  echo "❌ Helm install failed. Recent logs/describe:"
  kubectl -n "${KARPENTER_NAMESPACE}" logs deploy/karpenter -c controller --tail=200 || true
  kubectl -n "${KARPENTER_NAMESPACE}" describe deploy/karpenter || true
  exit $RC
fi

echo "➤ Waiting for controller rollout…"
kubectl rollout status -n "${KARPENTER_NAMESPACE}" deploy/karpenter --timeout=10m || {
  kubectl -n "${KARPENTER_NAMESPACE}" logs deploy/karpenter -c controller --tail=200 || true
  exit 1
}

echo "✅ Karpenter controller is up with correct IAM."
