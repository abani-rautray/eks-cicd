# 🚀 Production-Grade CI/CD & GitOps on Amazon EKS (Karpenter)

## 📌 Overview

This repository demonstrates a **real-world DevOps implementation** of an **end-to-end CI/CD and GitOps workflow** on **Amazon EKS** using modern cloud-native tools.

The project focuses on **automation, scalability, and cost optimization** by combining:
- CI pipelines for application builds
- GitOps-based Kubernetes deployments
- Dynamic node provisioning using **Karpenter**

---

## 🏗️ Architecture Flow

1. Developer pushes code to GitHub  
2. CI pipeline builds Docker image  
3. GitOps repository updates Kubernetes manifests  
4. Argo CD detects changes and syncs automatically  
5. Application deploys to Amazon EKS  
6. Karpenter provisions EC2 nodes based on workload demand  

---

## 🔧 Tech Stack

- Amazon EKS
- Kubernetes
- Karpenter
- Kustomize
- Argo CD
- GitHub Actions
- Docker
- Bash (Shell scripts)
---

## ✨ Key Features

- End-to-end automated CI/CD pipeline
- GitOps-based deployment using Argo CD
- Dynamic and cost-efficient autoscaling with Karpenter
- No static node groups
- Script-driven cluster bootstrap
- Production-oriented repository structure

---

## 📂 Repository Structure

.
├── 00-run-all.sh
│
├── cicd/
│   ├── exe.sh
│   ├── my-app/
│   │   ├── app.py
│   │   ├── Dockerfile
│   │   ├── requirements.txt
│   │   └── README.md
│   │
│   └── my-app-gitops/
│       ├── argocd-app.yaml
│       ├── README.md
│       └── k8s/
│           ├── namespace.yaml
│           ├── deployment.yaml
│           ├── service.yaml
│           └── kustomization.yaml
│
└── karpenter/
    ├── 01-create-cluster.sh
    ├── 02-add-tag.sh
    ├── 03-install-karpenter.sh
    ├── 04-ec2nodeclass+nodepool.sh
    ├── 05-smoke-test.sh
    └── 06-install-argocd-with-output.sh


---

## ⚙️ Setup & Installation

### Prerequisites

- AWS CLI configured
- kubectl
- Docker
- Git

---

### Step 1️⃣ Clone Repository

```bash
git clone https://github.com/abani-rautray/my-app-gitops.git
cd my-app-gitops
```

### Step 2️⃣ Create EKS Cluster & Install Karpenter

```bash
cd karpenter
./01-create-cluster.sh
./02-tag.sh
./03-karpenter.sh
./04-ec2nodeclass+nodepool.sh
./06-install-argocd-with-output.sh 
```

### Step 3️⃣ Deploy Application via GitOps

```bash
kubectl apply -f cicd/my-app-gitops/argocd-app.yaml 
```

## 📈 Why This Project Matters

-   Demonstrates production-level DevOps practices
-   Shows modern autoscaling using Karpenter
-   Implements true GitOps (no manual kubectl apply)
-   Designed for real-world cloud environments
-   Strong portfolio project for DevOps engineers


## 🔮 Future Improvements

-   Multi-environment support (dev / stage / prod)
-   Monitoring with Prometheus & Grafana

## 🤝 Contributing

Contributions are welcome.
Feel free to open issues or submit pull requests.

## License

MIT License


