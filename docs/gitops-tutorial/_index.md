+++
title = 'GitOps Tutorial Series'
+++
This series explores the principles of GitOps and shows you how to put them into practice with Strimzi and ArgoCD. You will learn how to manage your infrastructure the way you manage code: describing the desired state of your Kafka clusters in a Git repository and letting automation keep the running system in step with it. Along the way you will see how this approach makes changes reproducible, auditable and easy to roll back.

The best way to understand GitOps is to try it, so within each lesson you will find a hands-on, interactive tutorial. Rather than only reading about the ideas, you will make real changes and watch them take effect, building practical experience and the confidence to apply the same workflow to your own infrastructure. The lessons are designed to be followed in order, but each is self-contained so you can jump ahead if you wish.

The full series in order:
 * [Introduction to GitOps](../introduction/_index.md) - Covers the problems that GitOps solves, contrasts it with the manual approach most teams start with and introduces the key ideas you will see in practice throughout the lessons.
 * [Preparing For The Tutorials](setup.md) - Walks you through the one-time setup to get your Kubernetes cluster configured for the lessons.
 * [Lesson 1: Your First GitOps Change](lesson-1.md) - Introduces infrastructure as code and automated reconciliation by guiding you through your first GitOps change.
 * [Lesson 2: Promoting Changes Across Environments](lesson-2.md) - Builds on lesson 1 with multi-environment management, showing how the Kustomize base and overlay pattern enables your project to scale.
 * [Lesson 3: Rolling Back a Bad Change](lesson-3.md) - Tackles what happens when things go wrong, covering health monitoring and rollback using nothing more than a git revert.
 * [Wrapping Up](wrapping-up.md) - Summarizes the principles you’ve learned and gives some ideas for your next steps.
