# GitOps Tutorial: Your First GitOps Deployment

This tutorial walks you through the core GitOps workflow: making a change in Git and watching it automatically deploy to a Kubernetes cluster. Everything runs locally on your machine — no cloud account required.

By the end, you will have:
- A local Kubernetes cluster running Apache Kafka (managed by Strimzi)
- ArgoCD watching a Git repository for changes
- Deployed a new Kafka topic by committing a change and pushing to Git

## Prerequisites

You need the following tools installed:

| Tool | Purpose | Install |
|------|---------|---------|
| **Docker** | Container runtime for KinD | [docker.com](https://www.docker.com/products/docker-desktop/) |
| **KinD** (v0.20+) | Local Kubernetes clusters | `brew install kind` or [kind.sigs.k8s.io](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) |
| **kubectl** | Kubernetes CLI | `brew install kubectl` or [kubernetes.io](https://kubernetes.io/docs/tasks/tools/) |
| **git** | Version control | `brew install git` or [git-scm.com](https://git-scm.com/) |
| **curl** | HTTP requests | Usually pre-installed |

**System requirements**: ~4 GB of available memory for Docker.

## Setup

Run the setup script from this directory:

```bash
./setup.sh
```

This takes approximately 5-8 minutes and will:

1. Create a local KinD Kubernetes cluster
2. Install **ArgoCD** (GitOps continuous delivery tool)
3. Install the **Strimzi operator** (manages Kafka on Kubernetes)
4. Install **Gitea** (a lightweight Git server running inside the cluster)
5. Create a Git repository in Gitea containing a minimal Kafka cluster definition
6. Configure ArgoCD to watch that repository
7. Wait for Kafka to become ready

When the script finishes, it prints the commands you need for the tutorial.

## Tutorial

### Step 1: Clone the repository

Clone the tutorial repository from the local Gitea server:

```bash
git clone http://tutorial-user:tutorial-password@localhost:3000/tutorial-user/streamshub-gitops.git /tmp/gitops-tutorial
cd /tmp/gitops-tutorial
```

### Step 2: Explore the current deployment

Look at what ArgoCD has deployed. You should see a running Kafka cluster:

```bash
kubectl get kafka -n kafka-tutorial
```

Expected output:
```
NAME         DESIRED KAFKA REPLICAS   DESIRED ZK REPLICAS   READY   METADATA STATE   WARNINGS
my-cluster   1                                              True    KRaft
```

Check that no Kafka topics exist yet (other than internal ones):

```bash
kubectl get kafkatopic -n kafka-tutorial
```

Now look at the manifests in the repository:

```bash
ls manifests/
```

You will see `namespace.yaml`, `combined-pool.yaml`, `kafka.yaml`, `topic.yaml`, and `kustomization.yaml`. Notice that `topic.yaml` defines a Kafka topic, but if you look at `kustomization.yaml`, it is **not listed** in the resources:

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

The topic file exists but ArgoCD is not deploying it because kustomize does not include it.

### Step 3: Add the topic to the deployment

Open `manifests/kustomization.yaml` in your editor and add `- topic.yaml` to the resources list:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - combined-pool.yaml
  - kafka.yaml
  - topic.yaml
```

### Step 4: Commit and push

```bash
git add manifests/kustomization.yaml
git commit -m "Add Kafka topic"
git push
```

### Step 5: Watch ArgoCD sync

ArgoCD polls the repository every 3 minutes by default. You can watch the sync status:

```bash
kubectl get application kafka-tutorial -n argocd -w
```

Wait until the `SYNC` column shows `Synced` and `STATUS` shows `Healthy`.

> **Tip**: To trigger an immediate sync instead of waiting, you can use the ArgoCD CLI or dashboard (see the optional section below).

### Step 6: Verify the topic was created

```bash
kubectl get kafkatopic my-first-topic -n kafka-tutorial
```

Expected output:
```
NAME             CLUSTER      PARTITIONS   REPLICATION FACTOR   READY
my-first-topic   my-cluster   3            1                    True
```

**Congratulations!** You just deployed a Kafka topic using GitOps. The change went from your editor, through Git, to ArgoCD, and was applied to the cluster automatically.

## Understanding What Happened

Here is the flow you just triggered:

1. **You edited** `kustomization.yaml` to include `topic.yaml`
2. **You pushed** the change to the Gitea Git server running in the cluster
3. **ArgoCD detected** the change by polling the Gitea repository
4. **ArgoCD rendered** the kustomize manifests, which now included the `KafkaTopic` resource
5. **ArgoCD applied** the `KafkaTopic` to the cluster
6. **Strimzi's Topic Operator** saw the new `KafkaTopic` custom resource and created the actual topic inside the Kafka broker

This is the GitOps loop: **Git is the source of truth**. You did not run `kubectl apply` manually — the change flowed automatically from Git to the cluster.

## Optional: Access the ArgoCD Dashboard

ArgoCD has a web dashboard where you can visualize the application and its resources.

In a separate terminal, start a port-forward:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Then open [https://localhost:8080](https://localhost:8080) in your browser (accept the self-signed certificate warning).

Retrieve the admin password:

```bash
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d; echo
```

Log in with username `admin` and the password above. Click on the `kafka-tutorial` application to see the deployed resources.

## Cleanup

When you are done, delete the KinD cluster to remove everything:

```bash
./teardown.sh
```

This deletes the entire cluster and all resources within it. You can also clean up the cloned repo:

```bash
rm -rf /tmp/gitops-tutorial
```

## Troubleshooting

**Docker is not running**
The setup script requires Docker. Start Docker Desktop or your container runtime and try again.

**Port 3000 is already in use**
Another application is using port 3000 (e.g., Grafana, a development server). Stop that application or change the port in `kind-config.yaml` (update both `hostPort` and the `nodePort` in `gitea/deployment.yaml` to match).

**Kafka cluster is not becoming ready**
Kafka requires time to start, especially on machines with limited resources. Check pod status:
```bash
kubectl get pods -n kafka-tutorial
kubectl describe kafka my-cluster -n kafka-tutorial
```

**ArgoCD is not syncing**
Check the application status for errors:
```bash
kubectl get application kafka-tutorial -n argocd -o yaml
```
Common issue: if the Gitea repository URL is unreachable from inside the cluster, check that the Gitea pod is running:
```bash
kubectl get pods -n gitea
```

**Insufficient memory**
If pods are being evicted or stuck in `Pending`, Docker may not have enough memory allocated. Increase Docker Desktop memory to at least 4 GB in Settings > Resources.
