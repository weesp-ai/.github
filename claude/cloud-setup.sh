#!/usr/bin/env bash
# Bracket — Claude Code on the web: one-time environment provisioning.
#
# Each cloud environment's "Setup script" fetches and runs this once, before
# Claude Code launches; Anthropic then snapshots the filesystem and reuses it.
# So this script does only durable, idempotent, SECRET-FREE work:
#
#   1. install the user-scope hooks at /root/.claude (they run every session, in
#      both the multi-repo cwd=/home/user and single-repo cwd=/home/user/<repo>
#      layouts — validated)
#   2. install the CLI tools sessions need, if missing
#
# Per-session work (renewing the bot's gcloud/gke credentials and starting
# dockerd) lives in the installed hooks, NOT here: a daemon is a process (it
# does not survive the snapshot) and credentials expire, so both must run each
# session. The hooks read their secrets from environment variables the
# environment injects at runtime (GCP_SERVICE_ACCOUNT_KEY_B64, GCP_PROJECT,
# GH_TOKEN, NEON_API_KEY); nothing secret is committed, so this repo can be
# public. See claude/README.md.
#
# NOTE: installing google-cloud-cli / kubectl / gke-gcloud-auth-plugin requires
# the environment's network policy to allow packages.cloud.google.com. If that
# host is blocked, those installs fail (logged) and the rest still proceed.
set -uo pipefail

mkdir -p /root/.claude/hooks
LOG_FILE="/root/.claude/cloud-setup.log"
# Capture all output to a file the session can print back — this runs pre-launch
# and its console output isn't retrievable from a session otherwise.
exec > >(tee -a "$LOG_FILE") 2>&1
echo "===== cloud-setup run $(date -u +%FT%TZ 2>/dev/null || true) ====="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_VERSION="1.15.5"
log() { echo "cloud-setup: $*"; }

# TEMPORARY (v7) debug: characterise the injected CLOUDSDK_AUTH_ACCESS_TOKEN so
# we can see what it actually is. Prints length, format prefix, and Google's
# tokeninfo (never the full token). Remove once understood.
dbg_token() {
  local t="${CLOUDSDK_AUTH_ACCESS_TOKEN:-}"
  if [[ -z "$t" ]]; then log "DEBUG CLOUDSDK_AUTH_ACCESS_TOKEN: unset/empty"; return; fi
  log "DEBUG CLOUDSDK_AUTH_ACCESS_TOKEN: len=${#t} first16='${t:0:16}' last6='${t: -6}'"
  log "DEBUG tokeninfo: $(curl -s https://oauth2.googleapis.com/tokeninfo --data-urlencode "access_token=$t" 2>/dev/null)"
}
dbg_token
apt_install() { DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" || log "WARN: failed to install: $*"; }

# --- 1. user-scope hooks (critical; do this first) ------------------------
install -m 0755 "$SCRIPT_DIR/hooks/session-start.sh"  /root/.claude/hooks/session-start.sh
install -m 0755 "$SCRIPT_DIR/hooks/session-end.sh"    /root/.claude/hooks/session-end.sh
install -m 0755 "$SCRIPT_DIR/hooks/check-neon-sql.sh" /root/.claude/hooks/check-neon-sql.sh
if [[ -f /root/.claude/settings.json ]] && ! cmp -s "$SCRIPT_DIR/settings.json" /root/.claude/settings.json; then
  cp /root/.claude/settings.json /root/.claude/settings.json.bak
fi
install -m 0644 "$SCRIPT_DIR/settings.json" /root/.claude/settings.json
log "installed hooks + settings under /root/.claude"

# --- 2. tools (plain apt; default Ubuntu repos are reachable directly — do NOT
#     force them through the egress proxy, which rejects them) ----------------
if ! command -v apt-get >/dev/null 2>&1; then
  log "apt-get unavailable; skipping tool installs (expecting a Debian/Ubuntu image)"
  exit 0
fi

DEBIAN_FRONTEND=noninteractive apt-get update -qq || log "WARN: apt-get update failed (continuing)"
apt_install ca-certificates gnupg curl

# Default-repo tools. gh ships in Ubuntu's universe repo, so no extra repo is
# needed (and the cli.github.com repo is blocked by the github-domain proxy).
command -v jq      >/dev/null 2>&1 || apt_install jq
command -v unzip   >/dev/null 2>&1 || apt_install unzip
command -v dockerd >/dev/null 2>&1 || apt_install docker.io
command -v gh      >/dev/null 2>&1 || apt_install gh

# Google Cloud SDK repo -> google-cloud-cli, kubectl, gke auth plugin.
# Requires the network policy to allow packages.cloud.google.com; if it's
# blocked the key fetch 403s and these stay uninstalled (logged, non-fatal).
if ! { command -v gcloud && command -v kubectl && command -v gke-gcloud-auth-plugin; } >/dev/null 2>&1; then
  if [[ ! -f /usr/share/keyrings/cloud.google.gpg ]]; then
    log "configuring Google Cloud apt repo"
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
      | gpg --batch --yes --no-tty --dearmor -o /usr/share/keyrings/cloud.google.gpg \
      && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
         > /etc/apt/sources.list.d/google-cloud-sdk.list \
      || log "WARN: failed to configure Google Cloud apt repo (is packages.cloud.google.com allowed by the network policy?)"
  fi
  if [[ -f /usr/share/keyrings/cloud.google.gpg ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || log "WARN: apt-get update failed (continuing)"
    apt_install google-cloud-cli kubectl google-cloud-cli-gke-gcloud-auth-plugin
  fi
fi

# Terraform: pinned release zip (curl, not apt, for a reproducible version).
if ! { command -v terraform >/dev/null 2>&1 \
       && [[ "$(terraform version 2>/dev/null | head -n1)" == "Terraform v${TERRAFORM_VERSION}" ]]; }; then
  case "$(uname -m)" in
    x86_64 | amd64) tf_arch="amd64" ;;
    aarch64 | arm64) tf_arch="arm64" ;;
    *) tf_arch="" ; log "WARN: unsupported arch $(uname -m) for terraform" ;;
  esac
  if [[ -n "$tf_arch" ]]; then
    log "installing terraform ${TERRAFORM_VERSION} (linux_${tf_arch})"
    tf_zip="$(mktemp)"
    if curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${tf_arch}.zip" -o "$tf_zip"; then
      unzip -o -q "$tf_zip" -d /usr/local/bin || log "WARN: terraform unzip failed"
    else
      log "WARN: terraform download failed"
    fi
    rm -f "$tf_zip"
  fi
fi

# Docker daemon config: route Hub pulls through the gcr.io pull-through mirror so
# the shared cloud egress IP does not trip Docker Hub's anonymous pull-rate
# limit. (dockerd is started per session by session-start.sh, not here.)
mkdir -p /etc/docker
if [[ ! -f /etc/docker/daemon.json ]]; then
  cat > /etc/docker/daemon.json <<'JSON'
{
  "registry-mirrors": ["https://mirror.gcr.io"]
}
JSON
fi

log "done — final tool check:"
for b in gcloud kubectl gke-gcloud-auth-plugin gh terraform docker jq; do
  command -v "$b" >/dev/null 2>&1 && echo "  ok   $b" || echo "  MISS $b"
done
