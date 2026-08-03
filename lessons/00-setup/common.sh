#!/usr/bin/env bash
# Shared configuration for all tutorial lesson scripts.
# Source this file from lesson prep scripts:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../00-setup/common.sh"

CLUSTER_NAME="gitops-tutorial"
GITEA_USER="tutorial-user"
GITEA_PASSWORD="tutorial-password"
GITEA_REPO="streamshub-gitops"
GITEA_HOST_PORT=3001
GITEA_URL="http://localhost:${GITEA_HOST_PORT}"

# KAFKA_NAMESPACE is also the namespace the Strimzi operator is configured to watch.
KAFKA_CLUSTER_NAME="my-cluster"
KAFKA_NAMESPACE="kafka-tutorial"

KAFKA_STAGING_NAMESPACE="kafka-staging"
KAFKA_PRODUCTION_NAMESPACE="kafka-production"
