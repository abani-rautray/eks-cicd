#!/usr/bin/env bash
set -euo pipefail

need() { command -v "$1" >/dev/null 2>&1 || { echo "❌ missing cli: $1"; exit 1; }; }
need aws

: "${CLUSTER_NAME:=karpenter-demo}"
: "${AWS_DEFAULT_REGION:=us-east-1}"
: "${KARPENTER_NAMESPACE:=karpenter}"
: "${AWS_PARTITION:=aws}"

: "${CLUSTER_TAG_KEY:=kubernetes.io/cluster/${CLUSTER_NAME}}"
: "${CLUSTER_TAG_VALUE:=shared}"          # lowercase: shared|owned
: "${DISCOVERY_TAG_KEY:=karpenter.sh/discovery}"
: "${DISCOVERY_TAG_VALUE:=${CLUSTER_NAME}}"

echo "➤ Tagging resources with:"
echo "   - ${CLUSTER_TAG_KEY}=${CLUSTER_TAG_VALUE}"
echo "   - ${DISCOVERY_TAG_KEY}=${DISCOVERY_TAG_VALUE}"

AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
KARPENTER_NODE_ROLE_NAME="KarpenterNodeRole-${CLUSTER_NAME}"
KARPENTER_CONTROLLER_POLICY_NAME="KarpenterControllerPolicy-${CLUSTER_NAME}"
KARPENTER_CONTROLLER_POLICY_ARN="arn:${AWS_PARTITION}:iam::${AWS_ACCOUNT_ID}:policy/${KARPENTER_CONTROLLER_POLICY_NAME}"

EKS_TAGS_ARGS="${CLUSTER_TAG_KEY}=${CLUSTER_TAG_VALUE},${DISCOVERY_TAG_KEY}=${DISCOVERY_TAG_VALUE}"
EC2_TAGS_ARGS="Key=${DISCOVERY_TAG_KEY},Value=${DISCOVERY_TAG_VALUE}"

# EKS cluster + nodegroups
echo "→ EKS cluster"
CLUSTER_ARN=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_DEFAULT_REGION" --query "cluster.arn" --output text)
aws eks tag-resource --region "$AWS_DEFAULT_REGION" --resource-arn "$CLUSTER_ARN" --tags "${EKS_TAGS_ARGS}"

echo "→ EKS nodegroups"
NODEGROUPS=$(aws eks list-nodegroups --cluster-name "$CLUSTER_NAME" --region "$AWS_DEFAULT_REGION" --query "nodegroups[]" --output text)
if [[ -n "${NODEGROUPS:-}" ]]; then
  for ng in $NODEGROUPS; do
    NG_ARN=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" --region "$AWS_DEFAULT_REGION" --query "nodegroup.nodegroupArn" --output text)
    aws eks tag-resource --region "$AWS_DEFAULT_REGION" --resource-arn "$NG_ARN" --tags "${EKS_TAGS_ARGS}"
  done
else
  echo "   (no managed nodegroups found)"
fi

# EC2 instances (cluster-owned/pending/running)
echo "→ EC2 instances"
INSTANCE_IDS=$(aws ec2 describe-instances --region "$AWS_DEFAULT_REGION" \
  --filters "Name=tag:eks:cluster-name,Values=$CLUSTER_NAME" "Name=instance-state-name,Values=running,pending" \
  --query "Reservations[].Instances[].InstanceId" --output text)
if [[ -n "${INSTANCE_IDS:-}" ]]; then
  for iid in $INSTANCE_IDS; do
    # tag one-by-one; ignore NotFound (instance may have terminated)
    aws ec2 create-tags --region "$AWS_DEFAULT_REGION" --resources "$iid" --tags ${EC2_TAGS_ARGS} \
    || echo "⚠️ skip: instance $iid not found (likely terminated)"
  done
else
  echo "   (no active instances matched)"
fi

# VPC / Subnets / SGs / RTs
echo "→ VPCs"
VPCS=$(aws ec2 describe-vpcs --region "$AWS_DEFAULT_REGION" --filters "Name=tag:Name,Values=*${CLUSTER_NAME}*" --query "Vpcs[].VpcId" --output text)
[[ -n "${VPCS:-}" ]] && aws ec2 create-tags --region "$AWS_DEFAULT_REGION" --resources $VPCS --tags ${EC2_TAGS_ARGS} || echo "   (none)"

echo "→ Subnets"
SUBNETS=$(aws ec2 describe-subnets --region "$AWS_DEFAULT_REGION" --filters "Name=tag:Name,Values=*${CLUSTER_NAME}*" --query "Subnets[].SubnetId" --output text)
[[ -n "${SUBNETS:-}" ]] && aws ec2 create-tags --region "$AWS_DEFAULT_REGION" --resources $SUBNETS --tags ${EC2_TAGS_ARGS} || echo "   (none)"

echo "→ Security Groups"
SGS=$(aws ec2 describe-security-groups --region "$AWS_DEFAULT_REGION" --filters "Name=tag:Name,Values=*${CLUSTER_NAME}*" --query "SecurityGroups[].GroupId" --output text)
[[ -n "${SGS:-}" ]] && aws ec2 create-tags --region "$AWS_DEFAULT_REGION" --resources $SGS --tags ${EC2_TAGS_ARGS} || echo "   (none)"

echo "→ Route Tables"
RTS=$(aws ec2 describe-route-tables --region "$AWS_DEFAULT_REGION" --filters "Name=tag:Name,Values=*${CLUSTER_NAME}*" --query "RouteTables[].RouteTableId" --output text)
[[ -n "${RTS:-}" ]] && aws ec2 create-tags --region "$AWS_DEFAULT_REGION" --resources $RTS --tags ${EC2_TAGS_ARGS} || echo "   (none)"

# Auto Scaling Groups
echo "→ Auto Scaling Groups"
ASGS=$(aws autoscaling describe-auto-scaling-groups --region "$AWS_DEFAULT_REGION" \
  --query "AutoScalingGroups[?contains(AutoScalingGroupName, '${CLUSTER_NAME}')].AutoScalingGroupName" --output text)
if [[ -n "${ASGS:-}" ]]; then
  for asg in $ASGS; do
    aws autoscaling create-or-update-tags --region "$AWS_DEFAULT_REGION" \
      --tags "ResourceId=$asg,ResourceType=auto-scaling-group,Key=${CLUSTER_TAG_KEY},Value=${CLUSTER_TAG_VALUE},PropagateAtLaunch=true" \
            "ResourceId=$asg,ResourceType=auto-scaling-group,Key=${DISCOVERY_TAG_KEY},Value=${DISCOVERY_TAG_VALUE},PropagateAtLaunch=true"
  done
else
  echo "   (none)"
fi

# IAM roles
echo "→ IAM roles containing '${CLUSTER_NAME}'"
ROLES=$(aws iam list-roles --query "Roles[?contains(RoleName, '${CLUSTER_NAME}')].RoleName" --output text)
if [[ -n "${ROLES:-}" ]]; then
  for role in $ROLES; do
    aws iam tag-role --role-name "$role" \
      --tags Key="${CLUSTER_TAG_KEY}",Value="${CLUSTER_TAG_VALUE}" Key="${DISCOVERY_TAG_KEY}",Value="${DISCOVERY_TAG_VALUE}"
  done
else
  echo "   (none)"
fi

echo "✅ Done. EKS + related resources are tagged."
echo "   Verify:"
echo "   aws resourcegroupstaggingapi get-resources --region ${AWS_DEFAULT_REGION} \\"
echo "     --tag-filters Key='${CLUSTER_TAG_KEY}',Values='${CLUSTER_TAG_VALUE}' Key='${DISCOVERY_TAG_KEY}',Values='${DISCOVERY_TAG_VALUE}'"
