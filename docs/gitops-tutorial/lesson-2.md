+++
title = 'GitOps Lesson 2: Promoting Changes Across Environments'
+++

# Background

In lesson 1, you successfully performed your first GitOps change. 
You edited your cluster configuration, pushed it to Git, and watched as Argo CD handled the heavy lifting of reconciling and rolling out those updates. 
This workflow is the heart of the GitOps loop: you define your infrastructure as code and let automation ensure your cluster matches that vision.

But what happens when your project starts to scale? 
As organizations grow, managing infrastructure becomes a high-stakes balancing act. 
You cannot simply push every change directly to production and hope for the best. 
Instead, you need a reliable way to validate changes in a staging environment before promoting them forward. 
This practice of environment promotion is how you ship safely at scale.

The real challenge lies in keeping these environments in sync. 
While staging and production will have intentional differences, like the number of replicas or resource quotas, they should stay functionally identical. 
If they diverge, you lose the ability to guarantee that a successful test in staging will actually work in production. 
Relying on manual "ClickOps" processes makes this divergence inevitable. 
Without a controlled pipeline, minor discrepancies accumulate over time into configuration drift that is difficult to track.

As we’ve previously discussed, by adopting GitOps you define your infrastructure as configuration managed within a Git repository. 
This repository serves as the single source of truth for your environments, allowing you to move away from the manual, error-prone processes that inevitably lead to configuration drift.

In this lesson, we will explore how Kustomize overlays handle these multi-environment configurations and how Argo CD manages them independently from a single repository. 
You will see that promotion in a GitOps world is not about running a manual deploy command. 
Instead, it is a simple configuration change followed by a Git commit that updates the desired state for your target environment.

## Core Concepts

### Multi-Environment Configuration

We previously discussed why organizations maintain multiple environments and how GitOps helps you avoid configuration drift by defining your environments in configuration files. 
However, simply creating separate configuration files for each environment is still problematic. 
Maintaining multiple files is inherently fragile, as updating a shared cluster definition would require you to modify every copy independently. 
If you miss a single update, you introduce the very drift you were trying to avoid. 
Instead, you need a way to define your shared configuration once and layer environment-specific differences on top.

### The Kustomize Base and Overlay Pattern

So, how do we solve the duplication problem without losing our minds? 
This is where Kustomize steps in with its 'base and overlay' pattern. 
Think of the base as your primary definition for your environments. 
It contains all the shared configuration that every environment needs. 
Your core cluster definition stays here, defined exactly once. 
Then, you have your overlays. 
These are simply separate directories for each environment, like staging or production. 
An overlay references the base and then layers on just the differences. 
If you need a different namespace or extra scaling parameters for production, you define those specific overrides in that environment's overlay.

Each overlay includes a kustomization.yaml file that tells Kustomize how to glue things together. 
When it runs, Kustomize takes the base, injects the environment-specific settings, and generates the final configuration.

Why is this approach a game changer?

* **No more configuration duplication:** Because shared resources live in the base, you update them once and the change flows to every environment automatically.  
* **Crystal clear customization:** Each overlay only contains the specific differences for that environment. 
  You can see at a glance exactly how staging differs from production.  
* **Easy scaling:** Need to add a new environment? Just create a new overlay directory and a matching Argo CD Application. 
  You don't need to copy entire sets of files or build a complex new pipeline.

### Promotion as a Git Commit

As you saw in Lesson 1, you change the state of your cluster by updating the configuration and pushing it to your Git repository. 
Promotion is no different, you simply update the production overlay and push the commit. 
This approach ensures every promotion is auditable and reviewable, in Lesson 3 you’ll see why this is important.

### Multiple Argo CD Applications

Argo CD supports the multi-environment pattern through multiple *Application* resources, each configured to watch a different directory path in the same Git repository and deploy to a different namespace (in a real system this would probably be a separate Kubernetes cluster). 
In the lesson, we’ll use a separate Application for staging and production. 
Argo CD evaluates each Application independently on every poll cycle.

This independence provides *environment isolation*. 
When you push a commit that adds a resource to the production overlay, only the production Application detects a change and triggers a roll out. 
Changes to one environment cannot accidentally affect another, because each Application's scope is limited to its own overlay directory and target namespace.

## What to watch for in the lesson

Now that you have explored the core concepts and technologies behind environment promotion, it is time to dive in. 
As you do, look out for these moments where the concepts become concrete:

* When you explore the `manifests/` directory and see `base/`, `overlays/staging/`, and `overlays/production/`, you are looking at the Kustomize base and overlay pattern in practice: shared configuration in the base, with environment-specific layers on top. 
* When you copy `topic.yaml` into the production overlay, add it to `kustomization.yaml`, and run git push, you are performing a GitOps promotion. 
  The commit that updates the target environment's desired state is the only deployment action required.  
* When Argo CD syncs the kafka-production Application while kafka-staging remains unchanged, you are seeing environment isolation. 
  Because each Application independently watches its own overlay path, a change to one environment never affects another.

You’re now ready to work through the hands-on tutorial that follows.

# Tutorial

## What you will learn

By the end of this lesson you will understand:

- How **kustomize overlays** let you share a base configuration and layer environment-specific differences on top
- How ArgoCD can manage multiple Applications from a single Git repository, each watching a different path
- What it means to **promote** a change from staging to production — and why it is just a configuration change, pushed to your Git repository.

You will do this by observing a staging environment with a deployed Kafka topic, then promoting that topic to production by copying it into the production overlay and pushing to Git.

## Prerequisites

If you haven't done this yet, run through the [Preparing For The Tutorials](setup.md) guide. You only need to do this once.

## Why environments matter

In Lesson 1 you made a single change in the configuration hosted in the Git repository and watched it be applied to the the cluster automatically. In practice, organisations don't push changes directly to production — they promote changes through a chain of environments: developers push to **staging** first, validate the change, then promote to **production**.

The key insight: promotion from one environment to another, in a GitOps world, is not a deploy command. It is a change in a Git repository. You describe what each environment should look like in the configuration in the repo and ArgoCD continuously reconciles each environment to match its description. Promoting a change means updating the description for the target environment and pushing.

**Kustomize overlays** are the kubernetes-native mechanism for managing configurations. You keep a shared base configuration and then have one overlay per environment that references the base and adds or patches environment-specific resources. ArgoCD points a separate Application at each overlay.


## Setup

Run the prep script from this directory:

```bash
./prep.sh
```

This takes approximately 5 minutes. It:

1. Removes the Lesson 1 state from the cluster
2. Seeds the Gitea repository with the multi-environment overlay structure
3. Creates two ArgoCD Applications — one for staging and one for production
4. Waits for both Kafka clusters to become ready

When it finishes it prints the Gitea and ArgoCD credentials.

You can re-run `./prep.sh` at any time to reset back to the lesson starting state.

## Part 1: Explore the environment

### Clone the repository

When you ran the `./prep.sh` script, it printed the exact `git clone` command to use (the Gitea address can vary depending on how your cluster exposes it), run that command, it will follow the below format:

```bash
git clone <external address of gitea server> /tmp/gitops-lesson-2
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

## Part 2: Understand the overlay structure

Look at how the repository is organised:

```bash
tree manifests/
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
        └── namespace.yaml
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

You can render the full overlay yourself to see exactly what ArgoCD will apply:

```bash
kubectl kustomize manifests/overlays/staging
```

Notice that every resource has `namespace: kafka-staging` injected — that is kustomize combining the base with the overlay.

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

Notice that `topic.yaml` is **absent** — both from the resources list and from the directory itself. The topic only exists in the staging overlay. The production Kafka cluster is running, but no topic has been promoted to it yet.

## Part 3: Promote the topic to production

Your staging team has validated `my-first-topic` and it is ready for production. Promoting it means copying the topic definition from the staging overlay into the production overlay and adding it to production's `kustomization.yaml` — both changes together as a single atomic commit.

First, copy the topic definition from staging into production:

```bash
cp manifests/overlays/staging/topic.yaml manifests/overlays/production/topic.yaml
```

Then open `manifests/overlays/production/kustomization.yaml` in your editor and add `- topic.yaml` to the resources list:

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
git add manifests/overlays/production/
git commit -m "Promote my-first-topic to production"
git push
```

That is the promotion. The topic definition and the kustomize entry arrive together — just as they would in a real pull request. You changed the configuration in the Git repository; the system will reconcile to match.

## Part 4: Watch both ArgoCD Applications

ArgoCD polls the repository every 30 seconds. Watch the production Application detect and apply your change:

```bash
kubectl get application kafka-production -n argocd -w
```

The `SYNC STATUS` column will move from `Synced` → `OutOfSync` → `Synced` within about 30 seconds. Press `Ctrl+C` once it settles. Remember, you only changed the production overlay, so only the production Application was affected.

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

Same topic, same configuration. **You promoted a change from staging to production by copying the resource and updating the kustomization — a single atomic Git commit.**

## How it worked

```
git push
  └─▶ Gitea receives the commit

ArgoCD polls Gitea every 30 seconds
  └─▶ kafka-staging Application: manifests/overlays/staging → no change → stays Synced
  └─▶ kafka-production Application: manifests/overlays/production → topic.yaml now included
  └─▶ ArgoCD applies the diff to the kafka-production namespace — creating the KafkaTopic resource

Strimzi Topic Operator
  └─▶ Strimzi sees the new KafkaTopic and creates the topic inside the kafka-production Kafka broker
```

Each Application is independent. Changes to one overlay do not affect the other. The configuration in the Git repository is the source of truth for both environments, and the overlay structure makes clear exactly what each environment contains.

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

## What you've learned

- Kustomize overlays let you share a base configuration and layer environment-specific changes on top without duplicating files
- ArgoCD can manage multiple Applications from a single Git repository, each watching a different path
- Promotion is a configuration change — copying a resource into the target overlay and adding it to `kustomization.yaml`, followed by a Git commit and push, is all it takes
- Environments are isolated from each other: a change to one overlay does not affect others
- In production, you would typically use separate clusters or ArgoCD instances per environment; the promotion principle is identical — it is always a configuration change, pushed to your Git repository that drives the sync

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
Confirm both files were committed correctly:

```bash
git log --oneline -3
git show HEAD:manifests/overlays/production/kustomization.yaml
```

Confirm `- topic.yaml` appears in the resources list and the topic file exists:

```bash
git show HEAD:manifests/overlays/production/topic.yaml
```

**Strimzi is not managing the Kafka clusters**  
Check that the operator is running and watching all namespaces:

```bash
kubectl get deployment strimzi-cluster-operator -n strimzi-operator
kubectl logs deployment/strimzi-cluster-operator -n strimzi-operator | grep STRIMZI_NAMESPACE
```

You should see `STRIMZI_NAMESPACE` set to `*`. If the operator is not running, re-run `../00-setup/setup.sh`.

## What's next

In [Lesson 3](lesson-3.md), you will use `git revert` to undo a broken configuration that has already reached production — and watch GitOps automatically restore the cluster to the last known-good state.
