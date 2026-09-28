# GitOps with StreamsHub

A hands-on tutorial series for learning GitOps with Apache Kafka on Kubernetes. Each lesson builds on the last, using real tools — ArgoCD, Strimzi, and a local Git server — running entirely on your machine.

## How the series works

A shared cluster runs for the whole series. You set it up once, then run a short prep script before each lesson to put the environment in the right starting state. Lessons take 20–30 minutes each and involve making real changes to a Git repository and watching the effects propagate to the cluster automatically.

## Where to find the lessons

The lesson content can be found [here](../docs/gitops-tutorial/_index.md).

## Verifying the tutorials

If you're contributing changes to the lessons, a smoke test script runs through all three lessons end-to-end to catch regressions, to run it:

```bash
cd 00-setup
./smoke-test.sh --create-cluster
```

This creates its own disposable KinD cluster, runs each lesson's workflow, and tears the cluster down afterwards — it won't affect a cluster you're already using. Expect it to take 15–20 minutes.

You can also run the tests against a pre-existing Kubernetes cluster. To run the tests against the current kubectl context:

```bash
cd 00-setup
./smoke-test.sh
```

