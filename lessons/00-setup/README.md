# Getting Started

This directory sets up the shared infrastructure for the GitOps tutorial series. Run `setup.sh` once before starting any lesson.

---

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| **Docker** | Container runtime | [docker.com](https://www.docker.com/products/docker-desktop/) |
| **KinD** (v0.20+) | Local Kubernetes clusters (default) | `brew install kind` or [kind.sigs.k8s.io](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) |
| **Minikube** | Alternative to KinD | `brew install minikube` or [minikube.sigs.k8s.io](https://minikube.sigs.k8s.io/docs/start/) |
| **kubectl** | Kubernetes CLI | `brew install kubectl` or [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |
| **git** | Version control | `brew install git` or [git-scm.com](https://git-scm.com/) |
| **curl** | HTTP requests | Usually pre-installed |

You need **either** KinD or Minikube — not both. KinD is the default. See [Choosing a runtime](#choosing-a-runtime) below.

**System requirements:** ~4 GB of available memory for Docker.

---

## Choosing a runtime

KinD and Minikube both run a local Kubernetes cluster inside Docker. KinD is simpler to set up and is the default. Minikube is a good alternative if you already have it installed or if your organisation uses it in CI.

| | KinD (default) | Minikube |
|---|---|---|
| Gitea URL | `http://localhost:3001` | `http://<minikube-ip>:30003` |
| Setup flag | _(none)_ | `--runtime minikube` |

## Setup

Run the setup script from this directory:

```bash
# Using KinD (default)
./setup.sh

# Using Minikube
./setup.sh --runtime minikube
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

## Starting a lesson

After setup completes, run the prep script for the lesson you want. Pass the same `--runtime` flag you used for setup (if any):

```bash
# KinD (default)
cd ../01-lesson-1 && ./prep.sh

# Minikube
cd ../01-lesson-1 && ./prep.sh --runtime minikube
```

Each `prep.sh` resets the Gitea repository to that lesson's starting state and takes under a minute. You can switch between lessons, or re-run `prep.sh` to reset after making mistakes — without re-running `setup.sh`.

---

## Teardown

When you are done with all lessons, delete the cluster to remove everything:

```bash
# KinD (default)
./teardown.sh

# Minikube
./teardown.sh --runtime minikube
```

---

## Troubleshooting

**Docker is not running**
Start Docker Desktop or your container runtime and run `./setup.sh` again.

**Port 3001 is already in use (KinD only)**
Another application is using port 3001. Stop that application, or change the port in `kind-config.yaml` (update both `hostPort` and the `nodePort` in `gitea/deployment.yaml` to match). This issue does not apply to Minikube, which uses a different IP address rather than localhost ports.

**Kafka cluster is not becoming ready**
Kafka takes a few minutes to start, especially on machines with limited resources. Check pod status:

```bash
kubectl get pods -n kafka-tutorial
kubectl describe kafka my-cluster -n kafka-tutorial
```

**KinD cluster creation fails with "could not find a log line"**
This can happen if you have other KinD clusters already running — they exhaust the Linux kernel's inotify instance limit. If you're using Colima, increase the limit temporarily:

```bash
colima ssh -- sudo sysctl -w fs.inotify.max_user_instances=512
```

Then retry `./setup.sh`. The setting resets when the Colima VM restarts. This issue does not affect Minikube.

**Insufficient memory**
If pods are stuck in `Pending` or being evicted, Docker may not have enough memory. Increase Docker Desktop memory to at least 4 GB in Settings > Resources.
