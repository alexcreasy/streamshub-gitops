#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="gitops-tutorial"
GITEA_USER="tutorial-user"
GITEA_PASSWORD="tutorial-password"
GITEA_REPO="streamshub-gitops"
GITEA_HOST_PORT=3001
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }
b64decode() { echo "$1" | base64 -d 2>/dev/null || echo "$1" | base64 -D 2>/dev/null; }

cleanup() {
  if [[ -n "${WORK_DIR:-}" ]]; then
    rm -rf "${WORK_DIR}"
  fi
}

# ─── Step 1: Check prerequisites ───────────────────────────────────────────────

info "Checking prerequisites..."
for cmd in kind kubectl git curl; do
  if ! command -v "$cmd" &>/dev/null; then
    error "'$cmd' is required but not found in PATH."
    exit 1
  fi
done

if ! docker info &>/dev/null 2>&1; then
  error "Docker is not running. Please start Docker Desktop or your container runtime."
  exit 1
fi

info "All prerequisites satisfied."

# ─── Step 2: Create KinD cluster ───────────────────────────────────────────────

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  info "KinD cluster '${CLUSTER_NAME}' already exists, skipping creation."
else
  info "Creating KinD cluster '${CLUSTER_NAME}'..."
  kind create cluster --name "${CLUSTER_NAME}" --config "${SCRIPT_DIR}/kind-config.yaml"
fi

kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null 2>&1
info "Cluster is ready."

# ─── Step 3: Install ArgoCD ────────────────────────────────────────────────────

info "Installing ArgoCD..."
kubectl apply -k "${SCRIPT_DIR}/../../examples/argo-cd/overlays/kubernetes" --server-side 2>/dev/null || \
  kubectl apply -k "${SCRIPT_DIR}/../../examples/argo-cd/overlays/kubernetes" --server-side

info "Waiting for ArgoCD to be ready (this may take a few minutes)..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=300s

# ─── Step 4: Install Strimzi operator ──────────────────────────────────────────

info "Installing Strimzi operator..."
kubectl create namespace strimzi-operator 2>/dev/null || true
kubectl apply -k "${SCRIPT_DIR}/../../examples/operators/strimzi/overlays/kubernetes" --server-side 2>/dev/null || \
  kubectl apply -k "${SCRIPT_DIR}/../../examples/operators/strimzi/overlays/kubernetes" --server-side

# The upstream Strimzi YAML hardcodes 'myproject' as the ServiceAccount namespace in RoleBindings.
# Kustomize namespace override doesn't fix subject references, so patch them manually.
STRIMZI_NS_PATCH='[{"op":"replace","path":"/subjects/0/namespace","value":"strimzi-operator"}]'
for rb in strimzi-cluster-operator strimzi-cluster-operator-entity-operator-delegation strimzi-cluster-operator-leader-election strimzi-cluster-operator-watched; do
  kubectl patch rolebinding "${rb}" -n strimzi-operator --type=json -p "${STRIMZI_NS_PATCH}" 2>/dev/null || true
done
for crb in strimzi-cluster-operator strimzi-cluster-operator-kafka-broker-delegation strimzi-cluster-operator-kafka-client-delegation; do
  kubectl patch clusterrolebinding "${crb}" --type=json -p "${STRIMZI_NS_PATCH}" 2>/dev/null || true
done

# Tell the operator to watch the kafka-tutorial namespace and create the RoleBindings it needs there.
kubectl create namespace kafka-tutorial 2>/dev/null || true
kubectl set env deployment/strimzi-cluster-operator -n strimzi-operator STRIMZI_NAMESPACE='kafka-tutorial'

for rb_name in strimzi-cluster-operator strimzi-cluster-operator-entity-operator-delegation strimzi-cluster-operator-watched; do
  ROLE_REF=$(kubectl get rolebinding "${rb_name}" -n strimzi-operator -o jsonpath='{.roleRef.name}')
  kubectl create rolebinding "${rb_name}" \
    --namespace kafka-tutorial \
    --clusterrole="${ROLE_REF}" \
    --serviceaccount=strimzi-operator:strimzi-cluster-operator 2>/dev/null || true
done

info "Waiting for Strimzi operator to be ready..."
kubectl rollout status deployment/strimzi-cluster-operator -n strimzi-operator --timeout=300s

# ─── Step 5: Install Gitea ─────────────────────────────────────────────────────

info "Installing Gitea (local Git server)..."
kubectl apply -k "${SCRIPT_DIR}/gitea"

info "Waiting for Gitea to be ready..."
kubectl rollout status deployment/gitea -n gitea --timeout=120s

GITEA_POD=$(kubectl get pods -n gitea -l app=gitea -o jsonpath='{.items[0].metadata.name}')
info "Waiting for Gitea to finish initialising..."
for i in $(seq 1 30); do
  if kubectl exec -n gitea "${GITEA_POD}" -- curl -sf http://localhost:3000/api/v1/version >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# ─── Step 6: Configure Gitea ───────────────────────────────────────────────────

info "Configuring Gitea user and repository..."

kubectl exec -n gitea "${GITEA_POD}" -- gitea admin user create \
  --username "${GITEA_USER}" \
  --password "${GITEA_PASSWORD}" \
  --email "tutorial@example.com" \
  --must-change-password=false 2>/dev/null || true

info "Waiting for Gitea to be reachable on localhost:${GITEA_HOST_PORT}..."
GITEA_READY=false
for i in $(seq 1 60); do
  if curl -sf "http://localhost:${GITEA_HOST_PORT}/api/v1/version" >/dev/null 2>&1; then
    GITEA_READY=true
    break
  fi
  sleep 3
done

if [[ "${GITEA_READY}" != "true" ]]; then
  error "Gitea is not reachable on localhost:${GITEA_HOST_PORT} after 3 minutes."
  error "Check pod status: kubectl get pods -n gitea"
  exit 1
fi

TOKEN_RESPONSE=$(curl -sf -X POST \
  "http://localhost:${GITEA_HOST_PORT}/api/v1/users/${GITEA_USER}/tokens" \
  -u "${GITEA_USER}:${GITEA_PASSWORD}" \
  -H "Content-Type: application/json" \
  -d '{"name":"setup-token","scopes":["all"]}' 2>/dev/null || echo "{}")

TOKEN=$(echo "${TOKEN_RESPONSE}" | grep -o '"sha1":"[^"]*"' | cut -d'"' -f4)
[[ -z "${TOKEN}" ]] && TOKEN=$(echo "${TOKEN_RESPONSE}" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

if [[ -z "${TOKEN}" ]]; then
  error "Failed to create Gitea access token. Response: ${TOKEN_RESPONSE}"
  exit 1
fi

HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" -X POST \
  "http://localhost:${GITEA_HOST_PORT}/api/v1/user/repos" \
  -H "Authorization: token ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"name\":\"${GITEA_REPO}\",\"auto_init\":true,\"default_branch\":\"main\"}" 2>/dev/null || echo "000")

if [[ "${HTTP_CODE}" == "201" ]]; then
  info "Repository '${GITEA_REPO}' created."
elif [[ "${HTTP_CODE}" == "409" ]]; then
  info "Repository '${GITEA_REPO}' already exists."
else
  warn "Repository creation returned HTTP ${HTTP_CODE} (may already exist)."
fi

# ─── Step 7: Seed the Gitea repository with base manifests ────────────────────

info "Seeding Gitea repository with base manifests..."

WORK_DIR=$(mktemp -d)
trap cleanup EXIT

git clone "http://${GITEA_USER}:${GITEA_PASSWORD}@localhost:${GITEA_HOST_PORT}/${GITEA_USER}/${GITEA_REPO}.git" "${WORK_DIR}/repo" 2>/dev/null

mkdir -p "${WORK_DIR}/repo/manifests"
cp "${SCRIPT_DIR}/base-manifests/"* "${WORK_DIR}/repo/manifests/"

pushd "${WORK_DIR}/repo" >/dev/null
git add .
if git diff --cached --quiet; then
  info "Manifests already present in Gitea repo, skipping commit."
else
  git -c user.name="Tutorial Setup" -c user.email="setup@tutorial.local" commit -m "Initial tutorial manifests"
  git push
  info "Manifests pushed to Gitea."
fi
popd >/dev/null

# ─── Step 8: Configure ArgoCD to access Gitea ─────────────────────────────────

info "Configuring ArgoCD to watch the Gitea repository..."
kubectl apply -f "${SCRIPT_DIR}/argocd/repository-secret.yaml"
kubectl apply -f "${SCRIPT_DIR}/argocd/application.yaml"

# ─── Step 9: Wait for initial sync ────────────────────────────────────────────

info "Waiting for ArgoCD to sync the application (this may take a minute)..."
for i in $(seq 1 60); do
  SYNC_STATUS=$(kubectl get application kafka-tutorial -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
  if [[ "${SYNC_STATUS}" == "Synced" ]]; then
    break
  fi
  sleep 5
done

if [[ "${SYNC_STATUS}" != "Synced" ]]; then
  warn "ArgoCD has not synced yet (status: ${SYNC_STATUS}). It may still be processing."
  warn "Check status with: kubectl get application kafka-tutorial -n argocd"
else
  info "ArgoCD application is synced."
fi

info "Waiting for Kafka cluster to be ready (this may take several minutes)..."
kubectl wait kafka/my-cluster --for=condition=Ready -n kafka-tutorial --timeout=600s 2>/dev/null || \
  warn "Kafka cluster is not yet ready. It may still be starting — check with: kubectl get kafka -n kafka-tutorial"

# ─── Step 10: Print instructions ───────────────────────────────────────────────

ARGOCD_PASSWORD=$(b64decode "$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}')")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
info "Setup complete! Your tutorial environment is ready."
echo ""
echo "  Next step: run the prep script for the lesson you want to start:"
echo "     cd ../01-lesson-1 && ./prep.sh"
echo ""
echo "  ArgoCD Dashboard (open in a separate terminal):"
echo "     kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "     URL:      https://localhost:8080"
echo "     Username: admin"
echo "     Password: ${ARGOCD_PASSWORD}"
echo ""
echo "  Cleanup when done with all lessons:"
echo "     ./teardown.sh"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
