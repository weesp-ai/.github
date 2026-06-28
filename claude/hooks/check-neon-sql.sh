#!/bin/bash
# Gate Neon run_sql/run_sql_transaction by content: read-only statements
# auto-allow, anything containing a write or DDL keyword routes to the
# standard permission prompt. Regex uses word boundaries so column names
# like "deleted_at" or "updated_at" do not trip.

set -uo pipefail

input=$(cat)

if ! command -v jq >/dev/null 2>&1; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"jq is not installed; cannot inspect SQL content."}}\n'
  exit 0
fi

sqls=$(printf '%s' "$input" | jq -r '[.tool_input | recurse | strings] | join(" ; ")' 2>/dev/null) || sqls=""

WRITE_KEYWORDS='\b(UPDATE|DELETE|TRUNCATE|DROP|INSERT|CREATE|ALTER|GRANT|REVOKE|MERGE|COPY|CALL|DO)\b'

if printf '%s' "$sqls" | grep -iqE "$WRITE_KEYWORDS"; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"SQL contains a write or DDL keyword. Confirming before execution."}}\n'
  exit 0
fi

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"SQL appears to be read-only."}}\n'
exit 0
