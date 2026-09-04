# Getting Started

This directory sets up the shared infrastructure for the GitOps tutorial series. Run `setup.sh` once before starting any lesson.

---

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| **kubectl** | Kubernetes CLI | [kubectl](https://kubernetes.io/docs/tasks/tools/) |
| **git** | Version control | [git-scm.com](https://git-scm.com/) |
| **curl** | HTTP requests | Usually pre-installed |

Additionally, if using `--create-cluster` to have the script provision a local KinD cluster for you:

| Tool | Purpose | Install |
|------|---------|---------|
| **Docker** or **Podman** | Container runtime | [docker](https://docs.docker.com/get-docker/)<br>[podman](https://podman.io/docs/installation) |
| **KinD** (v0.20+) | Local Kubernetes clusters | [KinD](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) |

**System requirements:** ~8 GB of available memory for Docker/Podman when using `--create-cluster`.

---

## Setup

Run the setup script from this directory:

```bash
./setup.sh --create-cluster
```

This takes approximately 8 minutes and creates a fully self-contained local environment:

1. A **KinD** Kubernetes cluster (`gitops-tutorial`) running on your machine
2. **ArgoCD** — the GitOps engine that watches Git and applies changes
3. **Strimzi** — the operator that manages Kafka resources on Kubernetes
4. **Gitea** — a lightweight Git server running inside the cluster, reachable at `http://localhost:3001`
5. A Git repository in Gitea containing the base Kafka configuration
6. An ArgoCD `Application` configured to watch that repository
7. A running Kafka cluster, already deployed via the GitOps workflow

When the script finishes, it prints the ArgoCD admin password and tells you which lesson prep script to run next.

---

## Using an existing cluster

If you already have a Kubernetes cluster (KinD set up differently, minikube, k3d, a remote cluster, etc.), you can skip local cluster provisioning entirely. This is the **default** behavior — running `./setup.sh` with no flags installs ArgoCD, Strimzi, and Gitea onto whatever `kubectl`'s current context points at, instead of creating a KinD cluster:

```bash
kubectl config use-context <your-context>
./setup.sh
```

You can also opt in explicitly with `CREATE_CLUSTER=true ./setup.sh`, but a flag/env var isn't needed for this mode since it's the default — `--create-cluster` (or `CREATE_CLUSTER=true`) is only needed when you *want* setup.sh to provision a local KinD cluster for you (flag takes precedence over the env var).

Things to know when using an existing cluster:

* **The cluster is assumed to be dedicated to this tutorial.** Setup doesn't check for or try to coexist with a pre-existing ArgoCD/Strimzi/Gitea install.
* **You need cluster-admin rights**, since setup installs cluster-scoped resources (CRDs, ClusterRoleBindings) for Strimzi and ArgoCD.
* **You are responsible for making Gitea reachable for each lesson.** `setup.sh` itself doesn't need you to do anything — if it can't reach Gitea directly, it starts its own temporary port-forward just long enough to finish configuring it, then tears it down. But from then on (running `prep.sh`, following a lesson), you're on your own: by default this means `http://localhost:3001`; if your cluster doesn't otherwise expose NodePort `30003` there, leave a port-forward running in another terminal for the duration of the tutorial:

  ```bash
  kubectl port-forward svc/gitea-http -n gitea 3001:3000
  ```

  `setup.sh` and every lesson's `prep.sh` always print the Gitea address they actually used — trust that output over any address written down here.

* **This tutorial targets plain Kubernetes.** It does not currently work out of the box against OpenShift (ArgoCD's Redis component fails OpenShift's default restricted SCC).

---

## Starting a lesson

After setup completes, follow the lesson guide of your choice:
* [Lesson 1: Your First GitOps Change](../01-lesson-1/README.md)

---

## Teardown

When you are done with all lessons:

* If you used `--create-cluster` (or `CREATE_CLUSTER=true`), delete the KinD cluster to remove everything:

  ```bash
  ./teardown.sh --delete-cluster
  ```

* Otherwise (existing-cluster mode, the default), remove just the resources this tutorial installed, leaving the rest of the cluster untouched:

  ```bash
  ./teardown.sh
  ```

---

## Troubleshooting

**Docker is not running**
Start Docker Desktop or your container runtime and run `./setup.sh --create-cluster` again.

**Port 3001 is already in use**
Another application is using port 3001. Stop that application, or (when using `--create-cluster`) change the port in `kind-config.yaml` (update both `hostPort` and the `nodePort` in `gitea/deployment.yaml` to match).

**Gitea is not reachable (existing-cluster mode)**
When not using `--create-cluster`, nothing automatically exposes Gitea's NodePort on your machine. Leave a port-forward running for the duration of the tutorial: `kubectl port-forward svc/gitea-http -n gitea 3001:3000`.

**Kafka cluster is not becoming ready**
Kafka takes a few minutes to start, especially on machines with limited resources. Check pod status:

```bash
kubectl get pods -n kafka-tutorial
kubectl describe kafka my-cluster -n kafka-tutorial
```
