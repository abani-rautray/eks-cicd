#!/usr/bin/env bash
set -euo pipefail

# ===============================
# GLOBAL CONFIG
# ===============================
export CLUSTER_NAME="karpenter-demo"
export AWS_REGION="us-east-1"

echo "======================================"
echo " Karpenter + GitOps Bootstrap"
echo " Cluster : $CLUSTER_NAME"
echo " Region  : $AWS_REGION"
echo "======================================"
sleep 2

# ===============================
# Karpenter Bootstrap
# ===============================
cd karpenter

echo "STEP 1: Create EKS cluster"
./01-create-cluster.sh
kubectl get nodes
echo "--------------------------------------"

echo "STEP 2: Tag AWS resources"
./02-add-tag.sh
echo "--------------------------------------"

echo "STEP 3: Install Karpenter"
./03-install-karpenter.sh
kubectl get pods -n karpenter
echo "--------------------------------------"

echo "STEP 4: Apply NodeClass & NodePool"
./04-ec2nodeclass+nodepool.sh
kubectl get nodepool
echo "--------------------------------------"

echo "STEP 5: Smoke test Karpenter"
./05-smoke-test.sh
kubectl get nodes
echo "--------------------------------------"

echo "STEP 6: Install Argo CD"
./06-install-argocd-with-output.sh
kubectl get pods -n argocd
echo "--------------------------------------"

cd ..

# ===============================
# CI/CD & GitOps (INTENTIONAL)
# ===============================
echo "NOTE:"
echo "CI is triggered by pushing application code to GitHub."
echo "GitOps deployment is handled automatically by Argo CD."
echo "This script intentionally does NOT perform any git push."
echo "--------------------------------------"

# ===============================
# Verify App
# ===============================
echo "Checking application pods (if deployed)"
kubectl get pods -n my-app || true
echo "--------------------------------------"

echo "======================================"
echo " BOOTSTRAP COMPLETED SUCCESSFULLY"
echo "======================================"
