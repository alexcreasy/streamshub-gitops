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

# ─── Step 1: Validate infrastructure ──────────────────────────────────────────

info "Validating tutorial infrastructure..."

if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  error "KinD cluster '${CLUSTER_NAME}' is not running."
  error "Please run the setup script first: ../00-setup/setup.sh"
  exit 1
fi

if ! kubectl get kafka my-cluster -n kafka-tutorial &>/dev/null; then
  error "Kafka cluster 'my-cluster' not found in namespace 'kafka-tutorial'."
  error "Please run the setup script first: ../00-setup/setup.sh"
  exit 1
fi

if ! curl -sf "http://localhost:${GITEA_HOST_PORT}/api/v1/version" >/dev/null 2>&1; then
  error "Gitea is not reachable on localhost:${GITEA_HOST_PORT}."
  error "Please run the setup script first: ../00-setup/setup.sh"
  exit 1
fi

info "Infrastructure checks passed."

# ─── Step 2: Reset Gitea repo to lesson-1 starting state ──────────────────────

info "Resetting Gitea repository to lesson-1 starting state..."

WORK_DIR=$(mktemp -d)
trap cleanup EXIT

git clone "http://${GITEA_USER}:${GITEA_PASSWORD}@localhost:${GITEA_HOST_PORT}/${GITEA_USER}/${GITEA_REPO}.git" "${WORK_DIR}/repo" 2>/dev/null

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
echo "  Gitea (your Git server):  http://localhost:${GITEA_HOST_PORT}"
echo "  Username: ${GITEA_USER}   Password: ${GITEA_PASSWORD}"
echo ""
echo "  ArgoCD Dashboard (open in a separate terminal):"
echo "     kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "     URL:      https://localhost:8080"
echo "     Username: admin"
echo "     Password: ${ARGOCD_PASSWORD}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
