# Bracket

Bracket (formerly Weesp) is a task management system that puts **Context** at the center — correlating task-related inputs from multiple channels alongside autonomous AI agents that can be assigned to tasks and accomplish them. Users interact with the system through a web console, Email, and Slack today, with WhatsApp, Telegram, SMS, and Phone on the roadmap. Bracket is designed to meet users where they already are, instead of requiring them to learn a new system, dashboard, or interface.

## What it does

- **Multi-channel task management** — create and manage tasks via Email, Slack, and the web console, with more communication platforms on the roadmap.
- **Autonomous AI agents** — agents that can be assigned to tasks and accomplish them autonomously.
- **Intelligent assistant** — a proactive aide that drafts and sends email, performs research, and executes sub-tasks to move work forward.
- **Deep integrations** — a roadmap focused on connecting with the ecosystem of work tools (Google Workspace, HubSpot, Salesforce, Linear, Jira) to provide context and execute actions across platforms.

## Repositories

- **[`mono`](https://github.com/weesp-ai/mono)** — the product monorepo: the Go API server, the React console, the Playwright end-to-end suite, the Helm chart, and per-environment Terraform.
- **[`cluster`](https://github.com/weesp-ai/cluster)** — Argo CD GitOps for the `primary-v2` GKE cluster.
- **[`infrastructure`](https://github.com/weesp-ai/infrastructure)** — global Google Cloud infrastructure-as-code: project, IAM, DNS, GKE clusters, networking, and Secret Manager.
