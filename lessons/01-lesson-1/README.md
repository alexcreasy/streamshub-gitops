# Lesson 1: Your First GitOps Change

**Series:** GitOps with StreamsHub — 3-part series  
**Time:** ~20 minutes (plus ~8 minutes for first-time setup)

---

## What you will learn

By the end of this lesson you will understand:

- What the GitOps workflow looks like in practice
- How ArgoCD watches a Git repository and automatically applies changes to a Kubernetes cluster
- How Strimzi manages Kafka resources declaratively

You will do this by making a real change — adding a Kafka topic — and watching it flow automatically from Git to a running cluster, without ever running `kubectl apply` yourself.

---

## Prerequisites

If you haven't done this yet, run through the [Getting Started](../00-setup/README.md) guide. You only need to do this once. (takes ~8 minutes)

---

## Background: The GitOps idea in one paragraph

In traditional operations you make changes to a running system by running commands directly against it — `kubectl apply`, a config panel, an API call. GitOps flips this around: a Git repository is the single source of truth for what the system should look like. A tool (in this case ArgoCD) watches the repository and continuously reconciles the live system to match. If the config in the git repository says a topic should exist, then the topic will be created. If you remove it from the config repository, it disappears from the cluster. You never touch the system directly; you only change the configuration in the repo. You now have, thanks to git, a record of all the changes made, when they were made and by who. You can also setup all kinds of sanity and safety checks to run against those changes before they are applied.

---

## Setup

Run the prep script from this directory:

```bash
./prep.sh
```

This takes under a minute. It resets the Gitea repository to the lesson-1 starting state and confirms that ArgoCD has synced. When it finishes it prints the Gitea and ArgoCD credentials.

You can re-run `./prep.sh` at any time to reset back to the lesson starting state — useful if you make a mistake and want to start over without re-running the full setup.

---

## Part 1: Look at what's already running

Before you make any changes, take a moment to explore the environment. This is where the lesson starts: everything you are about to see was deployed by ArgoCD from Git.

### Clone the repository

The Gitea server is running inside the cluster and is exposed on port 3001. Clone the repository it holds:

```bash
git clone http://tutorial-user:tutorial-password@localhost:3001/tutorial-user/streamshub-gitops.git /tmp/gitops-lesson-1
cd /tmp/gitops-lesson-1
```

This is the repository ArgoCD is watching. Any change you push here will be picked up and applied to the cluster.

### Check the running Kafka cluster

```bash
kubectl get kafka -n kafka-tutorial
```

Expected output:

```
NAME         READY    WARNINGS    KAFKA VERSION    METADATA VERSION
my-cluster   True                 4.2.0            4.2-IV0
```

`READY: True` means Kafka is up. Now look at *how* this cluster got here — open `manifests/kafka.yaml`:

```bash
cat manifests/kafka.yaml
```

That YAML file, committed to the Git repository, is the description of this Kafka cluster. ArgoCD read it from the repo, applied to the kubernetes cluster and the Strimzi operator created the Kafka cluster from it. You didn't run any `kubectl apply` commands — the setup script pushed the file to the Git repo and ArgoCD took it from there.

### Check for Kafka topics

```bash
kubectl get kafkatopic -n kafka-tutorial
```

You should see no topics listed.

### Understand the kustomization file

ArgoCD uses [Kustomize](https://kustomize.io/) to decide which YAML files to deploy. The entry point is `manifests/kustomization.yaml`:

```bash
cat manifests/kustomization.yaml
```

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - combined-pool.yaml
  - kafka.yaml
```

This tells ArgoCD: "deploy the configuration in these three files to Kubernetes." Notice that `topic.yaml` is not listed, even though the file exists in the repository:

```bash
ls manifests/
```

`topic.yaml` is there — but because it is not in `kustomization.yaml`, ArgoCD ignores it. The cluster's state is determined entirely by what Kustomize includes, not by what files happen to exist in the folder.

---

## Part 2: Make your first GitOps change

Your application team needs a Kafka topic to send and receive messages. Your job is to add it to the cluster — the GitOps way.

### Look at the topic definition

Open `manifests/topic.yaml`:

```bash
cat manifests/topic.yaml
```

```yaml
apiVersion: kafka.strimzi.io/v1
kind: KafkaTopic
metadata:
  name: my-first-topic
  namespace: kafka-tutorial
  labels:
    strimzi.io/cluster: my-cluster
spec:
  partitions: 3
  replicas: 1
  config:
    retention.ms: "86400000"
    segment.bytes: "1073741824"
```

This defines a topic called `my-first-topic` with 3 partitions. The `strimzi.io/cluster: my-cluster` label tells Strimzi which cluster this topic belongs to. Messages will be retained for 24 hours (`86400000` ms).

The file is ready — you just need to tell Kustomize to include it.

### Edit kustomization.yaml

Open `manifests/kustomization.yaml` in your editor and add `- topic.yaml` as the last entry in the resources list:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - combined-pool.yaml
  - kafka.yaml
  - topic.yaml
```

Save the file.

### Commit and push

```bash
git add manifests/kustomization.yaml
git commit -m "Add my-first-topic Kafka topic"
git push
```

That's it. You've made your GitOps change. The commit is now in the repository that ArgoCD is watching.

---

## Part 3: Watch the GitOps loop

ArgoCD polls the repository every 30 seconds. Watch it detect your change:

```bash
kubectl get application kafka-tutorial -n argocd -w
```

Watch the `SYNC STATUS` column. Within about 30 seconds it will move from `Synced` → `OutOfSync` (when ArgoCD detects your push) → `Synced` again (when it has applied the change). Press `Ctrl+C` once you see it settle back to `Synced`.


### Verify the topic was created

Once ArgoCD shows `Synced`, check that the topic now exists:

```bash
kubectl get kafkatopic my-first-topic -n kafka-tutorial
```

Expected output:

```
NAME             CLUSTER      PARTITIONS   REPLICATION FACTOR   READY
my-first-topic   my-cluster   3            1                    True
```

`READY: True` confirms that Strimzi's Topic Operator received the `KafkaTopic` resource from ArgoCD and created the topic inside the Kafka broker.

**You just deployed a Kafka topic using GitOps.** The change went from your editor, through Git, through ArgoCD, and into the cluster — automatically.

---

## How it worked

Here is the full sequence of what happened after you ran `git push`:

```
git push
  └─▶ Gitea (Git server inside the cluster) receives the commit

ArgoCD polls Gitea every 30 seconds
  └─▶ ArgoCD detects that kustomization.yaml now includes topic.yaml
  └─▶ ArgoCD renders the Kustomize manifests (now four resources instead of three)
  └─▶ ArgoCD compares the rendered state to what is live in the cluster
  └─▶ ArgoCD applies the diff — creating the KafkaTopic resource

Strimzi Topic Operator watches for KafkaTopic resources
  └─▶ Strimzi sees the new KafkaTopic and creates the topic inside the Kafka broker
```

The key point: **you never ran `kubectl apply`**. You changed Git, and the system reconciled itself to match. This is what GitOps means in practice.

---

## Optional: View the ArgoCD dashboard

ArgoCD has a web UI where you can see the application's resource tree, sync history, and current state. In a separate terminal:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open [https://localhost:8080](https://localhost:8080) in your browser (accept the self-signed certificate warning).

Retrieve the admin password:

```bash
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d; echo
```

Log in with username `admin` and the password above. Click the `kafka-tutorial` application to see the full resource tree — Namespace, KafkaNodePool, Kafka, and now KafkaTopic, all managed by ArgoCD from a single Git repository.

---

## Cleanup

When you are done with all lessons, delete the cluster to remove everything:

```bash
../00-setup/teardown.sh
```

This deletes the KinD cluster and all resources within it. Clean up the cloned repo too:

```bash
rm -rf /tmp/gitops-lesson-1
```

---

## What's next

In **Lesson 2: Promotion from Staging to Production**, you will build on this environment by creating separate staging and production configurations and walk through the process of promoting a change through environments — the same Git-as-source-of-truth principle, applied to multi-environment workflows.

---

## Troubleshooting

**Infrastructure is not running**
If `./prep.sh` reports that the cluster or Kafka is not found, you need to run the setup script first: `../00-setup/setup.sh`. See [Getting Started](../00-setup/README.md) for setup troubleshooting.

**Kafka cluster is not becoming ready**
Kafka takes a few minutes to start, especially on machines with limited resources. Check pod status and events:

```bash
kubectl get pods -n kafka-tutorial
kubectl describe kafka my-cluster -n kafka-tutorial
```

**ArgoCD is not syncing**
Check the application for error messages:

```bash
kubectl get application kafka-tutorial -n argocd -o yaml
```

If Gitea is unreachable from inside the cluster, verify the Gitea pod is running:

```bash
kubectl get pods -n gitea
```

**Topic is not appearing after sync**
Check that the `kustomization.yaml` edit was saved and committed correctly:

```bash
git log --oneline -3
git show HEAD:manifests/kustomization.yaml
```

Confirm `- topic.yaml` appears in the resources list. If it does not, re-edit, commit, and push.
