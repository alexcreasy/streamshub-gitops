+++
title = 'GitOps Tutorial Series: Lesson 2 Companion Guide'
+++

# Introduction

In lesson 1, you successfully performed your first GitOps change. You edited your cluster configuration, pushed it to Git, and watched as ArgoCD handled the heavy lifting of reconciling and rolling out those updates. This workflow is the heart of the GitOps loop: you define your infrastructure as code and let automation ensure your cluster matches that vision.

But what happens when your project starts to scale? As organizations grow, managing infrastructure becomes a high-stakes balancing act. You cannot simply push every change directly to production and hope for the best. Instead, you need a reliable way to validate changes in a staging environment before promoting them forward. This practice of environment promotion is how you ship safely at scale.

The real challenge lies in keeping these environments in sync. While staging and production will have intentional differences, like the number of replicas or resource quotas, they should stay functionally identical. If they diverge, you lose the ability to guarantee that a successful test in staging will actually work in production. Relying on manual "ClickOps" processes makes this divergence inevitable. Without a controlled pipeline, minor discrepancies accumulate over time into configuration drift that is difficult to track.

As we’ve previously discussed, by adopting GitOps you define your infrastructure as configuration managed within a Git repository. This repository serves as the single source of truth for your environments, allowing you to move away from the manual, error-prone processes that inevitably lead to configuration drift.

In this lesson, we will explore how Kustomize overlays handle these multi-environment configurations and how ArgoCD manages them independently from a single repository. You will see that promotion in a GitOps world is not about running a manual deploy command. Instead, it is a simple configuration change followed by a Git commit that updates the desired state for your target environment.

# Core Concepts

## Multi-Environment Configuration

We previously discussed why organizations maintain multiple environments and how GitOps helps you avoid configuration drift by defining your environments in configuration files. However, simply creating separate configuration files for each environment is still problematic. Maintaining multiple files is inherently fragile, as updating a shared cluster definition would require you to modify every copy independently. If you miss a single update, you introduce the very drift you were trying to avoid. Instead, you need a way to define your shared configuration once and layer environment-specific differences on top.

## The Kustomize Base and Overlay Pattern

So, how do we solve the duplication problem without losing our minds? This is where Kustomize steps in with its 'base and overlay' pattern. Think of the base as your primary definition for your environments. It contains all the shared configuration that every environment needs. Your core cluster definition stays here, defined exactly once. Then, you have your overlays. These are simply separate directories for each environment, like staging or production. An overlay references the base and then layers on just the differences. If you need a different namespace or extra scaling parameters for production, you define those specific overrides in that environment's overlay.

Each overlay includes a kustomization.yaml file that tells Kustomize how to glue things together. When it runs, Kustomize takes the base, injects the environment-specific settings, and generates the final configuration.

Why is this approach a game changer?

* **No more configuration duplication:** Because shared resources live in the base, you update them once and the change flows to every environment automatically.  
* **Crystal clear customization:** Each overlay only contains the specific differences for that environment. You can see at a glance exactly how staging differs from production.  
* **Easy scaling:** Need to add a new environment? Just create a new overlay directory and a matching ArgoCD Application. You don't need to copy entire sets of files or build a complex new pipeline.

## Promotion as a Git Commit

As you saw in Lesson 1, you change the state of your cluster by updating the configuration and pushing it to your Git repository. Promotion is no different, you simply update the production overlay and push the commit. This approach ensures every promotion is auditable and reviewable, in Lesson 3 you’ll see why this is important.

## Multiple ArgoCD Applications

ArgoCD supports the multi-environment pattern through multiple *Application* resources, each configured to watch a different directory path in the same Git repository and deploy to a different namespace. In the lesson, we’ll use a separate Application for staging and production. ArgoCD evaluates each Application independently on every poll cycle.

This independence provides *environment isolation*. When you push a commit that adds a resource to the production overlay, only the production Application detects a change and triggers a roll out. Changes to one environment cannot accidentally affect another, because each Application's scope is limited to its own overlay directory and target namespace.

# What to watch for in the lesson

Now that you have explored the core concepts and technologies behind environment promotion, it is time to dive in. As you do, look out for these moments where the concepts become concrete:

* When you explore the `manifests/` directory and see `base/`, `overlays/staging/`, and `overlays/production/`, you are looking at the Kustomize base and overlay pattern in practice: shared configuration in the base, with environment-specific layers on top. 
* When you copy `topic.yaml` into the production overlay, add it to `kustomization.yaml`, and run git push, you are performing a GitOps promotion. The commit that updates the target environment's desired state is the only deployment action required.  
* When ArgoCD syncs the kafka-production Application while kafka-staging remains unchanged, you are seeing environment isolation. Because each Application independently watches its own overlay path, a change to one environment never affects another.

Now you are ready to try the second lesson; check out the lesson 2 readme to run through the tutorial.

