#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="gitops-tutorial"
GITEA_USER="tutorial-user"
GITEA_PASSWORD="tutorial-password"
GITEA_REPO="streamshub-gitops"
GITEA_HOST_PORT=3001
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="${RUNTIME:-kind}"
while [[ $# -gt 0 ]]; do
  case $1 in
    --runtime) RUNTIME="$2"; shift 2 ;;
    *) shift ;;
  esac
done

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }
b64decode() { echo "$1" | base64 -d 2>/dev/null || echo "$1" | base64 -D 2>/dev/null; }

cleanup() {
  if [[ -n "${WORK_DIR:-}" ]]; then
    rm -rf "${WORK_DIR}"
  fi
  if [[ -n "${GITEA_PF_PID:-}" ]]; then
    kill "${GITEA_PF_PID}" 2>/dev/null || true
  fi
}

# ─── Step 1: Validate infrastructure ──────────────────────────────────────────

info "Validating tutorial infrastructure..."

if [[ "${RUNTIME}" == "kind" ]]; then
  if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    error "KinD cluster '${CLUSTER_NAME}' is not running."
    error "Please run the setup script first: ../00-setup/setup.sh"
    exit 1
  fi
elif [[ "${RUNTIME}" == "minikube" ]]; then
  if ! minikube status --profile "${CLUSTER_NAME}" &>/dev/null; then
    error "Minikube cluster '${CLUSTER_NAME}' is not running."
    error "Please run the setup script first: ../00-setup/setup.sh --runtime minikube"
    exit 1
  fi
else
  error "Unknown runtime '${RUNTIME}'. Use 'kind' (default) or 'minikube'."
  exit 1
fi

if ! kubectl get kafka my-cluster -n kafka-tutorial &>/dev/null; then
  error "Kafka cluster 'my-cluster' not found in namespace 'kafka-tutorial'."
  error "Please run the setup script first: ../00-setup/setup.sh"
  exit 1
fi

GITEA_URL="http://localhost:${GITEA_HOST_PORT}"
if [[ "${RUNTIME}" != "kind" ]]; then
  info "Starting port-forward: Gitea → localhost:${GITEA_HOST_PORT}..."
  kubectl port-forward svc/gitea-http "${GITEA_HOST_PORT}:3000" -n gitea &
  GITEA_PF_PID=$!
  sleep 2
fi

if ! curl -sf "${GITEA_URL}/api/v1/version" >/dev/null 2>&1; then
  error "Gitea is not reachable at ${GITEA_URL}."
  if [[ "${RUNTIME}" == "kind" ]]; then
    error "Please run the setup script first: ../00-setup/setup.sh"
  else
    error "Please run the setup script first: ../00-setup/setup.sh --runtime ${RUNTIME}"
  fi
  exit 1
fi

info "Infrastructure checks passed."

# ─── Step 2: Reset Gitea repo to lesson-1 starting state ──────────────────────

info "Resetting Gitea repository to lesson-1 starting state..."

WORK_DIR=$(mktemp -d)
trap cleanup EXIT

GITEA_AUTHORITY="${GITEA_URL#http://}"
git clone "http://${GITEA_USER}:${GITEA_PASSWORD}@${GITEA_AUTHORITY}/${GITEA_USER}/${GITEA_REPO}.git" "${WORK_DIR}/repo" 2>/dev/null

rm -rf "${WORK_DIR}/repo/manifests"
mkdir -p "${WORK_DIR}/repo/manifests"
cp "${SCRIPT_DIR}/lesson-manifests/"* "${WORK_DIR}/repo/manifests/"

pushd "${WORK_DIR}/repo" >/dev/null
git add .
if git diff --cached --quiet; then
  info "Gitea repo is already in lesson-1 starting state, skipping commit."
else
  git -c user.name="Tutorial Setup" -c user.email="setup@tutorial.local" commit -m "Reset to lesson-1 starting state"
  git push
  info "Lesson-1 starting state pushed to Gitea."
fi
TARGET_REVISION=$(git rev-parse HEAD)
popd >/dev/null

# ─── Step 3: Wait for ArgoCD sync ─────────────────────────────────────────────

info "Waiting for ArgoCD to sync..."

# Trigger an immediate refresh so ArgoCD picks up the new commit without waiting up to 3 minutes.
kubectl annotate application kafka-tutorial -n argocd argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true

SYNC_STATUS="Unknown"
for i in $(seq 1 24); do
  CURRENT_REVISION=$(kubectl get application kafka-tutorial -n argocd -o jsonpath='{.status.sync.revision}' 2>/dev/null || echo "")
  SYNC_STATUS=$(kubectl get application kafka-tutorial -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
  if [[ "${CURRENT_REVISION}" == "${TARGET_REVISION}" && "${SYNC_STATUS}" == "Synced" ]]; then
    break
  fi
  sleep 5
done

if [[ "${SYNC_STATUS}" != "Synced" ]]; then
  warn "ArgoCD has not synced yet (status: ${SYNC_STATUS})."
  warn "Check status with: kubectl get application kafka-tutorial -n argocd"
else
  info "ArgoCD application is synced."
fi

# ─── Step 4: Print starting instructions ──────────────────────────────────────

ARGOCD_PASSWORD=$(b64decode "$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}')")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
info "Lesson 1 is ready. Open README.md and follow the lesson steps."
echo ""
echo "  Gitea (your Git server):  ${GITEA_URL}"
echo "  Username: ${GITEA_USER}   Password: ${GITEA_PASSWORD}"
if [[ "${RUNTIME}" != "kind" ]]; then
  echo ""
  echo "  Note: to push git changes during the lesson, keep a port-forward running:"
  echo "     kubectl port-forward svc/gitea-http ${GITEA_HOST_PORT}:3000 -n gitea"
fi
echo ""
echo "  ArgoCD Dashboard (open in a separate terminal):"
echo "     kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "     URL:      https://localhost:8080"
echo "     Username: admin"
echo "     Password: ${ARGOCD_PASSWORD}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
