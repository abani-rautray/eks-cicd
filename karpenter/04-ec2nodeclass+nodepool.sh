#!/usr/bin/env bash
set -euo pipefail

: "${CLUSTER_NAME:=karpenter-demo}"
echo "Using CLUSTER_NAME=${CLUSTER_NAME}"

cat <<EOF | kubectl apply -f -
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  role: KarpenterNodeRole-${CLUSTER_NAME}
  amiSelectorTerms:
    - alias: al2023@latest
  subnetSelectorTerms:
    - tags:
        kubernetes.io/cluster/${CLUSTER_NAME}: shared
  securityGroupSelectorTerms:
    - tags:
        kubernetes.io/cluster/${CLUSTER_NAME}: shared
  tags:
    karpenter.sh/discovery: ${CLUSTER_NAME}
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: critical
spec:
  template:
    metadata:
      labels:
        workload-type: critical
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c","m","r","t"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["2"]
      expireAfter: 720h
  limits:
    cpu: 100
  disruption:
    consolidationPolicy: WhenEmpty
    consolidateAfter: 1m
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    metadata:
      labels:
        nodepool: default
        provisioner: karpenter
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot","on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c","m","r","t"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["2"]
      expireAfter: 720h
  limits:
    cpu: 1000
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
EOF
