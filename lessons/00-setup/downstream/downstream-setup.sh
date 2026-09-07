#!/usr/bin/env bash
# Downstream (OpenShift) customization for setup.sh. Sourced once, early —
# its mere presence is the OpenShift signal, no live detection needed.
# Not meant to be shipped in the open-source upstream tutorial.

ARGOCD_KUSTOMIZE_DIR="${SCRIPT_DIR}/downstream/argocd-openshift"

gitea_post_install_hook() {
  info "Exposing Gitea via an OpenShift Route..."
  kubectl apply -k "${SCRIPT_DIR}/downstream/gitea-openshift"

  local route_host=""
  for i in $(seq 1 30); do
    route_host=$(kubectl get route gitea -n gitea -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    [[ -n "$route_host" ]] && break
    sleep 2
  done

  if [[ -z "$route_host" ]]; then
    error "Could not determine the Gitea route hostname."
    exit 1
  fi

  GITEA_URL="http://${route_host}"
  GITEA_EXPOSURE_MANAGED=true
}
