#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="gitops-tutorial"
RUNTIME="${RUNTIME:-kind}"
while [[ $# -gt 0 ]]; do
  case $1 in
    --runtime) RUNTIME="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ "${RUNTIME}" == "kind" ]]; then
  echo "Deleting KinD cluster '${CLUSTER_NAME}'..."
  kind delete cluster --name "${CLUSTER_NAME}"
elif [[ "${RUNTIME}" == "minikube" ]]; then
  echo "Deleting Minikube cluster '${CLUSTER_NAME}'..."
  minikube delete --profile "${CLUSTER_NAME}"
else
  echo "Unknown runtime '${RUNTIME}'. Use 'kind' (default) or 'minikube'." >&2
  exit 1
fi

echo "Done. All tutorial resources have been removed."
