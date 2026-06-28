#!/usr/bin/env bash
# Per-session provisioning for Claude Code on the web. Installed at
# /root/.claude/hooks/session-start.sh by cloud-setup.sh and registered as a
# user-scope SessionStart hook, so it runs on every session in both the
# multi-repo (cwd=/home/user) and single-repo (cwd=/home/user/<repo>) layouts.
#
# Renews the bot's gcloud + ADC credential, points kubectl at primary-v2, and
# starts dockerd. No-op outside the cloud environment. Each step degrades
# gracefully (logs + continues) so a missing tool or secret never fails the
# session. Credentials come from env vars the environment injects:
#   GCP_SERVICE_ACCOUNT_KEY_B64, GCP_PROJECT   (gcloud / ADC / gke)
#   GH_TOKEN                                   (gh CLI; injected, used directly)
set -uo pipefail

[[ "${CLAUDE_CODE_REMOTE:-}" == "true" ]] || exit 0
log() { echo "session-start: $*" >&2; }

# --- self-heal CLI tools --------------------------------------------------
# cloud-setup.sh installs these into the environment snapshot, but its
# pre-launch context can occasionally fail an apt install. The apt repos are
# configured in the snapshot regardless, so here — in session context, where
# apt is reliable — we install anything still missing before it's needed.
# Installed per-repo so an unavailable `gh` can't abort the gcloud install.
if command -v apt-get >/dev/null 2>&1; then
  gpkgs=()
  command -v gcloud  >/dev/null 2>&1 || gpkgs+=("google-cloud-cli")
  command -v kubectl >/dev/null 2>&1 || gpkgs+=("kubectl")
  command -v gke-gcloud-auth-plugin >/dev/null 2>&1 || gpkgs+=("google-cloud-cli-gke-gcloud-auth-plugin")
  if (( ${#gpkgs[@]} > 0 )) || ! command -v gh >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >&2 || true
  fi
  if (( ${#gpkgs[@]} > 0 )); then
    log "self-heal: installing ${gpkgs[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${gpkgs[@]}" >&2 \
      || log "WARN: self-heal install failed: ${gpkgs[*]}"
  fi
  if ! command -v gh >/dev/null 2>&1; then
    log "self-heal: installing gh"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gh >&2 || log "WARN: gh self-heal failed"
  fi
fi

# --- gcloud + ADC as claude-code-bot --------------------------------------
if command -v gcloud >/dev/null 2>&1 && [[ -n "${GCP_SERVICE_ACCOUNT_KEY_B64:-}" && -n "${GCP_PROJECT:-}" ]]; then
  key_dir="${HOME}/.config/gcloud-claude"
  mkdir -p "$key_dir"
  chmod 700 "$key_dir"
  key_file="${key_dir}/claude-code-bot.json"
  printf '%s' "${GCP_SERVICE_ACCOUNT_KEY_B64}" | base64 -d > "$key_file" 2>/dev/null && chmod 600 "$key_file"
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$key_file" >/dev/null 2>&1; then
    gcloud auth activate-service-account --key-file="$key_file" --quiet >&2 \
      && gcloud config set project "$GCP_PROJECT" --quiet >&2 \
      && log "gcloud authenticated ($(gcloud config get-value account 2>/dev/null), project ${GCP_PROJECT})"
    # Hand ADC + project to the Claude session. CLAUDE_ENV_FILE is the
    # SessionStart-hook mechanism for exporting env vars to the session.
    if [[ -n "${CLAUDE_ENV_FILE:-}" ]]; then
      {
        echo "GOOGLE_APPLICATION_CREDENTIALS=$key_file"
        echo "CLOUDSDK_CORE_PROJECT=$GCP_PROJECT"
      } >> "$CLAUDE_ENV_FILE"
    fi
  else
    log "WARN: GCP_SERVICE_ACCOUNT_KEY_B64 did not decode to valid JSON; skipping gcloud auth"
    rm -f "$key_file"
  fi
else
  log "gcloud or GCP_* env missing; skipping gcloud auth"
fi

# --- kubectl -> primary-v2 (DNS endpoint) ---------------------------------
# The DNS endpoint (not the IP endpoint) is required so the sandbox's
# TLS-inspecting egress proxy can validate the public Google cert. Needs gcloud
# to be authenticated above.
if command -v gcloud >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1 \
   && [[ -n "$(gcloud config get-value account 2>/dev/null || true)" ]]; then
  gcloud container clusters get-credentials primary-v2 \
    --zone=us-east1-b --dns-endpoint --quiet >&2 \
    && log "kubeconfig -> primary-v2" \
    || log "WARN: gke get-credentials failed"
else
  log "gcloud unauthenticated or kubectl missing; skipping gke"
fi

# --- dockerd --------------------------------------------------------------
# Needed for testcontainers-based Go tests. Idempotent: exit early if already up
# (e.g. on session resume within a warm container).
if command -v dockerd >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    log "dockerd already running"
  else
    nohup dockerd >/var/log/dockerd.log 2>&1 </dev/null &
    disown || true
    for _ in $(seq 1 30); do
      docker info >/dev/null 2>&1 && {
        log "dockerd ready"
        break
      }
      sleep 1
    done
    docker info >/dev/null 2>&1 || log "WARN: dockerd did not become ready (see /var/log/dockerd.log)"
  fi
else
  log "dockerd not installed; skipping"
fi

exit 0
