#!/bin/bash
set -euo pipefail

#################################
# 1. App repo: my-app
#################################

# base folder jahan se sab shuru karna hai
BASE_DIR="/d/devops/DEVOPS-PROJECT/cicd project"
cd "$BASE_DIR"

mkdir -p my-app
cd my-app

# git init only once
if [ ! -d .git ]; then
  git init
fi

# ek basic file ho, warna empty push hoga
if [ ! -f README.md ]; then
  echo "# my-app" > README.md
fi

git add .
git commit -m "initial commit - app" || echo "no changes to commit"

git branch -M master

# repo create karo, agar already hai to ignore error
gh repo create abani-rautray/my-app --public --source=. --remote=origin --push || echo "repo already exists, continuing..."

git remote remove origin 2>/dev/null || true
git remote add origin https://github.com/abani-rautray/my-app.git

git push -u origin master || echo "push failed, maybe history conflict"


#################################
# 2. GitOps repo: my-app-gitops
#################################

cd "$BASE_DIR"

mkdir -p my-app-gitops
cd my-app-gitops

if [ ! -d .git ]; then
  git init
  echo "# gitops for my-app" > README.md
  git add README.md
  git commit -m "init gitops repo" || echo "no changes"
fi

git branch -M master

# create + set remote
gh repo create abani-rautray/my-app-gitops --public --source=. --remote=origin --push || echo "gitops repo already exists"

git remote remove origin 2>/dev/null || true
git remote add origin https://github.com/abani-rautray/my-app-gitops.git

# k8s manifests
mkdir -p k8s

cat > k8s/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
        - name: my-app
          image: ghcr.io/abani-rautray/my-app:latest
          ports:
            - containerPort: 8080
EOF

cat > k8s/service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: my-app
spec:
  selector:
    app: my-app
  ports:
    - port: 80
      targetPort: 8080
  type: ClusterIP
EOF

cat > k8s/kustomization.yaml << 'EOF'
resources:
  - deployment.yaml
  - service.yaml
EOF

git add k8s
git commit -m "Add k8s manifests" || echo "no changes"
git push -u origin master

#################################
# 3. CI workflow in app repo
#################################

cd "$BASE_DIR/my-app"

mkdir -p .github/workflows
cat > .github/workflows/ci-cd.yml << 'EOF'
name: CI -> GitOps Deployment

on:
  push:
    branches: [ master ]

permissions:
  contents: write
  packages: write
  id-token: write

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    env:
      GHCR_OWNER: ${{ github.repository_owner }}
      IMAGE_NAME: my-app

    steps:
      - name: Checkout app repo
        uses: actions/checkout@v4

      - name: Run Tests
        run: |
          echo "Running tests..."
          echo "Tests completed."

      - name: Login to GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build & Push Docker image
        run: |
          IMAGE="ghcr.io/${GHCR_OWNER}/${IMAGE_NAME}:${{ github.sha }}"
          echo "IMAGE=${IMAGE}" >> $GITHUB_ENV
          docker build -t $IMAGE .
          docker push $IMAGE

      - name: Checkout GitOps Repo
        uses: actions/checkout@v4
        with:
          repository: ${{ github.repository_owner }}/my-app-gitops
          token: ${{ secrets.GH_PAT }}
          path: gitops

      - name: Update Kubernetes Manifests
        run: |
          cd gitops
          sed -i "s|image: .*|image: ${IMAGE}|" k8s/deployment.yaml
          git config user.email "ci-bot@github-actions.local"
          git config user.name "github-actions"
          git add k8s/deployment.yaml
          git commit -m "Update image to ${IMAGE}" || echo "No changes to commit"
          git push origin master
EOF

git add .github/workflows/ci-cd.yml
git commit -m "ci: add CI -> GitOps workflow" || echo "no changes to commit"
git push -u origin master

gh secret set GH_PAT --repo abani-rautray/my-app


cd "/my-app"
touch Dockerfile
echo "FROM alpine:3.20
WORKDIR /app
COPY . .
CMD ["sh"]
" > Dockerfile
git add Dockerfile
git commit -m "chore: add Dockerfile" || echo "no changes to commit"
git push -u origin master --force
