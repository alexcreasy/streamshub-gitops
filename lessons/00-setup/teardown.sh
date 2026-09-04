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
    -n argocd --ignore-not-found || true

  kubectl delete namespace "${KAFKA_NAMESPACE}" "${KAFKA_STAGING_NAMESPACE}" "${KAFKA_PRODUCTION_NAMESPACE}" \
    --ignore-not-found --wait=false || true

  # The Strimzi Topic/Entity Operator can re-add its finalizer on a reconcile that
  # races with the namespace terminating, so clearing finalizers is retried rather
  # than done once. Deleting the Strimzi operator/CRDs below is only safe once
  # these namespaces are actually gone — if they're not, nothing will ever be able
  # to finish removing a re-added finalizer once the operator managing it is gone.
  KAFKA_NAMESPACES_GONE=false
  for attempt in $(seq 1 8); do
    remove_strimzi_finalizers "${KAFKA_NAMESPACE}" "${KAFKA_STAGING_NAMESPACE}" "${KAFKA_PRODUCTION_NAMESPACE}"
    STILL_PRESENT=false
    for ns in "${KAFKA_NAMESPACE}" "${KAFKA_STAGING_NAMESPACE}" "${KAFKA_PRODUCTION_NAMESPACE}"; do
      kubectl get namespace "${ns}" &>/dev/null && STILL_PRESENT=true
    done
    if [[ "${STILL_PRESENT}" != "true" ]]; then
      KAFKA_NAMESPACES_GONE=true
      break
    fi
    sleep 15
  done

  if [[ "${KAFKA_NAMESPACES_GONE}" != "true" ]]; then
    error "The Kafka namespaces did not finish terminating."
    error "Not removing the Strimzi operator/CRDs yet — doing so now could orphan"
    error "any Kafka custom resources still stuck mid-deletion with no operator left"
    error "to finish removing their finalizers. Re-run ./teardown.sh to retry."
    exit 1
  fi

  kubectl delete -k "${SCRIPT_DIR}/gitea" --ignore-not-found || true
  kubectl delete -k "${SCRIPT_DIR}/strimzi" --ignore-not-found || true
  kubectl delete -k "${SCRIPT_DIR}/argocd" --ignore-not-found || true

  REMAINING=""
  for ns in "${KAFKA_NAMESPACE}" "${KAFKA_STAGING_NAMESPACE}" "${KAFKA_PRODUCTION_NAMESPACE}" gitea strimzi-operator argocd; do
    kubectl get namespace "${ns}" &>/dev/null && REMAINING="${REMAINING} ${ns}"
  done

  if [[ -n "${REMAINING}" ]]; then
    warn "These namespaces are still present:${REMAINING}"
    warn "A kubectl command likely failed partway through (e.g. a dropped connection) —"
    warn "check your connection to the cluster and re-run ./teardown.sh."
    exit 1
  fi

  info "Done. Tutorial resources have been removed; the cluster itself was left running."
fi
