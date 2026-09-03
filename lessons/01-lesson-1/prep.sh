#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../00-setup/common.sh
source "${SCRIPT_DIR}/../00-setup/common.sh"

# ─── Step 1: Validate infrastructure ──────────────────────────────────────────

info "Validating tutorial infrastructure..."

require_cluster

if ! kubectl get kafka "${KAFKA_CLUSTER_NAME}" -n "${KAFKA_NAMESPACE}" &>/dev/null; then
  error "Kafka cluster '${KAFKA_CLUSTER_NAME}' not found in namespace '${KAFKA_NAMESPACE}'."
  error "Please run the setup script first: ../00-setup/setup.sh"
  exit 1
fi

require_gitea

info "Infrastructure checks passed."

# ─── Step 2: Reset Gitea repo to lesson-1 starting state ──────────────────────

info "Resetting Gitea repository to lesson-1 starting state..."

seed_gitea_repo "${SCRIPT_DIR}/lesson-manifests" "Reset to lesson-1 starting state"
TARGET_REVISION="${GITEA_REPO_REVISION}"
info "Lesson-1 starting state pushed to Gitea."

# ─── Step 3: Wait for ArgoCD sync ─────────────────────────────────────────────

info "Waiting for ArgoCD to sync..."
wait_for_argocd_sync "kafka-tutorial" "${TARGET_REVISION}"

# ─── Step 4: Print starting instructions ──────────────────────────────────────

ARGOCD_PASSWORD=$(b64decode "$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}')")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
info "Lesson 1 is ready. Open README.md and follow the lesson steps."
echo ""
echo "  Gitea (your Git server):  ${GITEA_URL}"
echo "  Username: ${GITEA_USER}   Password: ${GITEA_PASSWORD}"
echo ""
echo "  ArgoCD Dashboard (open in a separate terminal):"
echo "     kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "     URL:      https://localhost:8080"
echo "     Username: admin"
echo "     Password: ${ARGOCD_PASSWORD}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
