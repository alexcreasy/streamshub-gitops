#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../00-setup/common.sh
source "${SCRIPT_DIR}/../00-setup/common.sh"

# ─── Step 1: Validate infrastructure ──────────────────────────────────────────

info "Validating tutorial infrastructure..."
require_cluster
require_strimzi
require_gitea
info "Infrastructure checks passed."

# ─── Step 2: Clean up previous lesson state ───────────────────────────────────

info "Cleaning up previous lesson state..."

# Remove the lesson-1 ArgoCD Application (no cascade finalizer, so this is instant).
kubectl delete application "${KAFKA_NAMESPACE}" -n argocd --ignore-not-found 2>/dev/null || true

# Also remove any lesson-2 Applications from a previous run of this script.
kubectl delete application "${KAFKA_STAGING_NAMESPACE}" "${KAFKA_PRODUCTION_NAMESPACE}" -n argocd --ignore-not-found 2>/dev/null || true

# Start namespace deletion first (non-blocking), then patch away Strimzi finalizers on the
# now-terminating resources. Doing it in this order avoids a race where the Strimzi operator
# re-adds finalizers to live (non-terminating) resources before the namespace delete begins.
kubectl delete namespace "${KAFKA_NAMESPACE}" "${KAFKA_STAGING_NAMESPACE}" "${KAFKA_PRODUCTION_NAMESPACE}" \
  --ignore-not-found --wait=false
remove_strimzi_finalizers "${KAFKA_NAMESPACE}" "${KAFKA_STAGING_NAMESPACE}" "${KAFKA_PRODUCTION_NAMESPACE}"

for ns in "${KAFKA_NAMESPACE}" "${KAFKA_STAGING_NAMESPACE}" "${KAFKA_PRODUCTION_NAMESPACE}"; do
  kubectl wait --for=delete "namespace/${ns}" --timeout=120s 2>/dev/null || true
done

info "Previous lesson state cleaned up."

# ─── Step 3: Seed the Gitea repository with the overlay structure ─────────────

info "Resetting Gitea repository to lesson-2 starting state..."

seed_gitea_repo "${SCRIPT_DIR}/lesson-manifests" "Reset to lesson-2 starting state"
TARGET_REVISION="${GITEA_REPO_REVISION}"
info "Lesson-2 starting state pushed to Gitea."

# ─── Step 4: Create ArgoCD Applications for staging and production ─────────────

info "Creating ArgoCD applications for staging and production..."

kubectl apply -f "${SCRIPT_DIR}/argocd/staging/"
kubectl apply -f "${SCRIPT_DIR}/argocd/production/"

# ─── Step 5: Wait for both applications to sync ───────────────────────────────

info "Waiting for ArgoCD to sync both applications..."

for app in "${KAFKA_STAGING_NAMESPACE}" "${KAFKA_PRODUCTION_NAMESPACE}"; do
  wait_for_argocd_sync "${app}" "${TARGET_REVISION}"
done

info "Waiting for Kafka clusters to be ready (this may take a few minutes)..."
kubectl wait "kafka/${KAFKA_CLUSTER_NAME}" --for=condition=Ready -n "${KAFKA_STAGING_NAMESPACE}" --timeout=600s 2>/dev/null &
kubectl wait "kafka/${KAFKA_CLUSTER_NAME}" --for=condition=Ready -n "${KAFKA_PRODUCTION_NAMESPACE}" --timeout=600s 2>/dev/null &
wait

# ─── Step 6: Print starting instructions ──────────────────────────────────────

ARGOCD_PASSWORD=$(b64decode "$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}')")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
info "Lesson 2 is ready. Open README.md and follow the lesson steps."
echo ""
echo "  Clone the repo to follow along:"
echo "     git clone http://${GITEA_USER}:${GITEA_PASSWORD}@localhost:${GITEA_HOST_PORT}/${GITEA_USER}/${GITEA_REPO}.git /tmp/gitops-lesson-2"
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
