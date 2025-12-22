#!/usr/bin/env bash
# eks-karpenter-setup-with-tags.sh
# End-to-end EKS + Karpenter setup + consistent tagging (env + CLI flags)
# Requirements: aws, eksctl, kubectl, helm

set -euo pipefail

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options (flags override env vars):
  --cluster NAME                 (env: CLUSTER_NAME, default: karpenter-demo)
  --region REGION                (env: AWS_DEFAULT_REGION, default: us-east-1)
  --k8s VERSION                  (env: K8S_VERSION, default: 1.30)
  --karpenter-version VER        (env: KARPENTER_VERSION, default: 1.8.1)
  --alias-version ALIAS          (env: ALIAS_VERSION, default: latest)
  --namespace NAME               (env: KARPENTER_NAMESPACE, default: karpenter)
  --partition PART               (env: AWS_PARTITION, default: aws)

  --cluster-tag-key KEY          (env: CLUSTER_TAG_KEY, default: kubernetes.io/cluster/\$CLUSTER_NAME)
  --cluster-tag-value VAL        (env: CLUSTER_TAG_VALUE, default: shared)
  --discovery-tag-key KEY        (env: DISCOVERY_TAG_KEY, default: karpenter.sh/discovery)
  --discovery-tag-value VAL      (env: DISCOVERY_TAG_VALUE, default: \$CLUSTER_NAME)

  -h, --help
USAGE
}

: "${CLUSTER_NAME:=karpenter-demo}"
: "${AWS_DEFAULT_REGION:=us-east-1}"
: "${K8S_VERSION:=1.30}"
: "${KARPENTER_VERSION:=1.8.1}"        # OCI chart version (no 'v' prefix)
: "${KARPENTER_NAMESPACE:=karpenter}"
: "${ALIAS_VERSION:=latest}"
: "${AWS_PARTITION:=aws}"

: "${CLUSTER_TAG_KEY:=kubernetes.io/cluster/${CLUSTER_NAME}}"
: "${CLUSTER_TAG_VALUE:=shared}"        # must be lowercase: shared|owned
: "${DISCOVERY_TAG_KEY:=karpenter.sh/discovery}"
: "${DISCOVERY_TAG_VALUE:=${CLUSTER_NAME}}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster)              CLUSTER_NAME="$2"; shift 2 ;;
    --region)               AWS_DEFAULT_REGION="$2"; shift 2 ;;
    --k8s)                  K8S_VERSION="$2"; shift 2 ;;
    --karpenter-version)    KARPENTER_VERSION="$2"; shift 2 ;;
    --alias-version)        ALIAS_VERSION="$2"; shift 2 ;;
    --namespace)            KARPENTER_NAMESPACE="$2"; shift 2 ;;
    --partition)            AWS_PARTITION="$2"; shift 2 ;;
    --cluster-tag-key)      CLUSTER_TAG_KEY="$2"; shift 2 ;;
    --cluster-tag-value)    CLUSTER_TAG_VALUE="$2"; shift 2 ;;
    --discovery-tag-key)    DISCOVERY_TAG_KEY="$2"; shift 2 ;;
    --discovery-tag-value)  DISCOVERY_TAG_VALUE="$2"; shift 2 ;;
    -h|--help)              usage; exit 0 ;;
    *) echo "Unknown option: $1"; echo; usage; exit 1 ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ missing cli: $1"; exit 1; }; }
need aws; need eksctl; need kubectl; need helm; need envsubst

echo "➤ Config:"
echo "   Cluster=${CLUSTER_NAME} Region=${AWS_DEFAULT_REGION} K8s=${K8S_VERSION} Karpenter=${KARPENTER_VERSION}"
echo "   Tags: ${CLUSTER_TAG_KEY}=${CLUSTER_TAG_VALUE}, ${DISCOVERY_TAG_KEY}=${DISCOVERY_TAG_VALUE}"

echo "➤ Resolving AWS account..."
AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
KARPENTER_NODE_ROLE_NAME="KarpenterNodeRole-${CLUSTER_NAME}"
KARPENTER_CONTROLLER_POLICY_NAME="KarpenterControllerPolicy-${CLUSTER_NAME}"
KARPENTER_CONTROLLER_POLICY_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/${KARPENTER_CONTROLLER_POLICY_NAME}"

EKS_TAGS_ARGS="${CLUSTER_TAG_KEY}=${CLUSTER_TAG_VALUE},${DISCOVERY_TAG_KEY}=${DISCOVERY_TAG_VALUE}"

# ---------- IAM Bootstrap ----------
echo "➤ Deploying Karpenter IAM (CloudFormation) in ${AWS_DEFAULT_REGION}…"
TMP="$(mktemp)"
curl -fsSL "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml" > "$TMP"
aws --region "${AWS_DEFAULT_REGION}" cloudformation deploy \
  --stack-name "Karpenter-${CLUSTER_NAME}" \
  --template-file "$TMP" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ClusterName=${CLUSTER_NAME}"
rm -f "$TMP"
echo "   ✓ IAM stack deployed"

# ---------- EKS Cluster ----------
echo "➤ Creating/ensuring EKS cluster (eksctl)…"
eksctl create cluster -f - <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_DEFAULT_REGION}
  version: "${K8S_VERSION}"
  tags:
    ${DISCOVERY_TAG_KEY}: ${DISCOVERY_TAG_VALUE}
    ${CLUSTER_TAG_KEY}: ${CLUSTER_TAG_VALUE}

vpc:
  nat:
    gateway: Single
availabilityZones:
  - ${AWS_DEFAULT_REGION}a
  - ${AWS_DEFAULT_REGION}b

iam:
  withOIDC: true
  podIdentityAssociations:
  - namespace: "${KARPENTER_NAMESPACE}"
    serviceAccountName: karpenter
    roleName: ${CLUSTER_NAME}-karpenter
    permissionPolicyARNs:
    - ${KARPENTER_CONTROLLER_POLICY_ARN}

iamIdentityMappings:
- arn: "arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:role/${KARPENTER_NODE_ROLE_NAME}"
  username: system:node:{{EC2PrivateDNSName}}
  groups:
  - system:bootstrappers
  - system:nodes

managedNodeGroups:
- name: ${CLUSTER_NAME}-ng
  instanceType: m5.large
  amiFamily: AmazonLinux2023
  desiredCapacity: 2
  minSize: 1
  maxSize: 5
  privateNetworking: true
  tags:
    ${DISCOVERY_TAG_KEY}: ${DISCOVERY_TAG_VALUE}
    ${CLUSTER_TAG_KEY}: ${CLUSTER_TAG_VALUE}

addons:
- name: eks-pod-identity-agent
EOF
