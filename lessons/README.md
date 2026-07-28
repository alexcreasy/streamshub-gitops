# GitOps with StreamsHub

A hands-on tutorial series for learning GitOps with Apache Kafka on Kubernetes. Each lesson builds on the last, using real tools — ArgoCD, Strimzi, and a local Git server — running entirely on your machine.

---

## How the series works

A shared cluster runs for the whole series. You set it up once, then run a short prep script before each lesson to put the environment in the right starting state. Lessons take 20–30 minutes each and involve making real changes to a Git repository and watching the effects propagate to the cluster automatically.

---

## Lessons

| # | Title | What you will do |
|---|-------|-----------------|
| [Getting Started](00-setup/README.md) | Environment setup | Install the shared cluster, ArgoCD, Strimzi, and a local Git server. Run this once before any lesson. |
| [Lesson 1](01-lesson-1/README.md) | Your First GitOps Change | Add a Kafka topic by editing a file in Git and watch ArgoCD deploy it automatically — without running `kubectl apply`. |

---

## Start here

**1. Complete the one-time setup** (~8 minutes):

```bash
cd 00-setup
./setup.sh
```

**2. Run the prep script for Lesson 1**, then open its README:

```bash
cd 01-lesson-1
./prep.sh
```

See [Getting Started](00-setup/README.md) for prerequisites and troubleshooting.
