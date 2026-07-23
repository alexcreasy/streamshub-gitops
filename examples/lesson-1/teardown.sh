#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="gitops-lesson-1"

echo "Deleting KinD cluster '${CLUSTER_NAME}'..."
kind delete cluster --name "${CLUSTER_NAME}"
echo "Done. All lesson resources have been removed."
