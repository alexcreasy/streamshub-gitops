#!/usr/bin/env bash
# Shared configuration and functions for all tutorial lesson scripts.
# Source this file from lesson prep scripts:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../00-setup/common.sh"

CLUSTER_NAME="gitops-tutorial"
GITEA_USER="tutorial-user"
GITEA_PASSWORD="tutorial-password"
GITEA_REPO="streamshub-gitops"
GITEA_HOST_PORT=3001
GITEA_URL="http://localhost:${GITEA_HOST_PORT}"

KAFKA_CLUSTER_NAME="my-cluster"
KAFKA_NAMESPACE="kafka-tutorial"

KAFKA_STAGING_NAMESPACE="kafka-staging"
KAFKA_PRODUCTION_NAMESPACE="kafka-production"

# ─── Logging ──────────────────────────────────────────────────────────────────

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }
b64decode() { echo "$1" | base64 -d 2>/dev/null || echo "$1" | base64 -D 2>/dev/null; }

# ─── Temp directory cleanup (use with: trap cleanup EXIT) ─────────────────────

cleanup() {
  if [[ -n "${WORK_DIR:-}" ]]; then
    rm -rf "${WORK_DIR}"
  fi
}

# ─── Precondition checks ─────────────────────────────────────────────────────

require_cluster() {
  if ! kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null 2>&1; then
    error "KinD cluster '${CLUSTER_NAME}' is not running."
    error "Please run the setup script first: ../00-setup/setup.sh"
    exit 1
  fi
}

require_gitea() {
  if ! curl -sf "${GITEA_URL}/api/v1/version" >/dev/null 2>&1; then
    error "Gitea is not reachable on ${GITEA_URL}."
    error "Please run the setup script first: ../00-setup/setup.sh"
    exit 1
  fi
}

require_strimzi() {
  if ! kubectl get deployment strimzi-cluster-operator -n strimzi-operator &>/dev/null; then
    error "Strimzi operator not found in namespace 'strimzi-operator'."
    error "Please run the setup script first: ../00-setup/setup.sh"
    exit 1
  fi
}

# ─── Operational helpers ─────────────────────────────────────────────────────

# Usage: remove_strimzi_finalizers <namespace> [<namespace> ...]
remove_strimzi_finalizers() {
  for ns in "$@"; do
    for cr_type in kafka kafkanodepool kafkatopic; do
      kubectl get "${cr_type}" -n "${ns}" -o name 2>/dev/null | \
        xargs -r -I{} kubectl patch {} -n "${ns}" \
          --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    done
  done
}

# Usage: wait_for_argocd_sync <app_name> <target_revision>
wait_for_argocd_sync() {
  local app="$1" target_rev="$2"

  kubectl annotate application "${app}" -n argocd \
    argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true

  local sync_status="Unknown" current_rev
  for _ in $(seq 1 24); do
    current_rev=$(kubectl get application "${app}" -n argocd \
      -o jsonpath='{.status.sync.revision}' 2>/dev/null || echo "")
    sync_status=$(kubectl get application "${app}" -n argocd \
      -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    if [[ "${current_rev}" == "${target_rev}" && "${sync_status}" == "Synced" ]]; then
      break
    fi
    sleep 5
  done

  if [[ "${sync_status}" != "Synced" ]]; then
    warn "Application '${app}' has not synced yet (status: ${sync_status})."
    warn "Check with: kubectl get application ${app} -n argocd"
  else
    info "Application '${app}' is synced."
  fi
}
