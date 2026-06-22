#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="gitops-tutorial"

echo "Deleting KinD cluster '${CLUSTER_NAME}'..."
kind delete cluster --name "${CLUSTER_NAME}"
echo "Done. All tutorial resources have been removed."
