+++
title = 'GitOps Tutorial Series: Lesson 2 Companion Guide'
+++

# Introduction

In lesson 1 you made your first GitOps change: you edited `kustomization.yaml`, pushed to Git, and watched ArgoCD reconcile the cluster to match. That workflow demonstrates the core GitOps loop, but it operates on a single environment. In practice, organisations do not push changes directly to production. They maintain a chain of environments — staging first, then production — and validate changes at each stage before promoting them forward. This practice of *environment promotion* is central to how teams ship safely at scale.

This guide explains how Kustomize overlays solve the multi-environment configuration problem and how ArgoCD manages multiple environments independently from a single Git repository. You will see why promotion in a GitOps world is not a deploy command or a pipeline trigger — it is a Git commit that updates the target environment's desired state.

# Core Concepts

## The Multi-Environment Problem

Organisations maintain chains of environments to reduce risk. Changes are deployed to a lower environment first, validated, and then promoted to the next. A misconfigured resource is caught in staging rather than discovered in production. The challenge arises in managing configuration across these environments: each one needs the same core infrastructure — the same cluster definition, the same node pool — but with different settings, such as different namespaces, different scaling parameters, or different retention policies.

Duplicating entire configuration files per environment is fragile. A change to the shared cluster definition would need to be applied to every copy independently, and a missed update creates configuration drift between environments. What you need is a way to define shared configuration once and layer environment-specific differences on top.

## The Kustomize Base and Overlay Pattern

Kustomize addresses this with a *base and overlay* pattern. The *base* directory contains resources shared across all environments — your core cluster definition, node pools, and any configuration that should be identical everywhere. Each environment then gets its own *overlay* directory that references the base and layers environment-specific resources or configuration on top.

Each overlay's `kustomization.yaml` includes the base via a relative path and sets a `namespace:` field that Kustomize injects into every resource it renders. This means the same cluster definition in the base becomes a staging cluster or a production cluster depending on which overlay renders it. Resources that should exist in only one environment — such as a topic that is ready for staging but not yet for production — are simply included only in that overlay's resource list.

Key benefits of adopting the base and overlay pattern include:

* **No configuration duplication**: shared resources are defined once in the base and inherited by every overlay, so a change to the base propagates to all environments automatically.  
* **Scoped customisation**: each overlay contains only its environment's specific differences, making it immediately clear what varies between staging and production.  
* **Straightforward scaling**: adding a new environment means creating a new overlay directory and a corresponding ArgoCD Application, not duplicating an entire set of configuration files or building a new pipeline.

## Promotion as a Git Commit

In a traditional workflow, promoting a change from staging to production means triggering a deployment pipeline or running a command against the target environment. In GitOps, *promotion* is a configuration change. You copy the resource into the target environment's overlay, add it to that overlay's `kustomization.yaml`, and commit. No deploy command is run. No pipeline is triggered. The commit itself is the promotion, and the reconciliation loop takes care of the rest.

This makes every promotion *auditable* and *reviewable*. Each promotion is a Git commit with an author and a timestamp. In a team setting it would take the form of a pull request, reviewed by peers before merging. The Git history becomes a complete record of what was promoted, when, and by whom — the same traceability that developers expect for code changes, extended to infrastructure operations.

## Multiple ArgoCD Applications

ArgoCD supports the multi-environment pattern through multiple *Application* resources, each configured to watch a different directory path in the same Git repository and deploy to a different namespace. In the lesson, a `kafka-staging` Application watches the staging overlay and deploys to the `kafka-staging` namespace, while a `kafka-production` Application watches the production overlay and deploys to `kafka-production`. ArgoCD evaluates each Application independently on every poll cycle.

This independence provides *environment isolation*. When you push a commit that adds a resource to the production overlay, only the production Application detects a change and syncs. The staging Application sees no difference in its watched path and remains unaffected. Changes to one environment cannot accidentally affect another, because each Application's scope is limited to its own overlay directory and target namespace.

# What to watch for in the lesson

Now that you have looked at the core concepts and technologies behind environment promotion, it is almost time to dive in, but as you do look out for these moments where the concepts above become concrete:

\- When you explore the `manifests/` directory and see `base/`, `overlays/staging/`, and `overlays/production/`, you are looking at the Kustomize base and overlay pattern in practice — shared configuration in the base, with environment-specific layers on top.  
\- When you copy `topic.yaml` into the production overlay, add it to `kustomization.yaml`, and run `git push`, you are performing a GitOps promotion — the commit that updates the target environment's desired state is the only deploy action required.  
\- When ArgoCD syncs the `kafka-production` Application while `kafka-staging` remains unchanged, you are seeing environment isolation — each Application independently watches its own overlay path, so a change to one environment never affects another.  
Now you're ready to try the second lesson, check out the lesson 2 readme to run through the tutorial.
