+++
title = 'GitOps Lesson 1: Your First GitOps Change'
+++

# Background

In our introductory article, "[Introduction to GitOps](../introduction/_index.md)" we explained how GitOps applies the proven principles of version control and continuous delivery (CD) to infrastructure, allowing you to treat operations the same way you treat code. 
With GitOps, you skip clicking through menus and checking boxes. 
Instead, you describe your system in a set of configuration files stored in a git repository. 
This repository becomes your *single source of truth* for how everything should look. 
You then rely on automation to turn your description into reality.

This tutorial aims to give you a practical demonstration of two key GitOps concepts, Infrastructure as Code (IaC) and the reconciliation loop, alongside two tools that bring them to life: Kustomize and Argo CD.

## Core Concepts

### Infrastructure as Code

IaC is the practice of managing and provisioning your infrastructure using configuration files rather than manual processes, e.g. ClickOps. 
By treating infrastructure as code, you define your system's desired state in configuration files and check them into a version control system like a git repository. 
This approach transforms operations, allowing you to track changes, collaborate, and automate deployments.

Key benefits of adopting IaC include:

* **Consistency and eliminating configuration drift**: By using versioned configuration files, you ensure environments remain consistent, effectively eliminating the manual changes that cause configuration drift.  
* **Disaster recovery**: Because your infrastructure state is codified in version control, rebuilding your environment in the event of a failure is as straightforward as applying your existing configurations.  
* **Reproducible builds**: IaC enables reliable, repeatable infrastructure deployments, ensuring that the same configuration results in the same environment every time.

### Kustomize

Kustomize is a configuration management tool built directly into the Kubernetes command line tool (`kubectl`), which simplifies managing Kubernetes objects.
It enables IaC by allowing you to define a common "base" set of configuration files and then apply "overlays" to patch them for different environments, such as staging or production, without relying on messy templating. 
This ensures that your configurations remain clean, consistent, and reproducible. 

Throughout these lessons you will create, edit and deploy Kustomize manifests to effect changes to the deployed cluster. 
You can learn more in the [official Kustomize documentation](https://kustomize.io/).

### The Reconciliation Loop

The reconciliation loop is the mechanism that transforms IaC into actual, running infrastructure by continuously monitoring the configuration repository and automatically applying changes to the running infrastructure to reach the desired state.
By choosing off-the-shelf tooling, you gain significant speed and operational efficiency from this automation. 
Popular tools that implement this reconciliation pattern include [Argo CD](https://argoproj.github.io/cd/) and [Flux](https://fluxcd.io).

### Argo CD

Argo CD is an open-source, CD tool that runs inside your Kubernetes cluster and implements the reconciliation loop described above. 
It is the CD technology you will be working with in all the lessons in this series. 

You tell Argo CD what to watch by creating an *Application* resource in Kubernetes, a small piece of configuration that says: "monitor this Git repository, look at this directory path, and deploy whatever you find there into this namespace." 
Argo CD then polls the repository on a regular interval (every three minutes by default, however in our tutorial series we’ve reduced that to thirty seconds for convenience), renders the manifests it finds, and syncs the cluster to match.

Argo CD exposes the state of this process through two key concepts: *sync status* and *health status*. 
*Sync status* tells you whether the cluster matches the configuration in your Git repository; *Synced* means they match, whereas *OutOfSync* means Argo CD has detected a difference and will act on it. 
In the lesson, you will see this status transition when you push a change: it moves from *Synced* to *OutOfSync* (Argo CD noticed the new commit) and back to *Synced* (Argo CD applied the change). 
Health status is a separate concern that tells you whether the resources themselves are functioning correctly, we’ll explore health status in more detail in Lesson 3. 

## What to watch for in the lesson

Now that you’ve looked at the core concepts and technologies you’ll be working with in this lesson, it’s almost time to dive in, but as you do look out for these moments where the concepts above become concrete:

* When you edit `kustomization.yaml`, you are declaratively changing the desired state of the cluster.  
* When you run `git push`, you are updating the single source of truth. From this moment, the configuration in the repository says a topic should exist.  
* When Argo CD's status transitions from `Synced` to `OutOfSync` and back to `Synced`, you are watching the reconciliation loop complete a full cycle: observe the change, calculate the required changes and then roll them out.  

You’re now ready to work through the hands-on tutorial that follows.

# Tutorial

## What you will learn

By the end of this lesson you will understand:

- What the GitOps workflow looks like in practice
- How ArgoCD watches a Git repository and automatically applies changes to a Kubernetes cluster
- How Strimzi manages Kafka resources declaratively

You will do this by making a real change — adding a Kafka topic — and watching it flow automatically from Git to a running cluster, without ever running `kubectl apply` yourself.

## Prerequisites

If you haven't done this yet, run through the [Preparing For The Tutorials](setup.md) guide. You only need to do this once.

## The GitOps idea in one paragraph

In traditional operations you make changes to a running system by running commands directly against it — `kubectl apply`, a config panel, an API call. GitOps flips this around: a Git repository is the single source of truth for what the system should look like. A tool (in this case ArgoCD) watches the repository and continuously reconciles the live system to match. If the config in the git repository says a topic should exist, then the topic will be created. If you remove it from the config repository, it disappears from the cluster. You never touch the system directly; you only change the configuration in the repo. You now have, thanks to git, a record of all the changes made, when they were made and by who. You can also setup all kinds of sanity and safety checks to run against those changes before they are applied.

## Setup

Run the prep script from this directory:

```bash
./prep.sh
```

This takes under a minute. It resets the Gitea repository to the lesson-1 starting state and confirms that ArgoCD has synced. When it finishes it prints the Gitea and ArgoCD credentials.

You can re-run `./prep.sh` at any time to reset back to the lesson starting state — useful if you make a mistake and want to start over without re-running the full setup.

## Part 1: Look at what's already running

Before you make any changes, take a moment to explore the environment. This is where the lesson starts: everything you are about to see was deployed by ArgoCD from Git.

### Clone the repository

The Gitea server is running inside the cluster. When you ran the `./prep.sh` script, it printed the exact `git clone` command to use (the Gitea address can vary depending on how your cluster exposes it), run that command, it will follow the below format:

```bash
git clone <external address of gitea server> /tmp/gitops-lesson-1
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

## What's next

In [Lesson 2](lesson-2.md), you will build on this environment by creating separate staging and production configurations and walk through the process of promoting a change through environments — the same Git-as-source-of-truth principle, applied to multi-environment workflows.