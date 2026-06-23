#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="gitops-tutorial"
CLUSTER_PROVIDER="${CLUSTER_PROVIDER:-}"

# Auto-detect which provider owns the cluster
if [[ -z "${CLUSTER_PROVIDER}" ]]; then
  if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    CLUSTER_PROVIDER="kind"
  elif command -v minikube &>/dev/null; then
    CLUSTER_PROVIDER="minikube"
  else
    echo "Could not detect cluster provider. Set CLUSTER_PROVIDER=kind or CLUSTER_PROVIDER=minikube."
    exit 1
  fi
fi

if [[ "${CLUSTER_PROVIDER}" == "kind" ]]; then
  echo "Deleting KinD cluster '${CLUSTER_NAME}'..."
  kind delete cluster --name "${CLUSTER_NAME}"
elif [[ "${CLUSTER_PROVIDER}" == "minikube" ]]; then
  echo "Removing tutorial resources from Minikube cluster..."
  kubectl delete application kafka-tutorial -n argocd 2>/dev/null || true
  for ns in kafka-tutorial gitea argocd strimzi-operator; do
    kubectl delete namespace "${ns}" 2>/dev/null || true
  done
fi

echo "Done. All tutorial resources have been removed."
