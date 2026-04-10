#!/usr/bin/env bash
# Read repo-info.json and output orchestrator CLI flags.
# Translates the adapter's repo-info.json into the flags the orchestrator expects,
# eliminating LLM-driven flag construction in the batch controller.
#
# Usage: bash resolve-repo-context.sh <ticket-id>
#
# Output (single line to stdout, ready to append to orchestrator args):
#   --repo-path /abs/path/.work/repo --format mkdocs
#   --draft --format adoc
#   (empty string if no repo-info.json found)
#
# Exit codes:
#   0 — flags resolved (may be empty)
#   1 — error reading repo-info.json
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

# --- Argument parsing ---
TICKET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -*) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
    *) TICKET="$1"; shift ;;
  esac
done

if [[ -z "$TICKET" ]]; then
  echo "ERROR: Ticket ID is required." >&2
  echo "Usage: bash resolve-repo-context.sh <ticket-id>" >&2
  exit 1
fi

TICKET_LOWER="$(echo "$TICKET" | tr '[:upper:]' '[:lower:]')"
REPO_INFO="${REPO_ROOT}/artifacts/${TICKET_LOWER}/repo-info.json"

# No repo-info.json — output empty string (orchestrator uses defaults)
if [[ ! -f "$REPO_INFO" ]]; then
  echo ""
  exit 0
fi

# Read repo-info.json and construct flags
python3 -c "
import json, sys, os

with open(sys.argv[1]) as f:
    d = json.load(f)

repo_url = d.get('repo_url') or ''
clone_path = d.get('clone_path', '')
fmt = d.get('format', 'adoc')

flags = []

# Add format flag
if fmt:
    flags.append(f'--format {fmt}')

if not repo_url:
    # No repo URL — draft mode
    flags.append('--draft')
elif clone_path and os.path.isdir(clone_path):
    # Repo cloned successfully — update-in-place mode
    flags.append(f'--repo-path {clone_path}')
else:
    # Repo URL set but clone missing — fall back to draft
    print(f'WARNING: clone_path {clone_path!r} does not exist, falling back to --draft', file=sys.stderr)
    flags.append('--draft')

print(' '.join(flags))
" "$REPO_INFO"
