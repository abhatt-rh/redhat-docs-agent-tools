#!/usr/bin/env bash
# batch-progress.sh — Manage the batch pipeline progress file.
# Called by the batch-controller skill to track pipeline state.
# The batch-completion stop hook reads this file to prevent early stopping.
#
# Usage:
#   batch-progress.sh init <ticket> [<ticket>...]   Create progress file with claimed tickets
#   batch-progress.sh step <step>                   Update current_step (e.g., "2a", "2b")
#   batch-progress.sh ticket-done                   Move current ticket to completed, advance
#   batch-progress.sh ticket-failed                 Move current ticket to failed, advance
#   batch-progress.sh finish                        Set status to completed (allows session end)
#   batch-progress.sh abort                         Set status to failed (allows session end)
#
# Dependencies: python3
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PROGRESS_FILE="${REPO_ROOT}/artifacts/batch-progress.json"

cmd="${1:-}"
shift || true

case "$cmd" in
  init)
    if [[ $# -eq 0 ]]; then
      echo "ERROR: init requires at least one ticket key." >&2
      exit 1
    fi
    # Build JSON array of ticket keys
    TICKETS_JSON=$(python3 -c "
import json, sys
print(json.dumps(sys.argv[1:]))
" "$@")
    FIRST_TICKET="$1"

    python3 -c "
import json, sys
from datetime import datetime, timezone
print(json.dumps({
    'status': 'in_progress',
    'created_at': datetime.now(timezone.utc).isoformat(),
    'updated_at': datetime.now(timezone.utc).isoformat(),
    'tickets': json.loads(sys.argv[1]),
    'current_ticket': sys.argv[2],
    'current_step': '2a',
    'completed_tickets': [],
    'failed_tickets': [],
    'batch_summary_written': False
}, indent=2))
" "$TICKETS_JSON" "$FIRST_TICKET" > "$PROGRESS_FILE"
    echo "Batch progress: initialized with $# ticket(s)"
    ;;

  step)
    STEP="${1:-}"
    if [[ -z "$STEP" ]]; then
      echo "ERROR: step requires a step name (e.g., 2a, 2b)." >&2
      exit 1
    fi
    if [[ ! -f "$PROGRESS_FILE" ]]; then
      echo "WARNING: No progress file found. Skipping step update." >&2
      exit 0
    fi
    python3 -c "
import json, sys
from datetime import datetime, timezone
with open(sys.argv[1]) as f:
    data = json.load(f)
data['current_step'] = sys.argv[2]
data['updated_at'] = datetime.now(timezone.utc).isoformat()
with open(sys.argv[1], 'w') as f:
    json.dump(data, f, indent=2)
" "$PROGRESS_FILE" "$STEP"
    echo "Batch progress: step → ${STEP}"
    ;;

  ticket-done|ticket-failed)
    if [[ ! -f "$PROGRESS_FILE" ]]; then
      echo "WARNING: No progress file found. Skipping ticket update." >&2
      exit 0
    fi
    if [[ "$cmd" == "ticket-done" ]]; then
      TARGET_LIST="completed_tickets"
    else
      TARGET_LIST="failed_tickets"
    fi
    python3 -c "
import json, sys
from datetime import datetime, timezone
with open(sys.argv[1]) as f:
    data = json.load(f)
target = sys.argv[2]
current = data.get('current_ticket', '')
if current:
    data[target].append(current)
# Advance to next ticket
tickets = data.get('tickets', [])
done = set(data.get('completed_tickets', []) + data.get('failed_tickets', []))
remaining = [t for t in tickets if t not in done]
if remaining:
    data['current_ticket'] = remaining[0]
    data['current_step'] = '2a'
else:
    data['current_ticket'] = None
    data['current_step'] = 'done'
data['updated_at'] = datetime.now(timezone.utc).isoformat()
with open(sys.argv[1], 'w') as f:
    json.dump(data, f, indent=2)
print(f'Batch progress: {current} → {target} ({len(remaining)} remaining)')
" "$PROGRESS_FILE" "$TARGET_LIST"
    ;;

  finish)
    if [[ ! -f "$PROGRESS_FILE" ]]; then
      echo "WARNING: No progress file found. Nothing to finish." >&2
      exit 0
    fi
    python3 -c "
import json, sys
from datetime import datetime, timezone
with open(sys.argv[1]) as f:
    data = json.load(f)
data['status'] = 'completed'
data['batch_summary_written'] = True
data['updated_at'] = datetime.now(timezone.utc).isoformat()
with open(sys.argv[1], 'w') as f:
    json.dump(data, f, indent=2)
" "$PROGRESS_FILE"
    # Clean up counter file if present
    rm -f "${REPO_ROOT}/artifacts/.batch_stop_count"
    echo "Batch progress: completed. Stop hook released."
    ;;

  abort)
    if [[ ! -f "$PROGRESS_FILE" ]]; then
      echo "WARNING: No progress file found. Nothing to abort." >&2
      exit 0
    fi
    python3 -c "
import json, sys
from datetime import datetime, timezone
with open(sys.argv[1]) as f:
    data = json.load(f)
data['status'] = 'failed'
data['updated_at'] = datetime.now(timezone.utc).isoformat()
with open(sys.argv[1], 'w') as f:
    json.dump(data, f, indent=2)
" "$PROGRESS_FILE"
    rm -f "${REPO_ROOT}/artifacts/.batch_stop_count"
    echo "Batch progress: aborted. Stop hook released."
    ;;

  *)
    echo "Usage: batch-progress.sh {init|step|ticket-done|ticket-failed|finish|abort}" >&2
    exit 1
    ;;
esac
