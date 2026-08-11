# Lesson 3: Rolling Back a Bad Change

**Series:** GitOps with StreamsHub — 3-part series  
**Time:** ~25 minutes (plus ~5 minutes for prep)

---

## What you will learn

By the end of this lesson you will understand:

- Why **ArgoCD Synced does not mean the change worked** — sync status and health status are separate concerns
- How Strimzi enforces Kafka's own constraints (partition count can only increase, never decrease)
- How to **roll back a breaking change** using `git revert` — a new commit that undoes the previous one, preserving the full audit trail
- Why `git revert` is the correct GitOps approach, and why rewriting history with `git reset --hard` is an anti-pattern

You will do this by deploying a configuration change that ArgoCD accepts but Strimzi rejects, observing the failure, and performing a GitOps rollback that heals the cluster automatically.

---

## Prerequisites

If you haven't done this yet, run through the [Getting Started](../00-setup/README.md) guide. You only need to do this once. (takes ~8 minutes)

---

## Background: Two things to understand before we start

### Sync status vs health status

ArgoCD tracks two independent statuses for every Application:

- **Sync Status** (`Synced` / `OutOfSync`): Did ArgoCD successfully apply the manifests from Git to Kubernetes? This reflects whether the Kubernetes API accepted the YAML. A successful `kubectl apply` produces `Synced`.

- **Health Status** (`Healthy` / `Degraded` / `Progressing`): Is the resource actually working? This is assessed by reading resource conditions — for a KafkaTopic, that means checking the `Ready` condition set by the Strimzi Topic Operator.

These can disagree. A manifest can be `Synced` (Kubernetes stored the desired state) while the application is `Degraded` (the platform rejected the semantic change underneath). This lesson demonstrates that divergence concretely.

### GitOps rollback

Because the configuration in the Git repository is the source of truth, rolling back is not a special operation — it is just another Git commit. You revert the bad commit, push, and the reconciler heals the cluster automatically. No `kubectl rollout undo`, no deployment pipeline, no emergency access needed.

---

## Setup

Run the prep script from this directory:

```bash
./prep.sh
```

This takes approximately 5 minutes. It:

1. Removes any state from previous lessons
2. Seeds the Gitea repository with a working Kafka cluster and topic
3. Waits for both the Kafka cluster and the topic to become ready

When it finishes it prints the Gitea and ArgoCD credentials.

You can re-run `./prep.sh` at any time to reset back to the lesson starting state. If you have already cloned the repo at `/tmp/gitops-lesson-3`, delete it first (`rm -rf /tmp/gitops-lesson-3`) because the reset rewrites the Gitea commit history.

---

## Part 1: Explore the starting state

### Clone the repository

```bash
git clone http://tutorial-user:tutorial-password@localhost:3001/tutorial-user/streamshub-gitops.git /tmp/gitops-lesson-3
cd /tmp/gitops-lesson-3
```

### Check the running resources

```bash
kubectl get kafka -n kafka-tutorial
```

Expected output:

```
NAME         READY   WARNINGS   KAFKA VERSION   METADATA VERSION
my-cluster   True               4.2.0           4.2-IV0
```

```bash
kubectl get kafkatopic -n kafka-tutorial
```

Expected output:

```
NAME             CLUSTER      PARTITIONS   REPLICATION FACTOR   READY
my-first-topic   my-cluster   3            1                    True
```

Both the Kafka cluster and the topic are `READY: True`. This is the known-good baseline you will return to at the end of the lesson.

### Check the Git history

```bash
git log --oneline
```

The most recent commit will be the lesson-3 reset:

```
abc1234 Reset to lesson-3 starting state
...
```

Watch this history grow as the lesson progresses.

### Review the manifest

```bash
cat manifests/topic.yaml
```

Confirm `partitions: 3`. That number is about to change.

---

## Part 2: Deploy the breaking change

**The scenario:** a team member decides to reduce `my-first-topic` from 3 partitions to 1 to save resources. It seems harmless. Kafka, however, does not allow partition counts to decrease — topics can gain partitions but never lose them.

Open `manifests/topic.yaml` in your editor and change `partitions: 3` to `partitions: 1`:

```yaml
spec:
  partitions: 1
  replicas: 1
```

Commit and push:

```bash
git add manifests/topic.yaml
git commit -m "Reduce my-first-topic to 1 partition"
git push
```

ArgoCD polls the repository every 30 seconds. Watch it detect the change:

```bash
kubectl get application kafka-tutorial -n argocd -w
```

The `SYNC STATUS` column will move from `Synced` → `OutOfSync` → `Synced` within about 30 seconds. Press `Ctrl+C` once it settles.

The output should now look something like this:

```
NAME             SYNC STATUS   HEALTH STATUS
kafka-tutorial   Synced        Progressing
```

ArgoCD reports `Synced` — from its perspective, its job is done. It applied the manifest to Kubernetes and the API accepted it. But notice the `HEALTH STATUS` column: it says `Progressing`, not `Healthy`. ArgoCD is waiting for the resource to become ready, but something is wrong underneath. In the next section, you will find out what.

---

## Part 3: Detect the problem

Check the topic status:

```bash
kubectl get kafkatopic -n kafka-tutorial
```

Expected output:

```
NAME             CLUSTER      PARTITIONS   REPLICATION FACTOR   READY
my-first-topic   my-cluster   1            1                    False
```

`READY: False`. The manifest was applied, but the change is not working. Note that `PARTITIONS` now shows `1` — that is what the KafkaTopic CR specifies. But Strimzi could not actually change the partition count inside Kafka.

Find out why:

```bash
kubectl describe kafkatopic my-first-topic -n kafka-tutorial
```

Look at the `Conditions` section near the bottom:

```
Conditions:
  Type:    Ready
  Status:  False
  Reason:  NotSupported
  Message: Decreasing partitions not supported
```

Strimzi's Topic Operator attempted to reconfigure the topic and Kafka itself rejected the operation. The actual topic inside the broker still has 3 partitions — nothing in Kafka changed. But the KafkaTopic CR is in an error state because what the configuration in the Git repository says and what the broker has are now out of agreement.

Now check the ArgoCD application status again:

```bash
kubectl get application kafka-tutorial -n argocd
```

```
NAME             SYNC STATUS   HEALTH STATUS
kafka-tutorial   Synced        Progressing
```

This is the key distinction from the background section made real:

- `SYNC STATUS: Synced` — ArgoCD applied the manifest to Kubernetes. It did its job.
- `HEALTH STATUS: Progressing` — ArgoCD is waiting for the resource to become ready, but it never will. Strimzi has enforced Kafka's constraint and the topic is stuck in a `READY: False` state.

Sync tells you whether ArgoCD succeeded. Health tells you whether the underlying system is in a good state. **Both matter, and they can disagree.** A deployment is not complete until it is both Synced and Healthy — not Synced and Progressing indefinitely.

This situation — synced but not healthy — is exactly when a GitOps rollback is needed.

---

## Part 4: Rollback with git revert

First, look at the commit history to understand what to revert:

```bash
git log --oneline
```

```
def5678 Reduce my-first-topic to 1 partition
abc1234 Reset to lesson-3 starting state
```

The breaking change is the most recent commit — `HEAD`. You need to undo it.

Perform the rollback:

```bash
git revert HEAD --no-edit
```

`git revert HEAD` creates a new commit that applies the exact inverse of what `HEAD` introduced. If `HEAD` changed `partitions: 3` to `partitions: 1`, the revert changes it back to `partitions: 3`. The `--no-edit` flag accepts the default commit message without opening an editor.

Look at what just happened:

```bash
git log --oneline
```

```
789abcd Revert "Reduce my-first-topic to 1 partition"
def5678 Reduce my-first-topic to 1 partition
abc1234 Reset to lesson-3 starting state
```

Three commits. The bad commit is still there — it was not erased. The revert commit sits on top of it, documenting exactly what was undone and when. This is the audit trail.

Push the revert:

```bash
git push
```

That is the rollback. No `kubectl` command was run. No deployment pipeline was triggered. You changed the configuration in Git; the system will reconcile to match.

### Why not git reset --hard?

You could also roll back by rewriting history:

```bash
git reset --hard HEAD~1
git push --force   # DO NOT DO THIS
```

This removes the bad commit as if it never existed. In a GitOps context this is an anti-pattern:

- Anyone who pulled the bad commit now has a divergent history and will see errors on their next `git pull`
- The audit trail is gone — no record of what changed or when it was fixed
- Force-pushing to a shared branch is a coordination hazard in teams
- In regulated environments, history rewriting may violate compliance requirements

`git revert` is additive and safe. The full sequence of events stays in history for anyone to inspect.

---

## Part 5: Watch the recovery

ArgoCD will pick up the revert within about 30 seconds. Watch the recovery:

```bash
kubectl get application kafka-tutorial -n argocd -w
```

The application will move through `OutOfSync` → `Synced` as ArgoCD detects the new commit and applies the restored manifest. Press `Ctrl+C` once it settles.

Verify the topic is healthy again:

```bash
kubectl get kafkatopic my-first-topic -n kafka-tutorial
```

Expected output:

```
NAME             CLUSTER      PARTITIONS   REPLICATION FACTOR   READY
my-first-topic   my-cluster   3            1                    True
```

`READY: True`. `PARTITIONS: 3`. The topic is back to its working state.

Check the application health:

```bash
kubectl get application kafka-tutorial -n argocd
```

```
NAME             SYNC STATUS   HEALTH STATUS
kafka-tutorial   Synced        Healthy
```

Both `Synced` and `Healthy`. The system has fully recovered.

Review the full audit trail:

```bash
git log --oneline
```

```
789abcd Revert "Reduce my-first-topic to 1 partition"
def5678 Reduce my-first-topic to 1 partition
abc1234 Reset to lesson-3 starting state
```

The complete sequence is preserved: what was changed, when, and when it was reverted.

---

## How it worked

```
git push (the revert commit)
  └─▶ Gitea receives the new commit

ArgoCD polls Gitea (every 30 seconds)
  └─▶ Detects HEAD has moved (new revert commit)
  └─▶ Renders the kustomize manifests — topic.yaml now has partitions: 3
  └─▶ Compares live cluster state to desired state
  └─▶ Applies the update — KafkaTopic CR updated back to partitions: 3

Strimzi Topic Operator
  └─▶ Sees KafkaTopic CR updated to partitions: 3
  └─▶ Checks the actual Kafka topic — it already has 3 partitions (never changed)
  └─▶ No Kafka operation needed; marks KafkaTopic Ready: True

ArgoCD health check
  └─▶ Sees KafkaTopic Ready condition is True
  └─▶ Reports application Health: Healthy
```

Note that the actual Kafka topic inside the broker never had its partition count changed. Strimzi protected the broker from the invalid operation the entire time. What `git revert` did was bring the configuration in the Git repository and the KafkaTopic CR back in sync with the broker's actual state.

---

## Optional: View the ArgoCD dashboard

In a separate terminal, start the port-forward:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open [https://localhost:8080](https://localhost:8080) (accept the self-signed certificate warning).

Retrieve the admin password:

```bash
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d; echo
```

Log in with username `admin`.

The `kafka-tutorial` tile shows two distinct indicators: a sync badge and a health badge. After deploying the breaking change, you will see `Synced` alongside `Degraded`. After the revert, both badges turn green — `Synced` and `Healthy`.

Click the Application to open the resource tree. Click on `my-first-topic` to see the KafkaTopic details, including the error condition from Strimzi. This view makes the sync/health distinction visible at a glance.


## What you've learned

- ArgoCD `Synced` means the Kubernetes API accepted the manifest — it does not mean the change was successful at the platform level
- A resource stuck in `Progressing` (never reaching `Healthy`) is a signal to investigate even when sync succeeds
- Strimzi enforces Kafka's own constraints; some invalid changes deploy silently through Kubernetes but are rejected by the operator
- `git revert` is the correct GitOps rollback tool: it creates a new commit, preserves history, and is safe for shared branches
- `git reset --hard` with force-push destroys the audit trail and causes problems for anyone who pulled the broken commit
- Rollback in GitOps requires no special tooling — change the configuration in the Git repository, and the reconciler heals the cluster automatically

---

## The complete picture

| Lesson | What you learned |
|--------|-----------------|
| **Lesson 1** | The GitOps core loop: edit Git, ArgoCD deploys it |
| **Lesson 2** | Kustomize overlays for multi-environment management; promotion is a Git change |
| **Lesson 3** | Rollback is a Git change too; sync and health are separate — check both |

---

## Cleanup

When you are done with all lessons, delete the cluster:

```bash
../00-setup/teardown.sh
```

Clean up the cloned repo:

```bash
rm -rf /tmp/gitops-lesson-3
```

---

## Troubleshooting

**Infrastructure is not running**  
If `./prep.sh` reports that the cluster or Strimzi is not found, run the setup script first: `../00-setup/setup.sh`.

**prep.sh fails waiting for KafkaTopic to be ready**  
The Topic Operator only starts after the Kafka cluster is ready. If the Kafka wait succeeded but the KafkaTopic wait timed out, check the Entity Operator:

```bash
kubectl get pods -n kafka-tutorial
kubectl logs -n kafka-tutorial -l strimzi.io/component-type=entity-operator
```

Re-running `./prep.sh` will reset and retry.

**ArgoCD shows Synced but HEALTH is Progressing after the revert**  
This is transient — ArgoCD's health check polls on a short interval. Wait 10–15 seconds and re-check. If it persists, check the topic status directly:

```bash
kubectl describe kafkatopic my-first-topic -n kafka-tutorial
```

**git revert opens an editor and I don't know how to exit**  
If you ran `git revert HEAD` without `--no-edit`, your default editor opens. In `vi`: press `Esc`, type `:wq`, press Enter. In `nano`: press `Ctrl+X`, then `Y`, then Enter. Alternatively, abort with `Ctrl+C` and rerun with `--no-edit`:

```bash
git revert HEAD --no-edit
```

**The topic still shows PARTITIONS: 1 after the revert and ArgoCD sync**  
Confirm the revert commit was pushed and ArgoCD has synced it:

```bash
git log --oneline          # confirm the revert commit is the latest
git status                 # confirm nothing is unpushed ("Your branch is up to date")
kubectl get application kafka-tutorial -n argocd   # confirm SYNC STATUS is Synced
```

If the revert was not pushed, run `git push`. To trigger an immediate ArgoCD sync without waiting for the next 30-second poll:

```bash
kubectl annotate application kafka-tutorial -n argocd \
  argocd.argoproj.io/refresh=normal --overwrite
```

**Strimzi is not managing the kafka-tutorial namespace**  
Verify the Strimzi operator is running and watching all namespaces:

```bash
kubectl get deployment strimzi-cluster-operator -n strimzi-operator \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="STRIMZI_NAMESPACE")].value}'; echo
```

It should show `*`. If not, re-run `../00-setup/setup.sh`.
