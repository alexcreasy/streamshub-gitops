#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="gitops-tutorial"
GITEA_USER="tutorial-user"
GITEA_PASSWORD="tutorial-password"
GITEA_REPO="streamshub-gitops"
GITEA_HOST_PORT=3001
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }
b64decode() { echo "$1" | base64 -d 2>/dev/null || echo "$1" | base64 -D 2>/dev/null; }

cleanup() {
  if [[ -n "${WORK_DIR:-}" ]]; then
    rm -rf "${WORK_DIR}"
  fi
}

# ─── Step 1: Validate infrastructure ──────────────────────────────────────────

info "Validating tutorial infrastructure..."

if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  error "KinD cluster '${CLUSTER_NAME}' is not running."
  error "Please run the setup script first: ../00-setup/setup.sh"
  exit 1
fi

if ! kubectl get deployment strimzi-cluster-operator -n strimzi-operator &>/dev/null; then
  error "Strimzi operator not found in namespace 'strimzi-operator'."
  error "Please run the setup script first: ../00-setup/setup.sh"
  exit 1
fi

if ! curl -sf "http://localhost:${GITEA_HOST_PORT}/api/v1/version" >/dev/null 2>&1; then
  error "Gitea is not reachable on localhost:${GITEA_HOST_PORT}."
  error "Please run the setup script first: ../00-setup/setup.sh"
  exit 1
fi

info "Infrastructure checks passed."

# ─── Step 2: Clean up previous lesson state ───────────────────────────────────

info "Cleaning up previous lesson state..."

# Remove the lesson-1 ArgoCD Application (no cascade finalizer, so this is instant).
kubectl delete application kafka-tutorial -n argocd --ignore-not-found 2>/dev/null || true

# Also remove any lesson-2 Applications from a previous run of this script.
kubectl delete application kafka-staging kafka-production -n argocd --ignore-not-found 2>/dev/null || true

# Patch away Strimzi finalizers so the namespace deletion doesn't hang.
for cr_type in kafka kafkanodepool kafkatopic; do
  if kubectl get "${cr_type}" -n kafka-tutorial &>/dev/null 2>&1; then
    kubectl get "${cr_type}" -n kafka-tutorial -o name 2>/dev/null | \
      xargs -r -I{} kubectl patch {} -n kafka-tutorial \
        --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
  fi
done

kubectl delete namespace kafka-tutorial --ignore-not-found
kubectl delete namespace kafka-staging --ignore-not-found
kubectl delete namespace kafka-production --ignore-not-found

info "Previous lesson state cleaned up."

# ─── Step 3: Configure Strimzi to watch staging and production namespaces ──────

info "Configuring Strimzi operator for staging and production namespaces..."

for ns in kafka-staging kafka-production; do
  kubectl create namespace "${ns}" 2>/dev/null || true
  for rb_name in strimzi-cluster-operator strimzi-cluster-operator-entity-operator-delegation strimzi-cluster-operator-watched; do
    ROLE_REF=$(kubectl get rolebinding "${rb_name}" -n strimzi-operator -o jsonpath='{.roleRef.name}' 2>/dev/null || echo "")
    if [[ -n "${ROLE_REF}" ]]; then
      kubectl create rolebinding "${rb_name}" \
        --namespace "${ns}" \
        --clusterrole="${ROLE_REF}" \
        --serviceaccount=strimzi-operator:strimzi-cluster-operator 2>/dev/null || true
    fi
  done
done

kubectl set env deployment/strimzi-cluster-operator -n strimzi-operator \
  STRIMZI_NAMESPACE='kafka-staging,kafka-production'

info "Waiting for Strimzi operator to restart..."
kubectl rollout status deployment/strimzi-cluster-operator -n strimzi-operator --timeout=120s

# ─── Step 4: Seed the Gitea repository with the overlay structure ─────────────

info "Resetting Gitea repository to lesson-2 starting state..."

WORK_DIR=$(mktemp -d)
trap cleanup EXIT

git clone "http://${GITEA_USER}:${GITEA_PASSWORD}@localhost:${GITEA_HOST_PORT}/${GITEA_USER}/${GITEA_REPO}.git" "${WORK_DIR}/repo" 2>/dev/null

rm -rf "${WORK_DIR}/repo/manifests"
mkdir -p "${WORK_DIR}/repo/manifests"
cp -r "${SCRIPT_DIR}/lesson-manifests/." "${WORK_DIR}/repo/manifests/"

pushd "${WORK_DIR}/repo" >/dev/null
git add .
if git diff --cached --quiet; then
  info "Gitea repo is already in lesson-2 starting state, skipping commit."
else
  git -c user.name="Tutorial Setup" -c user.email="setup@tutorial.local" commit -m "Reset to lesson-2 starting state"
  git push
  info "Lesson-2 starting state pushed to Gitea."
fi
TARGET_REVISION=$(git rev-parse HEAD)
popd >/dev/null

# ─── Step 5: Create ArgoCD Applications for staging and production ─────────────

info "Creating ArgoCD applications for staging and production..."

kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kafka-staging
  namespace: argocd
spec:
  project: default
  source:
    repoURL: http://gitea-http.gitea.svc:3000/tutorial-user/streamshub-gitops.git
    targetRevision: main
    path: manifests/overlays/staging
  destination:
    server: https://kubernetes.default.svc
    namespace: kafka-staging
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    managedNamespaceMetadata:
      labels:
        argocd.argoproj.io/managed-by: argocd
    syncOptions:
      - CreateNamespace=true
EOF

kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kafka-production
  namespace: argocd
spec:
  project: default
  source:
    repoURL: http://gitea-http.gitea.svc:3000/tutorial-user/streamshub-gitops.git
    targetRevision: main
    path: manifests/overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: kafka-production
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    managedNamespaceMetadata:
      labels:
        argocd.argoproj.io/managed-by: argocd
    syncOptions:
      - CreateNamespace=true
EOF

# ─── Step 6: Wait for both applications to sync ───────────────────────────────

info "Waiting for ArgoCD to sync both applications..."

kubectl annotate application kafka-staging -n argocd argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
kubectl annotate application kafka-production -n argocd argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true

for app in kafka-staging kafka-production; do
  SYNC_STATUS="Unknown"
  for i in $(seq 1 24); do
    CURRENT_REVISION=$(kubectl get application "${app}" -n argocd -o jsonpath='{.status.sync.revision}' 2>/dev/null || echo "")
    SYNC_STATUS=$(kubectl get application "${app}" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    if [[ "${CURRENT_REVISION}" == "${TARGET_REVISION}" && "${SYNC_STATUS}" == "Synced" ]]; then
      break
    fi
    sleep 5
  done

  if [[ "${SYNC_STATUS}" != "Synced" ]]; then
    warn "Application '${app}' has not synced yet (status: ${SYNC_STATUS})."
    warn "Check with: kubectl get application ${app} -n argocd"
  else
    info "Application '${app}' is synced."
  fi
done

info "Waiting for Kafka clusters to be ready (this may take a few minutes)..."
kubectl wait kafka/my-cluster --for=condition=Ready -n kafka-staging --timeout=600s 2>/dev/null &
kubectl wait kafka/my-cluster --for=condition=Ready -n kafka-production --timeout=600s 2>/dev/null &
wait

# ─── Step 7: Print starting instructions ──────────────────────────────────────

ARGOCD_PASSWORD=$(b64decode "$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}')")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
info "Lesson 2 is ready. Open README.md and follow the lesson steps."
echo ""
echo "  Clone the repo to follow along:"
echo "     git clone http://${GITEA_USER}:${GITEA_PASSWORD}@localhost:${GITEA_HOST_PORT}/${GITEA_USER}/${GITEA_REPO}.git /tmp/gitops-lesson-2"
echo ""
echo "  Gitea (your Git server):  http://localhost:${GITEA_HOST_PORT}"
echo "  Username: ${GITEA_USER}   Password: ${GITEA_PASSWORD}"
echo ""
echo "  ArgoCD Dashboard (open in a separate terminal):"
echo "     kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "     URL:      https://localhost:8080"
echo "     Username: admin"
echo "     Password: ${ARGOCD_PASSWORD}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
