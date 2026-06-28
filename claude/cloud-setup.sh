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

# The sandbox egress proxy is TLS-inspecting; trust its CA so HTTPS works. And
# unlike curl, apt does NOT read $HTTPS_PROXY — so added HTTPS repos (e.g.
# packages.cloud.google.com) are unreachable until we pass the proxy to apt
# explicitly. The proxy port changes between sessions, so read it per call.
if [[ -f /root/.ccr/ca-bundle.crt && -d /usr/local/share/ca-certificates ]]; then
  if ! cmp -s /root/.ccr/ca-bundle.crt /usr/local/share/ca-certificates/bracket-egress.crt 2>/dev/null; then
    cp /root/.ccr/ca-bundle.crt /usr/local/share/ca-certificates/bracket-egress.crt \
      && update-ca-certificates >/dev/null 2>&1 || true
  fi
fi
apt_get() {
  local -a px=()
  [[ -n "${HTTPS_PROXY:-}" ]] && px=(-o "Acquire::http::Proxy=${HTTP_PROXY:-$HTTPS_PROXY}" -o "Acquire::https::Proxy=$HTTPS_PROXY")
  DEBIAN_FRONTEND=noninteractive apt-get "${px[@]}" "$@"
}
apt_install() { apt_get install -y -qq "$@" || log "WARN: failed to install: $*"; }

# --- 1. user-scope hooks (critical; do this first) ------------------------
install -m 0755 "$SCRIPT_DIR/hooks/session-start.sh"  /root/.claude/hooks/session-start.sh
install -m 0755 "$SCRIPT_DIR/hooks/session-end.sh"    /root/.claude/hooks/session-end.sh
install -m 0755 "$SCRIPT_DIR/hooks/check-neon-sql.sh" /root/.claude/hooks/check-neon-sql.sh
if [[ -f /root/.claude/settings.json ]] && ! cmp -s "$SCRIPT_DIR/settings.json" /root/.claude/settings.json; then
  cp /root/.claude/settings.json /root/.claude/settings.json.bak
fi
install -m 0644 "$SCRIPT_DIR/settings.json" /root/.claude/settings.json
log "installed hooks + settings under /root/.claude"

# --- 2. tools -------------------------------------------------------------
if ! command -v apt-get >/dev/null 2>&1; then
  log "apt-get unavailable; skipping tool installs (expecting a Debian/Ubuntu image)"
  exit 0
fi

apt_get update -qq || log "WARN: apt-get update failed"
apt_install ca-certificates gnupg curl

# Default-repo tools. gh ships in Ubuntu's universe repo, so no extra repo is
# needed (and the cli.github.com repo is blocked by the github-domain proxy).
command -v jq      >/dev/null 2>&1 || apt_install jq
command -v unzip   >/dev/null 2>&1 || apt_install unzip
command -v dockerd >/dev/null 2>&1 || apt_install docker.io
command -v gh      >/dev/null 2>&1 || apt_install gh

# Google Cloud SDK repo -> google-cloud-cli, kubectl, gke auth plugin. The repo
# key is fetched with curl (which honours the proxy); the install uses apt_get
# (which now does too). --batch --no-tty: no controlling terminal for gpg.
if ! { command -v gcloud && command -v kubectl && command -v gke-gcloud-auth-plugin; } >/dev/null 2>&1; then
  if [[ ! -f /usr/share/keyrings/cloud.google.gpg ]]; then
    log "configuring Google Cloud apt repo"
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
      | gpg --batch --yes --no-tty --dearmor -o /usr/share/keyrings/cloud.google.gpg \
      && echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
         > /etc/apt/sources.list.d/google-cloud-sdk.list \
      || log "WARN: failed to configure Google Cloud apt repo"
  fi
  apt_get update -qq || log "WARN: apt-get update failed"
  apt_install google-cloud-cli kubectl google-cloud-cli-gke-gcloud-auth-plugin
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
