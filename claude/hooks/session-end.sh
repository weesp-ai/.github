#!/usr/bin/env bash
# Best-effort dockerd shutdown when a Claude Code on the web session ends.
# Registered as a user-scope SessionEnd hook by cloud-setup.sh. Cosmetic: the
# cloud container is reclaimed on session end anyway. No-op outside the cloud.
set -uo pipefail

[[ "${CLAUDE_CODE_REMOTE:-}" == "true" ]] || exit 0

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  pkill -TERM dockerd 2>/dev/null || true
  echo "session-end: signalled dockerd to stop" >&2
fi

exit 0
