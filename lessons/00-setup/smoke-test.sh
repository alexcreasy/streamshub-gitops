#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# ─── Global State ─────────────────────────────────────────────────────────────

TUTORIAL_WORK_DIR=""
TEST_FAILURES=()
LESSON_REPOS=()

# ─── Configuration ────────────────────────────────────────────────────────────

ARGOCD_SYNC_TIMEOUT=180  # 3 minutes for ArgoCD sync
TOPIC_READY_TIMEOUT=120  # 2 minutes for topic ready

# ─── Cleanup ──────────────────────────────────────────────────────────────────

cleanup_smoke_test() {
  info "Cleaning up temporary directories..."

  # Clean up individual lesson repos
  for repo in "${LESSON_REPOS[@]}"; do
    [[ -d "${repo}" ]] && rm -rf "${repo}"
  done

  # Clean up main work directory
  if [[ -n "${TUTORIAL_WORK_DIR:-}" && -d "${TUTORIAL_WORK_DIR}" ]]; then
    rm -rf "${TUTORIAL_WORK_DIR}"
  fi

  # Kill port-forward if running
  if [[ -n "${GITEA_PORT_FORWARD_PID:-}" ]]; then
    info "Stopping Gitea port-forward..."
    kill "${GITEA_PORT_FORWARD_PID}" 2>/dev/null || true
  fi
}

trap cleanup_smoke_test EXIT

# ─── Git Helpers ──────────────────────────────────────────────────────────────

configure_git_identity() {
  git config --global user.name "Smoke Test Bot" 2>/dev/null || true
  git config --global user.email "smoke-test@example.com" 2>/dev/null || true
}

git_commit_and_push() {
  local message="$1"
  git add .
  if git diff --cached --quiet; then
    # No output when no changes - caller will use current HEAD
    return 0
  fi
  # Redirect commit and push output to stderr so only SHA is captured
  git commit -m "${message}" >&2
  git push >&2
  git rev-parse HEAD
}

# ─── Verification Functions ───────────────────────────────────────────────────

verify_argocd_sync() {
  local app_name="$1"
  local expected_revision="$2"
  local timeout="${3:-${ARGOCD_SYNC_TIMEOUT}}"

  info "Waiting for ArgoCD application '${app_name}' to sync to ${expected_revision:0:7}..."

  kubectl annotate application "${app_name}" -n argocd \
    argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true

  local elapsed=0
  while [[ ${elapsed} -lt ${timeout} ]]; do
    local current_rev=$(kubectl get application "${app_name}" -n argocd \
      -o jsonpath='{.status.sync.revision}' 2>/dev/null || echo "")
    local sync_status=$(kubectl get application "${app_name}" -n argocd \
      -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")

    if [[ "${current_rev}" == "${expected_revision}" && "${sync_status}" == "Synced" ]]; then
      info "ArgoCD application '${app_name}' synced successfully"
      return 0
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  error "ArgoCD application '${app_name}' failed to sync within ${timeout}s"
  error "Current status: ${sync_status}, revision: ${current_rev:0:7}"
  return 1
}

verify_resource_ready() {
  local resource_type="$1"
  local resource_name="$2"
  local namespace="$3"
  local timeout="${4:-${TOPIC_READY_TIMEOUT}}"

  info "Waiting for ${resource_type}/${resource_name} in ${namespace} to be ready..."

  # Phase 1: Wait for resource to exist (kubectl wait requires resource to exist first)
  # Timeout must be >= ArgoCD sync timeout since ArgoCD creates the resource
  local existence_timeout=180  # Match ARGOCD_SYNC_TIMEOUT
  local elapsed=0
  while [[ ${elapsed} -lt ${existence_timeout} ]]; do
    if kubectl get "${resource_type}/${resource_name}" -n "${namespace}" &>/dev/null; then
      info "Resource ${resource_type}/${resource_name} exists (found after ${elapsed}s)"
      break
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  # Check if resource actually exists after the wait
  if ! kubectl get "${resource_type}/${resource_name}" -n "${namespace}" &>/dev/null; then
    error "${resource_type}/${resource_name} does not exist after ${existence_timeout}s"
    error "ArgoCD may have synced but resource was not created"
    info "Checking ArgoCD application status..."
    kubectl get application -n argocd -o wide 2>&1 | grep -E "NAME|kafka" || true
    return 1
  fi

  # Phase 2: Use kubectl wait for the Ready condition (this is what kubectl does best)
  if kubectl wait "${resource_type}/${resource_name}" \
      --for=condition=Ready -n "${namespace}" \
      --timeout="${timeout}s" 2>/dev/null; then
    info "${resource_type}/${resource_name} is ready"
    return 0
  else
    error "${resource_type}/${resource_name} not ready within ${timeout}s"
    kubectl describe "${resource_type}/${resource_name}" -n "${namespace}" 2>&1 | head -30 || true
    return 1
  fi
}

verify_resource_not_ready() {
  local resource_type="$1"
  local resource_name="$2"
  local namespace="$3"

  local ready_status=$(kubectl get "${resource_type}/${resource_name}" -n "${namespace}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")

  if [[ "${ready_status}" == "False" ]]; then
    info "${resource_type}/${resource_name} is correctly in NOT ready state"
    return 0
  else
    error "${resource_type}/${resource_name} ready status is '${ready_status}', expected 'False'"
    return 1
  fi
}

wait_for_resource_not_ready() {
  local resource_type="$1"
  local resource_name="$2"
  local namespace="$3"
  local timeout="${4:-60}"  # Default 60s timeout

  info "Waiting for ${resource_type}/${resource_name} to become NOT ready (timeout: ${timeout}s)..."

  local elapsed=0
  while [[ ${elapsed} -lt ${timeout} ]]; do
    local ready_status=$(kubectl get "${resource_type}/${resource_name}" -n "${namespace}" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")

    if [[ "${ready_status}" == "False" ]]; then
      info "${resource_type}/${resource_name} is now NOT ready"
      return 0
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  error "${resource_type}/${resource_name} did not become NOT ready within ${timeout}s"
  error "Current ready status: ${ready_status}"
  kubectl describe "${resource_type}/${resource_name}" -n "${namespace}" 2>&1 | head -50 || true
  return 1
}

verify_field_value() {
  local resource_type="$1"
  local resource_name="$2"
  local namespace="$3"
  local jsonpath="$4"
  local expected_value="$5"

  local actual_value=$(kubectl get "${resource_type}/${resource_name}" -n "${namespace}" \
    -o jsonpath="${jsonpath}" 2>/dev/null || echo "")

  if [[ "${actual_value}" == "${expected_value}" ]]; then
    info "Verified ${resource_type}/${resource_name} ${jsonpath} = ${expected_value}"
    return 0
  else
    error "Field verification failed: expected '${expected_value}', got '${actual_value}'"
    return 1
  fi
}

# ─── Lesson Test Functions ────────────────────────────────────────────────────

test_lesson_1() {
  local test_name="Lesson 1: Add Kafka Topic via GitOps"
  echo ""
  info "========================================="
  info "${test_name}"
  info "========================================="

  # Step 1: Run prep script
  info "Step 1/7: Running lesson-1 prep.sh..."
  if ! "${SCRIPT_DIR}/../01-lesson-1/prep.sh"; then
    error "Lesson 1 prep.sh failed"
    TEST_FAILURES+=("${test_name}: prep failed")
    return 1
  fi

  # Step 2: Clone repo
  local repo_dir="${TUTORIAL_WORK_DIR}/lesson-1-repo"
  LESSON_REPOS+=("${repo_dir}")
  info "Step 2/7: Cloning Gitea repository..."
  git clone "$(gitea_clone_url)" "${repo_dir}" 2>/dev/null
  cd "${repo_dir}"

  # Step 3: Verify initial state (topic.yaml should be in manifests but not in kustomization)
  info "Step 3/7: Verifying initial state..."
  if ! [[ -f manifests/topic.yaml ]]; then
    error "manifests/topic.yaml should exist"
    TEST_FAILURES+=("${test_name}: topic.yaml missing from manifests")
    cd - >/dev/null
    return 1
  fi

  # The prep script includes topic.yaml in the manifests directory but the lesson
  # has users add it to kustomization. Let's check the actual state from prep.
  # Note: grep -c returns exit code 1 when count is 0, so we check the output not the exit code
  local initial_has_topic=$(grep -c "topic.yaml" manifests/kustomization.yaml 2>/dev/null || true)
  info "Initial kustomization.yaml contains topic.yaml: ${initial_has_topic} times"

  # Step 4: Add topic.yaml to kustomization (if not already present)
  info "Step 4/7: Ensuring topic.yaml is in kustomization.yaml..."
  if ! grep -q "topic.yaml" manifests/kustomization.yaml 2>/dev/null; then
    echo "  - topic.yaml" >> manifests/kustomization.yaml
    info "Added topic.yaml to kustomization"
  else
    warn "topic.yaml already in kustomization.yaml"
  fi

  # Debug: show the kustomization file
  info "Current kustomization.yaml contents:"
  cat manifests/kustomization.yaml

  # Step 5: Commit and push
  info "Step 5/7: Committing and pushing change..."
  local new_revision=$(git_commit_and_push "Add my-first-topic Kafka topic")

  # Handle case where there were no changes
  if [[ -z "${new_revision}" ]]; then
    new_revision=$(git rev-parse HEAD)
    warn "No changes were committed, using current HEAD: ${new_revision:0:7}"
  else
    info "Committed and pushed: ${new_revision:0:7}"
  fi

  # Step 6: Wait for ArgoCD sync
  info "Step 6/7: Waiting for ArgoCD sync..."
  if ! verify_argocd_sync "kafka-tutorial" "${new_revision}"; then
    TEST_FAILURES+=("${test_name}: ArgoCD sync failed")
    cd - >/dev/null
    return 1
  fi

  # Debug: Check what resources ArgoCD thinks it managed
  info "Checking ArgoCD managed resources..."
  kubectl get application kafka-tutorial -n argocd -o yaml | grep -A 20 "resources:" || true
  info "Checking for KafkaTopic resources in namespace..."
  kubectl get kafkatopic -n kafka-tutorial || echo "No topics found"

  # Step 7: Verify topic created and ready
  info "Step 7/7: Verifying topic ready..."
  if ! verify_resource_ready "kafkatopic" "my-first-topic" "kafka-tutorial"; then
    TEST_FAILURES+=("${test_name}: topic not ready")
    cd - >/dev/null
    return 1
  fi

  # Step 8: Verify topic has correct partition count
  if ! verify_field_value "kafkatopic" "my-first-topic" "kafka-tutorial" \
       '{.spec.partitions}' "3"; then
    TEST_FAILURES+=("${test_name}: partition count incorrect")
    cd - >/dev/null
    return 1
  fi

  info "✓ PASSED: ${test_name}"
  cd - >/dev/null
  return 0
}

test_lesson_2() {
  local test_name="Lesson 2: Multi-Environment Promotion"
  echo ""
  info "========================================="
  info "${test_name}"
  info "========================================="

  # Step 1: Run prep script
  info "Step 1/8: Running lesson-2 prep.sh..."
  if ! "${SCRIPT_DIR}/../02-lesson-2/prep.sh"; then
    error "Lesson 2 prep.sh failed"
    TEST_FAILURES+=("${test_name}: prep failed")
    return 1
  fi

  # Step 2: Clone repo
  local repo_dir="${TUTORIAL_WORK_DIR}/lesson-2-repo"
  LESSON_REPOS+=("${repo_dir}")
  info "Step 2/8: Cloning Gitea repository..."
  git clone "$(gitea_clone_url)" "${repo_dir}" 2>/dev/null
  cd "${repo_dir}"

  # Step 3: Verify staging has topic, production does not
  info "Step 3/8: Verifying initial multi-environment state..."
  info "Waiting for topic to exist in staging..."

  # Poll for topic existence (up to 60s)
  local elapsed=0
  while [[ ${elapsed} -lt 60 ]]; do
    if kubectl get kafkatopic my-first-topic -n kafka-staging &>/dev/null; then
      info "Topic exists in staging"
      break
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done

  if ! kubectl get kafkatopic my-first-topic -n kafka-staging &>/dev/null; then
    error "Topic should exist in staging after prep (waited 60s)"
    TEST_FAILURES+=("${test_name}: staging topic missing")
    cd - >/dev/null
    return 1
  fi

  if kubectl get kafkatopic my-first-topic -n kafka-production &>/dev/null; then
    error "Topic should NOT exist in production initially"
    TEST_FAILURES+=("${test_name}: production topic should not exist")
    cd - >/dev/null
    return 1
  fi

  # Step 4: Verify production kustomization does not have topic
  info "Step 4/8: Verifying production kustomization..."
  if grep -q "topic.yaml" manifests/overlays/production/kustomization.yaml; then
    error "topic.yaml should not be in production kustomization initially"
    TEST_FAILURES+=("${test_name}: production kustomization already has topic")
    cd - >/dev/null
    return 1
  fi

  # Step 5: Promote to production (copy topic and update kustomization)
  info "Step 5/8: Promoting topic to production..."
  cp manifests/overlays/staging/topic.yaml manifests/overlays/production/topic.yaml
  echo "  - topic.yaml" >> manifests/overlays/production/kustomization.yaml

  # Step 6: Commit and push
  info "Step 6/8: Committing and pushing promotion..."
  local new_revision=$(git_commit_and_push "Promote my-first-topic to production")

  # Handle case where there were no changes
  if [[ -z "${new_revision}" ]]; then
    new_revision=$(git rev-parse HEAD)
  fi

  # Step 7: Wait for production ArgoCD sync
  info "Step 7/8: Waiting for production ArgoCD sync..."
  if ! verify_argocd_sync "kafka-production" "${new_revision}"; then
    TEST_FAILURES+=("${test_name}: production ArgoCD sync failed")
    cd - >/dev/null
    return 1
  fi

  # Step 8: Verify topic now exists in production
  info "Step 8/8: Verifying topic exists in production..."
  if ! verify_resource_ready "kafkatopic" "my-first-topic" "kafka-production"; then
    TEST_FAILURES+=("${test_name}: production topic not ready")
    cd - >/dev/null
    return 1
  fi

  # Verify staging still has the topic (unchanged)
  if ! kubectl get kafkatopic my-first-topic -n kafka-staging &>/dev/null; then
    error "Staging topic should still exist"
    TEST_FAILURES+=("${test_name}: staging topic disappeared")
    cd - >/dev/null
    return 1
  fi

  info "✓ PASSED: ${test_name}"
  cd - >/dev/null
  return 0
}

test_lesson_3() {
  local test_name="Lesson 3: Rollback Bad Change"
  echo ""
  info "========================================="
  info "${test_name}"
  info "========================================="

  # Step 1: Run prep script
  info "Step 1/10: Running lesson-3 prep.sh..."
  if ! "${SCRIPT_DIR}/../03-lesson-3/prep.sh"; then
    error "Lesson 3 prep.sh failed"
    TEST_FAILURES+=("${test_name}: prep failed")
    return 1
  fi

  # Step 2: Clone repo
  local repo_dir="${TUTORIAL_WORK_DIR}/lesson-3-repo"
  LESSON_REPOS+=("${repo_dir}")
  info "Step 2/10: Cloning Gitea repository..."
  git clone "$(gitea_clone_url)" "${repo_dir}" 2>/dev/null
  cd "${repo_dir}"

  # Step 3: Verify initial healthy state
  info "Step 3/10: Verifying initial healthy state..."
  if ! verify_resource_ready "kafkatopic" "my-first-topic" "kafka-tutorial"; then
    TEST_FAILURES+=("${test_name}: topic not ready initially")
    cd - >/dev/null
    return 1
  fi

  if ! verify_field_value "kafkatopic" "my-first-topic" "kafka-tutorial" \
       '{.spec.partitions}' "3"; then
    TEST_FAILURES+=("${test_name}: initial partition count incorrect")
    cd - >/dev/null
    return 1
  fi

  # Step 4: Make breaking change (reduce partitions)
  info "Step 4/10: Making breaking change (reducing partitions from 3 to 1)..."
  # Use .bak extension for macOS compatibility, then remove it
  sed -i.bak 's/partitions: 3/partitions: 1/' manifests/topic.yaml
  rm -f manifests/topic.yaml.bak

  # Step 5: Commit and push bad change
  info "Step 5/10: Committing and pushing bad change..."
  local bad_revision=$(git_commit_and_push "Reduce my-first-topic to 1 partition")

  # Handle case where there were no changes
  if [[ -z "${bad_revision}" ]]; then
    bad_revision=$(git rev-parse HEAD)
  fi

  # Step 6: Wait for ArgoCD sync (it should sync successfully)
  info "Step 6/10: Waiting for ArgoCD sync of bad change..."
  if ! verify_argocd_sync "kafka-tutorial" "${bad_revision}"; then
    TEST_FAILURES+=("${test_name}: ArgoCD sync failed for bad change")
    cd - >/dev/null
    return 1
  fi

  # Step 7: Wait for topic operator to reject bad change
  info "Step 7/10: Waiting for topic operator to reject bad change..."
  if ! wait_for_resource_not_ready "kafkatopic" "my-first-topic" "kafka-tutorial" 60; then
    TEST_FAILURES+=("${test_name}: topic did not become NOT ready after bad change")
    cd - >/dev/null
    return 1
  fi

  # Step 8: Revert the bad change
  info "Step 8/10: Reverting bad change with git revert..."
  git revert HEAD --no-edit >&2

  # Step 9: Push the revert
  info "Step 9/10: Pushing revert commit..."
  git push >&2
  local revert_revision=$(git rev-parse HEAD)

  # Step 10: Wait for ArgoCD sync
  info "Step 10/10: Waiting for ArgoCD sync of revert..."
  if ! verify_argocd_sync "kafka-tutorial" "${revert_revision}"; then
    TEST_FAILURES+=("${test_name}: ArgoCD sync failed for revert")
    cd - >/dev/null
    return 1
  fi

  # Verify topic is ready again
  if ! verify_resource_ready "kafkatopic" "my-first-topic" "kafka-tutorial" 180; then
    TEST_FAILURES+=("${test_name}: topic not ready after revert")
    cd - >/dev/null
    return 1
  fi

  # Verify partitions back to 3
  if ! verify_field_value "kafkatopic" "my-first-topic" "kafka-tutorial" \
       '{.spec.partitions}' "3"; then
    TEST_FAILURES+=("${test_name}: partition count not restored")
    cd - >/dev/null
    return 1
  fi

  info "✓ PASSED: ${test_name}"
  cd - >/dev/null
  return 0
}

# ─── Results Reporting ────────────────────────────────────────────────────────

report_results() {
  echo ""
  echo "========================================="
  echo "SMOKE TEST RESULTS"
  echo "========================================="

  if [[ ${#TEST_FAILURES[@]} -eq 0 ]]; then
    info "✓ ALL TESTS PASSED"
    exit 0
  else
    error "✗ ${#TEST_FAILURES[@]} TEST(S) FAILED:"
    for failure in "${TEST_FAILURES[@]}"; do
      error "  - ${failure}"
    done
    exit 1
  fi
}

# ─── Main Execution ───────────────────────────────────────────────────────────

main() {
  # Parse arguments
  for arg in "$@"; do
    case "$arg" in
      --create-cluster) ;;
      *)
        error "Unknown option: $arg"
        error "Usage: $0 [--create-cluster]"
        exit 1
        ;;
    esac
  done

  resolve_flag CREATE_CLUSTER --create-cluster "$@"
  local CREATE_CLUSTER_MODE="$RESOLVED_FLAG"

  # Initialize work directory
  TUTORIAL_WORK_DIR=$(mktemp -d)

  # Configure git
  configure_git_identity

  # Run setup
  echo ""
  info "========================================="
  info "SETUP PHASE"
  info "========================================="
  if [[ "${CREATE_CLUSTER_MODE}" == "true" ]]; then
    info "Running setup.sh --create-cluster..."
    "${SCRIPT_DIR}/setup.sh" --create-cluster
  else
    info "Running setup.sh (BYO cluster mode)..."
    "${SCRIPT_DIR}/setup.sh"
  fi

  # Load Gitea config
  load_gitea_config

  # Set up Gitea port-forward in BYO cluster mode if needed
  if [[ "${GITEA_EXPOSURE_MANAGED}" != "true" ]]; then
    if ! curl -sf "${GITEA_URL}/api/v1/version" >/dev/null 2>&1; then
      info "Setting up Gitea port-forward for BYO cluster mode..."
      kubectl port-forward svc/gitea-http -n gitea 3001:3000 >/dev/null 2>&1 &
      GITEA_PORT_FORWARD_PID=$!

      # Wait for port-forward to establish
      local retries=0
      while [[ ${retries} -lt 10 ]]; do
        if curl -sf "${GITEA_URL}/api/v1/version" >/dev/null 2>&1; then
          info "Gitea port-forward established (PID: ${GITEA_PORT_FORWARD_PID})"
          break
        fi
        sleep 2
        retries=$((retries + 1))
      done

      if [[ ${retries} -ge 10 ]]; then
        error "Failed to establish Gitea port-forward"
        exit 1
      fi
    else
      info "Gitea already reachable at ${GITEA_URL}"
    fi
  fi

  # Run lesson tests
  test_lesson_1 || true
  test_lesson_2 || true
  test_lesson_3 || true

  # Teardown
  echo ""
  info "========================================="
  info "TEARDOWN PHASE"
  info "========================================="
  if [[ "${CREATE_CLUSTER_MODE}" == "true" ]]; then
    info "Running teardown.sh --delete-cluster..."
    "${SCRIPT_DIR}/teardown.sh" --delete-cluster
  else
    info "Running teardown.sh (BYO cluster mode)..."
    "${SCRIPT_DIR}/teardown.sh"
  fi

  # Report results
  report_results
}

main "$@"
