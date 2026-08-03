# Lesson 2: Promoting Changes Across Environments

**Series:** GitOps with StreamsHub — 3-part series  
**Time:** ~25 minutes (plus ~8 minutes for first-time setup, ~5 minutes for prep)

---

## What you will learn

By the end of this lesson you will understand:

- How **kustomize overlays** let you share a base configuration and layer environment-specific differences on top
- How ArgoCD can manage multiple Applications from a single Git repository, each watching a different path
- What it means to **promote** a change from staging to production — and why it is just a Git change

You will do this by observing a staging environment with a deployed Kafka topic, then promoting that topic to production by editing a single file and pushing to Git.

---

## Prerequisites

If you haven't done this yet, run through the [Getting Started](../00-setup/README.md) guide. You only need to do this once. (takes ~8 minutes)

---

## Background: Why environments matter

In Lesson 1 you made a single change in the configuration hosted in the git repository and watched it be applied to the the cluster automatically. In practice, organisations don't push changes directly to production — they promote changes through a chain of environments: developers push to **staging** first, validate the change, then promote to **production**.

The key insight: promotion from one environment to another, in a GitOps world, is not a deploy command. It is a change in a git repository. You describe what each environment should look like in the configuration in the repo and ArgoCD continuously reconciles each environment to match its description. Promoting a change means updating the description for the target environment and pushing.

**Kustomize overlays** are the kubernetes-native mechanism for managing configurations. You keep a shared base configuration and then have one overlay per environment that references the base and adds or patches environment-specific resources. ArgoCD points a separate Application at each overlay.

---

## Setup

Run the prep script from this directory:

```bash
./prep.sh
```

This takes approximately 5 minutes. It:

1. Removes the Lesson 1 state from the cluster
2. Configures the Strimzi operator to watch the new namespaces
3. Seeds the Gitea repository with the multi-environment overlay structure
4. Creates two ArgoCD Applications — one for staging and one for production
5. Waits for both Kafka clusters to become ready

When it finishes it prints the Gitea and ArgoCD credentials.

You can re-run `./prep.sh` at any time to reset back to the lesson starting state.

---

## Part 1: Explore the environment

### Clone the repository

```bash
git clone http://tutorial-user:tutorial-password@localhost:3001/tutorial-user/streamshub-gitops.git /tmp/gitops-lesson-2
cd /tmp/gitops-lesson-2
```

### Check what's running in each environment

```bash
kubectl get kafka -n kafka-staging
kubectl get kafka -n kafka-production
```

Both should show `READY: True` — you have two independent Kafka clusters, each in its own namespace.

Now check for topics:

```bash
kubectl get kafkatopic -n kafka-staging
kubectl get kafkatopic -n kafka-production
```

You should see `my-first-topic` in staging, but nothing in production. **This is the starting state: staging is ahead of production.**

### Check the ArgoCD Applications

```bash
kubectl get application -n argocd
```

You'll see two Applications: `kafka-staging` and `kafka-production`. Each one watches a different path in the same Git repository, and each deploys to a different namespace.

---

## Part 2: Understand the overlay structure

Look at how the repository is organised:

```bash
ls manifests/
```

Instead of a flat `manifests/` directory as in Lesson 1, you'll see:

```
manifests/
├── base/
│   ├── kustomization.yaml
│   ├── kafka.yaml
│   └── combined-pool.yaml
└── overlays/
    ├── staging/
    │   ├── kustomization.yaml
    │   ├── namespace.yaml
    │   └── topic.yaml
    └── production/
        ├── kustomization.yaml
        ├── namespace.yaml
        └── topic.yaml
```

### The base

```bash
cat manifests/base/kustomization.yaml
```

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - combined-pool.yaml
  - kafka.yaml
```

The base contains the shared Kafka cluster definition. It has no namespace or environment-specific configuration — those come from the overlays.

### The staging overlay

```bash
cat manifests/overlays/staging/kustomization.yaml
```

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: kafka-staging
resources:
  - ../../base
  - namespace.yaml
  - topic.yaml
```

The staging overlay:
- Sets `namespace: kafka-staging` — kustomize applies this to every resource from the base
- Includes the base (shared Kafka config)
- Adds its own `namespace.yaml` (to create the `kafka-staging` namespace)
- Adds `topic.yaml` (the Kafka topic)

The ArgoCD `kafka-staging` Application points to this directory. When kustomize renders it, ArgoCD gets the full set of resources: namespace, Kafka cluster, KafkaNodePool, and topic — all in the `kafka-staging` namespace.

### The production overlay

```bash
cat manifests/overlays/production/kustomization.yaml
```

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: kafka-production
resources:
  - ../../base
  - namespace.yaml
```

Notice that `topic.yaml` is **absent** from the resources list — even though the file exists:

```bash
ls manifests/overlays/production/
```

`topic.yaml` is there, waiting. But because it is not in `kustomization.yaml`, ArgoCD ignores it. The production Kafka cluster is running, but no topic has been promoted to it yet.

This is the same pattern as Lesson 1 — a file existing in the repository does not mean it is deployed. Only what appears in `kustomization.yaml` gets deployed.

---

## Part 3: Promote the topic to production

Your staging team has validated `my-first-topic` and it is ready for production. Promoting it is a single Git change.

Open `manifests/overlays/production/kustomization.yaml` in your editor and add `- topic.yaml` to the resources list:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: kafka-production
resources:
  - ../../base
  - namespace.yaml
  - topic.yaml
```

Save, commit, and push:

```bash
git add manifests/overlays/production/kustomization.yaml
git commit -m "Promote my-first-topic to production"
git push
```

That is the promotion. You changed the configuration in Git; the system will reconcile to match.

---

## Part 4: Watch both ArgoCD Applications

Just as in lesson 1, ArgoCD polls the repository every 3 minutes by default. If you want to skip that wait, you can force an immediate refresh by running:

```bash
kubectl annotate application kafka-production -n argocd \
  argocd.argoproj.io/refresh=normal --overwrite
```

Watch the production Application detect and apply your change:

```bash
kubectl get application kafka-production -n argocd -w
```

The `SYNC STATUS` column will move from `Synced` → `OutOfSync` → `Synced`. Press `Ctrl+C` once it settles. Remember, you only changed the production overlay, so only the production Application was affected.

### Verify the topic is in production

Once `kafka-production` shows `Synced`:

```bash
kubectl get kafkatopic -n kafka-production
```

Expected output:

```
NAME             CLUSTER      PARTITIONS   REPLICATION FACTOR   READY
my-first-topic   my-cluster   3            1                    True
```

Confirm staging is unchanged:

```bash
kubectl get kafkatopic -n kafka-staging
```

Same topic, same configuration. **You promoted a change from staging to production by pushing a single-line Git change.**

---

## How it worked

```
git push
  └─▶ Gitea receives the commit

ArgoCD polls Gitea every 3 minutes
  └─▶ kafka-staging Application: manifests/overlays/staging → no change → stays Synced
  └─▶ kafka-production Application: manifests/overlays/production → topic.yaml now included
  └─▶ ArgoCD applies the diff to the kafka-production namespace — creating the KafkaTopic resource

Strimzi Topic Operator (watching kafka-production)
  └─▶ Strimzi sees the new KafkaTopic and creates the topic inside the kafka-production Kafka broker
```

Each Application is independent. Changes to one overlay do not affect the other. The Git repository is the source of truth for both environments, and the overlay structure makes clear exactly what each environment contains.

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

Log in with username `admin`. You will see both `kafka-staging` and `kafka-production` Applications. Click each one to see its resource tree — the resources are the same (Namespace, KafkaNodePool, Kafka), but one includes a KafkaTopic and the other does not.

---

## Optional: Force an immediate sync

To trigger ArgoCD without waiting up to 3 minutes:

```bash
kubectl annotate application kafka-production -n argocd \
  argocd.argoproj.io/refresh=normal --overwrite
```

---

## Bonus: Environment-specific configuration

So far you promoted `my-first-topic` to production with exactly the same configuration as staging — 3 partitions. In the real world, production often needs a different configuration: more partitions for throughput, a longer retention period, higher replication.

You can patch resources in an overlay by simply editing the overlay's copy of the file.

Open `manifests/overlays/production/topic.yaml` and increase the partition count to match production-scale requirements:

```yaml
apiVersion: kafka.strimzi.io/v1
kind: KafkaTopic
metadata:
  name: my-first-topic
  labels:
    strimzi.io/cluster: my-cluster
spec:
  partitions: 10
  replicas: 1
  config:
    retention.ms: "86400000"
    segment.bytes: "1073741824"
```

Commit and push:

```bash
git add manifests/overlays/production/topic.yaml
git commit -m "Set production topic to 10 partitions"
git push
```

After ArgoCD syncs, verify the partition counts in each environment:

```bash
kubectl get kafkatopic my-first-topic -n kafka-production -o jsonpath='{.spec.partitions}'; echo
kubectl get kafkatopic my-first-topic -n kafka-staging -o jsonpath='{.spec.partitions}'; echo
```

Production shows `10`; staging still shows `3`. **The environments are independently configurable** — a change to one overlay has no effect on the other.

---

## What you've learned

- Kustomize overlays let you share a base configuration and layer environment-specific changes on top without duplicating files
- ArgoCD can manage multiple Applications from a single Git repository, each watching a different path
- Promotion is a Git change — adding a resource to the target environment's `kustomization.yaml` is all it takes
- Environments are isolated from each other: a change to one overlay does not affect others
- In production, you would typically use separate clusters or ArgoCD instances per environment; the promotion principle is identical — it is always a Git change that drives the sync

---

## Cleanup

When you are done with all lessons, delete the cluster:

```bash
../00-setup/teardown.sh
```

Clean up the cloned repo:

```bash
rm -rf /tmp/gitops-lesson-2
```

---

## What's next

In **Lesson 3: Rolling Back a Bad Change**, you will use `git revert` to undo a broken configuration that has already reached production — and watch GitOps automatically restore the cluster to the last known-good state.

---

## Troubleshooting

**Infrastructure is not running**  
If `./prep.sh` reports that the cluster or Strimzi is not found, run the setup script first: `../00-setup/setup.sh`.

**Kafka clusters are not becoming ready**  
Both clusters start in parallel. Check pod status in each namespace:

```bash
kubectl get pods -n kafka-staging
kubectl get pods -n kafka-production
```

If pods are in `Pending` state, your Docker memory may be insufficient. This lesson requires ~8 GB. Check Docker Desktop's memory settings.

**ArgoCD Application is not syncing**  
Check for error messages:

```bash
kubectl get application kafka-production -n argocd -o yaml
```

If Gitea is unreachable from inside the cluster:

```bash
kubectl get pods -n gitea
```

**Topic is not appearing after sync**  
Confirm your edit was committed correctly:

```bash
git log --oneline -3
git show HEAD:manifests/overlays/production/kustomization.yaml
```

Confirm `- topic.yaml` appears in the resources list.

**Strimzi is not managing the Kafka clusters**  
Check the operator logs to confirm it is watching both namespaces:

```bash
kubectl logs deployment/strimzi-cluster-operator -n strimzi-operator | grep STRIMZI_NAMESPACE
```

You should see `kafka-staging,kafka-production`.
