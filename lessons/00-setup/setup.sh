#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=downstream-setup.sh
source "${SCRIPT_DIR}/downstream/downstream-setup.sh"
trap cleanup EXIT

for arg in "$@"; do
  case "$arg" in
    --create-cluster) ;;
    *)
      error "Unknown option: $arg"
      exit 1
      ;;
  esac
done
resolve_flag CREATE_CLUSTER --create-cluster "$@"
CREATE_CLUSTER_MODE="$RESOLVED_FLAG"

# ─── Step 1: Check prerequisites ───────────────────────────────────────────────

info "Checking prerequisites..."
REQUIRED_CMDS=(kubectl git curl)
[[ "$CREATE_CLUSTER_MODE" == "true" ]] && REQUIRED_CMDS+=(kind)
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" &>/dev/null; then
    error "'$cmd' is required but not found in PATH."
    exit 1
  fi
done

if [[ "$CREATE_CLUSTER_MODE" == "true" ]]; then
  if docker info &>/dev/null 2>&1; then
    :
  elif podman info &>/dev/null 2>&1; then
    :
  else
    error "Neither Docker nor Podman is running. Please start your container runtime."
    exit 1
  fi
fi

info "All prerequisites satisfied."

# ─── Step 2: Set up the cluster ────────────────────────────────────────────────

if [[ "$CREATE_CLUSTER_MODE" == "true" ]]; then
  if kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null 2>&1; then
    info "KinD cluster '${CLUSTER_NAME}' already exists, skipping creation."
  else
    info "Creating KinD cluster '${CLUSTER_NAME}'..."
    kind create cluster --name "${CLUSTER_NAME}" --config "${SCRIPT_DIR}/kind-config.yaml"
  fi

  kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null 2>&1
  info "Cluster is ready."
else
  CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || echo '')"
  info "Using existing cluster (current kubectl context: ${CURRENT_CONTEXT:-none})..."
  if ! kubectl cluster-info >/dev/null 2>&1; then
    error "No reachable Kubernetes cluster for the current kubectl context."
    error "Switch to the right context first (kubectl config use-context ...), or pass --create-cluster to provision a local KinD cluster."
    exit 1
  fi
  info "Cluster is ready."
fi

# ─── Step 3: Install ArgoCD ────────────────────────────────────────────────────

info "Installing ArgoCD..."
kubectl apply -k "${ARGOCD_KUSTOMIZE_DIR}" --server-side 2>/dev/null || \
  kubectl apply -k "${ARGOCD_KUSTOMIZE_DIR}" --server-side

info "Waiting for ArgoCD to be ready (this may take a few minutes)..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout=300s

# ─── Step 4: Install Strimzi operator ──────────────────────────────────────────

info "Installing Strimzi operator..."
kubectl apply -k "${SCRIPT_DIR}/strimzi" --server-side 2>/dev/null || \
  kubectl apply -k "${SCRIPT_DIR}/strimzi" --server-side

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

declare -f gitea_post_install_hook >/dev/null && gitea_post_install_hook
save_gitea_config

# ─── Step 6: Configure Gitea ───────────────────────────────────────────────────

info "Configuring Gitea user and repository..."

kubectl exec -n gitea "${GITEA_POD}" -- gitea admin user create \
  --username "${GITEA_USER}" \
  --password "${GITEA_PASSWORD}" \
  --email "tutorial@example.com" \
  --must-change-password=false 2>/dev/null || true

info "Waiting for Gitea to be reachable at ${GITEA_URL}..."
GITEA_READY=false
for i in $(seq 1 10); do
  if curl -sf "${GITEA_URL}/api/v1/version" >/dev/null 2>&1; then
    GITEA_READY=true
    break
  fi
  sleep 3
done

# BYO clusters (not --create-cluster, not already exposed downstream, e.g. via a
# Route) have no automatic path from localhost to the Gitea NodePort. Rather than
# require the user to have a port-forward running before setup.sh even starts,
# start one ourselves just long enough to finish configuring Gitea (Steps 6-7)
# — everything after that talks to Gitea in-cluster, not from this host.
if [[ "${GITEA_READY}" != "true" && "$CREATE_CLUSTER_MODE" != "true" && "$GITEA_EXPOSURE_MANAGED" != "true" ]]; then
  info "Gitea isn't reachable yet — starting a temporary port-forward to configure it..."
  kubectl port-forward svc/gitea-http -n gitea "${GITEA_HOST_PORT}:3000" >/dev/null 2>&1 &
  GITEA_PORT_FORWARD_PID=$!
  for i in $(seq 1 20); do
    if curl -sf "${GITEA_URL}/api/v1/version" >/dev/null 2>&1; then
      GITEA_READY=true
      break
    fi
    sleep 3
  done
fi

if [[ "${GITEA_READY}" != "true" ]]; then
  error "Gitea is not reachable at ${GITEA_URL}."
  error "Check pod status: kubectl get pods -n gitea"
  if [[ -n "${GITEA_PORT_FORWARD_PID:-}" ]]; then
    error "A temporary port-forward was attempted and didn't help — is port ${GITEA_HOST_PORT} already in use locally by something else?"
  fi
  exit 1
fi

TOKEN_RESPONSE=$(curl -sf -X POST \
  "${GITEA_URL}/api/v1/users/${GITEA_USER}/tokens" \
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
  "${GITEA_URL}/api/v1/user/repos" \
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

git clone "$(gitea_clone_url)" "${WORK_DIR}/repo" 2>/dev/null

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

if [[ -n "${GITEA_PORT_FORWARD_PID:-}" ]]; then
  info "Stopping temporary port-forward..."
  kill "${GITEA_PORT_FORWARD_PID}" 2>/dev/null || true
  wait "${GITEA_PORT_FORWARD_PID}" 2>/dev/null || true
  GITEA_PORT_FORWARD_PID=""
fi

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
kubectl wait "kafka/${KAFKA_CLUSTER_NAME}" --for=condition=Ready -n "${KAFKA_NAMESPACE}" --timeout=600s 2>/dev/null || \
  warn "Kafka cluster is not yet ready. It may still be starting — check with: kubectl get kafka -n ${KAFKA_NAMESPACE}"

# ─── Step 10: Print instructions ───────────────────────────────────────────────

ARGOCD_PASSWORD=$(b64decode "$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}')")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
info "Setup complete! Your tutorial environment is ready."
echo ""
if [[ "$CREATE_CLUSTER_MODE" != "true" ]]; then
  echo "  This is running against your existing cluster's current kubectl context."
  if [[ "$GITEA_EXPOSURE_MANAGED" != "true" ]]; then
    echo "  Keep Gitea reachable at ${GITEA_URL} for the whole tutorial, e.g.:"
    echo "     kubectl port-forward svc/gitea-http -n gitea ${GITEA_HOST_PORT}:3000"
  else
    echo "  Gitea is reachable at ${GITEA_URL}."
  fi
  echo ""
fi
echo "  Next step: run the prep script for the lesson you want to start:"
echo "     cd ../01-lesson-1 && ./prep.sh"
echo ""
echo "  ArgoCD Dashboard (open in a separate terminal):"
echo "     kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "     URL:      https://localhost:8080"
echo "     Username: admin"
echo "     Password: ${ARGOCD_PASSWORD}"
echo ""
if [[ "$CREATE_CLUSTER_MODE" == "true" ]]; then
  echo "  Cleanup when done with all lessons:"
  echo "     ./teardown.sh --delete-cluster"
else
  echo "  Cleanup when done with all lessons:"
  echo "     ./teardown.sh"
fi
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
