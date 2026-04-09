#!/bin/bash
# batch-completion-check.sh
#
# Stop hook: blocks Claude from stopping while the batch pipeline is
# still running. Reads artifacts/batch-progress.json.
#
# Exit codes:
#   0 = allow stop
#   2 = block stop (reason sent to stderr)
#
# Requires: jq

set -u

INPUT=$(cat)

if ! cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null; then
  echo "Cannot access project directory; cannot verify batch status." >&2
  exit 2
fi

PROGRESS_FILE="artifacts/batch-progress.json"

# If no progress file exists, the batch hasn't started (or is already done).
if [ ! -f "$PROGRESS_FILE" ]; then
  exit 0
fi

STATUS=$(jq -r '.status' "$PROGRESS_FILE" 2>/dev/null)

# Only block if status is in_progress
if [ "$STATUS" != "in_progress" ]; then
  exit 0
fi

# Anti-loop guard: counter prevents infinite blocking.
# Max 5 attempts, then allow stop to avoid unusable session.
COUNTER_FILE="artifacts/.batch_stop_count"
if [ -f "$COUNTER_FILE" ]; then
  COUNT=$(cat "$COUNTER_FILE")
else
  COUNT=0
fi
if [ "$COUNT" -ge 5 ]; then
  rm -f "$COUNTER_FILE"
  exit 0
fi

# Extract state for the message
CURRENT_TICKET=$(jq -r '.current_ticket // "unknown"' "$PROGRESS_FILE")
CURRENT_STEP=$(jq -r '.current_step // "unknown"' "$PROGRESS_FILE")
TOTAL=$(jq -r '.tickets | length' "$PROGRESS_FILE")
DONE=$(jq -r '(.completed_tickets | length) + (.failed_tickets | length)' "$PROGRESS_FILE")

echo "$((COUNT + 1))" > "$COUNTER_FILE"
echo "Batch pipeline in progress (${DONE}/${TOTAL} tickets done). Current ticket: ${CURRENT_TICKET}, step: ${CURRENT_STEP}. Continue the batch-controller pipeline." >&2
exit 2
