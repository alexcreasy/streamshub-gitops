#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../00-setup/common.sh
source "${SCRIPT_DIR}/../00-setup/common.sh"
TUTORIAL_WORK_DIR=""

# ─── Step 1: Validate infrastructure ──────────────────────────────────────────

info "Validating tutorial infrastructure..."
require_cluster
load_gitea_config
require_strimzi
require_gitea
info "Infrastructure checks passed."

# ─── Step 2: Clean up previous lesson state ──────────────────────────────────

info "Cleaning up previous lesson state..."

kubectl delete application "${KAFKA_NAMESPACE}" "${KAFKA_STAGING_NAMESPACE}" "${KAFKA_PRODUCTION_NAMESPACE}" \
  -n argocd --ignore-not-found 2>/dev/null || true

# Start namespace deletion first (non-blocking), then patch away Strimzi finalizers on the
# now-terminating resources. Doing it in this order avoids a race where the Strimzi operator
# re-adds finalizers to live (non-terminating) resources before the namespace delete begins.
kubectl delete namespace "${KAFKA_STAGING_NAMESPACE}" "${KAFKA_PRODUCTION_NAMESPACE}" \
  --ignore-not-found --wait=false
remove_strimzi_finalizers "${KAFKA_NAMESPACE}" "${KAFKA_STAGING_NAMESPACE}" "${KAFKA_PRODUCTION_NAMESPACE}"

for ns in "${KAFKA_STAGING_NAMESPACE}" "${KAFKA_PRODUCTION_NAMESPACE}"; do
  kubectl wait --for=delete "namespace/${ns}" --timeout=120s 2>/dev/null || true
done

info "Previous lesson state cleaned up."

# ─── Step 3: Seed the Gitea repository with lesson-3 starting state ──────────

info "Resetting Gitea repository to lesson-3 starting state..."

TUTORIAL_WORK_DIR=$(mktemp -d)
trap cleanup EXIT

git clone "$(gitea_clone_url)" "${TUTORIAL_WORK_DIR}/repo" 2>/dev/null

rm -rf "${TUTORIAL_WORK_DIR}/repo/manifests"
mkdir -p "${TUTORIAL_WORK_DIR}/repo/manifests"
cp "${SCRIPT_DIR}/lesson-manifests/"* "${TUTORIAL_WORK_DIR}/repo/manifests/"

pushd "${TUTORIAL_WORK_DIR}/repo" >/dev/null
git add .
if git diff --cached --quiet; then
  info "Gitea repo is already in lesson-3 starting state, skipping commit."
else
  git -c user.name="Tutorial Setup" -c user.email="setup@tutorial.local" commit -m "Reset to lesson-3 starting state"
  git push
  info "Lesson-3 starting state pushed to Gitea."
fi
TARGET_REVISION=$(git rev-parse HEAD)
popd >/dev/null

# ─── Step 4: Create ArgoCD Application kafka-tutorial ─────────────────────────

info "Creating ArgoCD application ${KAFKA_NAMESPACE}..."

kubectl apply -f "${SCRIPT_DIR}/argocd/application.yaml"

# ─── Step 5: Wait for ArgoCD to sync ──────────────────────────────────────────

info "Waiting for ArgoCD to sync..."
wait_for_argocd_sync "${KAFKA_NAMESPACE}" "${TARGET_REVISION}"

# ─── Step 6: Wait for Kafka cluster to be ready ────────────────────────────────

info "Waiting for Kafka cluster to be ready (this may take a few minutes)..."
kubectl wait kafka/${KAFKA_CLUSTER_NAME} --for=condition=Ready -n "${KAFKA_NAMESPACE}" --timeout=600s 2>/dev/null || \
  warn "Kafka cluster is not yet ready. Check with: kubectl get kafka -n ${KAFKA_NAMESPACE}"

# ─── Step 7: Wait for KafkaTopic to be ready ──────────────────────────────────

info "Waiting for KafkaTopic to be ready..."
kubectl wait kafkatopic/my-first-topic --for=condition=Ready -n "${KAFKA_NAMESPACE}" --timeout=120s 2>/dev/null || \
  warn "KafkaTopic is not yet ready. Check with: kubectl get kafkatopic -n ${KAFKA_NAMESPACE}"

# ─── Step 8: Print starting instructions ──────────────────────────────────────

ARGOCD_PASSWORD=$(b64decode "$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}')")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
info "Lesson 3 is ready. Open README.md and follow the lesson steps."
echo ""
echo "  Clone the repo to follow along:"
echo "     git clone $(gitea_clone_url) /tmp/gitops-lesson-3"
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
