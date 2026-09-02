#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

for arg in "$@"; do
  case "$arg" in
    --delete-cluster) ;;
    *)
      error "Unknown option: $arg"
      exit 1
      ;;
  esac
done
resolve_flag DELETE_CLUSTER --delete-cluster "$@"
DELETE_CLUSTER_MODE="$RESOLVED_FLAG"

if [[ "$DELETE_CLUSTER_MODE" == "true" ]]; then
  info "Deleting KinD cluster '${CLUSTER_NAME}'..."
  kind delete cluster --name "${CLUSTER_NAME}"
  info "Done. All tutorial resources have been removed."
else
  info "Removing tutorial resources from the current kubectl context ($(kubectl config current-context 2>/dev/null || echo 'none'))..."
  info "(Pass --delete-cluster instead if this cluster was created with 'setup.sh --create-cluster'.)"

  kubectl delete application "${KAFKA_NAMESPACE}" "${KAFKA_STAGING_NAMESPACE}" "${KAFKA_PRODUCTION_NAMESPACE}" \
    -n argocd --ignore-not-found 2>/dev/null || true

  kubectl delete namespace "${KAFKA_NAMESPACE}" "${KAFKA_STAGING_NAMESPACE}" "${KAFKA_PRODUCTION_NAMESPACE}" \
    --ignore-not-found --wait=false 2>/dev/null || true
  remove_strimzi_finalizers "${KAFKA_NAMESPACE}" "${KAFKA_STAGING_NAMESPACE}" "${KAFKA_PRODUCTION_NAMESPACE}"
  for ns in "${KAFKA_NAMESPACE}" "${KAFKA_STAGING_NAMESPACE}" "${KAFKA_PRODUCTION_NAMESPACE}"; do
    kubectl wait --for=delete "namespace/${ns}" --timeout=120s 2>/dev/null || true
  done

  kubectl delete -k "${SCRIPT_DIR}/gitea" --ignore-not-found 2>/dev/null || true
  kubectl delete -k "${SCRIPT_DIR}/strimzi" --ignore-not-found 2>/dev/null || true
  kubectl delete -k "${SCRIPT_DIR}/argocd" --ignore-not-found 2>/dev/null || true

  info "Done. Tutorial resources have been removed; the cluster itself was left running."
fi
