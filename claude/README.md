# Claude Code on the web — cloud environment provisioning

Shared, **public**, repo-agnostic setup for Bracket's Claude Code on the web
sessions. One environment-level setup script installs the CLI tools and the
per-session hooks every session needs, so the experience is consistent across
**multi-repo** and **single-repo** web sessions — without each repo
(`mono` / `cluster` / `infrastructure`) carrying its own `.claude` hooks.

Nothing here is secret. The hooks read credentials from environment variables
the environment injects at runtime (see below), so this script is safe to keep
public.

## Why this exists

In a Claude Code on the web session, per-repo `.claude/settings.json` hooks only
run when the working directory *is* that repo (single-repo sessions). In a
multi-repo session the repos are mounted under a parent working directory, so
their hooks never run. Installing the hooks at **user scope** (`/root/.claude`)
makes them fire in both layouts. This was validated end to end before adoption.

## Use it

Paste this into each cloud environment's **Setup script** field. It fetches a
pinned tag as an HTTPS tarball — a `git clone` of this repo is blocked by the
session's scope proxy, so use the tarball, not `git clone`:

```bash
mkdir -p /tmp/bracket-claude \
  && curl -fsSL https://github.com/weesp-ai/.github/archive/refs/tags/claude-setup-v5.tar.gz \
     | tar -xz -C /tmp/bracket-claude --strip-components=1 \
  && bash /tmp/bracket-claude/claude/cloud-setup.sh
```

Bump the tag when you cut a new release (see [Updating](#updating)).

## Required environment variables (set per environment)

| Variable | Secret? | Used by | Purpose |
|---|---|---|---|
| `GCP_SERVICE_ACCOUNT_KEY_B64` | yes | `session-start.sh` | base64 JSON key for `claude-code-bot`; gcloud + ADC + gke |
| `GCP_PROJECT` | no | `session-start.sh` | GCP project id (e.g. `weesp-ai`) |
| `GH_TOKEN` | yes | `gh` CLI | bot GitHub token (injected; used directly) |
| `NEON_API_KEY` | yes | neon MCP connector | only if the connector reads its token from the session env |
| `CLAUDE_CODE_REMOTE` | no | hooks | `true` in cloud sessions; the hooks no-op without it |

## What it does

`cloud-setup.sh` runs **once** per environment (before Claude launches; the
filesystem is then snapshotted and reused):

1. Installs the user-scope hooks into `/root/.claude/`.
2. Installs CLI tools if missing: `gcloud`, `kubectl`,
   `gke-gcloud-auth-plugin`, `gh`, `docker.io`, `terraform`, `jq`. Installing
   `gcloud`/`kubectl`/`gke-gcloud-auth-plugin` needs the environment's network
   policy to allow `packages.cloud.google.com`; if that host is blocked they are
   skipped (logged) and the rest still install.
3. Writes `/etc/docker/daemon.json` (Docker Hub pull-through mirror).

The installed hooks run **every session**:

- `session-start.sh` — installs any still-missing tool (self-heal), authenticates
  `gcloud` + ADC as `claude-code-bot`, points `kubectl` at `primary-v2` (DNS
  endpoint), starts `dockerd`.
- `session-end.sh` — stops `dockerd` (best-effort).
- `check-neon-sql.sh` — `PreToolUse` guard that routes Neon write/DDL SQL to a
  confirmation prompt; read-only SQL is auto-allowed.

## Debugging

The setup script runs pre-launch and its console output isn't retrievable later,
so both scripts log to files. From any session in the environment:

```bash
cat /root/.claude/cloud-setup.log     # one-time setup (tool installs)
cat /root/.claude/session-start.log   # per-session auth / gke / dockerd
```

## Local sessions

The hooks live only under `/root/.claude/`, which this script writes only in the
cloud environment. Local sessions never run it, so they keep using the
developer's own tools, auth, and Docker — unchanged.

## Updating

Edit the files here and merge. Then cut a new tag (e.g. `claude-setup-v6`) and
bump it in each environment's setup-script URL. Existing environments keep their
snapshot until recreated.
