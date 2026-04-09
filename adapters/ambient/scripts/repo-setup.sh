#!/usr/bin/env bash
# Resolve target docs repo for a JIRA ticket, clone it, create a feature branch.
# Writes repo-info.json for downstream consumers (orchestrator, publish script).
#
# Usage: bash repo-setup.sh <ticket-id> [--mapping <path>] [--dry-run]
#
# Dependencies: python3 (for YAML parsing), git
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

# --- Argument parsing ---
TICKET=""
MAPPING_FILE="${REPO_ROOT}/adapters/ambient/repo-mapping.yaml"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mapping) MAPPING_FILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -*) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
    *) TICKET="$1"; shift ;;
  esac
done

if [[ -z "$TICKET" ]]; then
  echo "ERROR: Ticket ID is required." >&2
  echo "Usage: bash repo-setup.sh <ticket-id> [--mapping <path>] [--dry-run]" >&2
  exit 1
fi

TICKET_LOWER="$(echo "$TICKET" | tr '[:upper:]' '[:lower:]')"
PROJECT_KEY="$(echo "$TICKET" | sed 's/-[0-9]*$//' | tr '[:lower:]' '[:upper:]')"

# --- Output directory ---
OUTPUT_DIR="${REPO_ROOT}/artifacts/${TICKET_LOWER}"
mkdir -p "$OUTPUT_DIR"

# Helper: write a minimal repo-info.json for draft/fallback mode
write_draft_repo_info() {
  python3 -c "
import json, sys
print(json.dumps({
    'ticket': sys.argv[1],
    'jira_project': sys.argv[2],
    'repo_url': None
}, indent=2))
" "$TICKET" "$PROJECT_KEY" > "${OUTPUT_DIR}/repo-info.json"
}

# --- Read repo mapping ---
if [[ ! -f "$MAPPING_FILE" ]]; then
  echo "WARNING: Mapping file not found at ${MAPPING_FILE}" >&2
  write_draft_repo_info
  echo "No repo mapping found. Orchestrator will use --draft mode."
  exit 0
fi

# Parse YAML mapping with python3 — pass file path and project key as arguments
# to avoid shell interpolation issues.
REPO_CONFIG=$(python3 -c "
import yaml, sys, json
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
for repo in data.get('repos', []):
    if repo.get('jira_project', '').upper() == sys.argv[2]:
        print(json.dumps(repo))
        sys.exit(0)
print('null')
" "$MAPPING_FILE" "$PROJECT_KEY" 2>/dev/null) || {
  echo "ERROR: Failed to parse mapping file. Is python3 with PyYAML installed?" >&2
  write_draft_repo_info
  exit 0
}

if [[ "$REPO_CONFIG" == "null" ]]; then
  echo "No mapping found for project ${PROJECT_KEY} in ${MAPPING_FILE}"
  write_draft_repo_info
  exit 0
fi

# Extract fields from config
eval "$(python3 -c "
import json, sys, shlex
d = json.load(sys.stdin)
print(f'REPO_URL={shlex.quote(d[\"repo_url\"])}')
print(f'DEFAULT_BRANCH={shlex.quote(d.get(\"default_branch\", \"main\"))}')
print(f'FORMAT={shlex.quote(d.get(\"format\", \"adoc\"))}')
" <<< "$REPO_CONFIG")"

# Detect platform from URL
if echo "$REPO_URL" | grep -q "github.com"; then
  PLATFORM="github"
else
  PLATFORM="gitlab"
fi

# Derive clone path (absolute)
REPO_NAME=$(basename "$REPO_URL" .git)
CLONE_PATH="$(cd "$REPO_ROOT" && pwd)/.work/${REPO_NAME}"

# --- Dry run ---
if [[ "$DRY_RUN" == true ]]; then
  echo "=== Dry Run ==="
  echo "Ticket:         $TICKET"
  echo "Project:        $PROJECT_KEY"
  echo "Repo URL:       $REPO_URL"
  echo "Platform:       $PLATFORM"
  echo "Default branch: $DEFAULT_BRANCH"
  echo "Format:         $FORMAT"
  echo "Clone path:     $CLONE_PATH"
  echo "Branch:         $TICKET_LOWER"
  exit 0
fi

# --- Clone or update ---
clone_repo() {
  local url="$1"
  local quiet="${2:-false}"
  if [[ "$quiet" == "true" ]]; then
    echo "Cloning (with credentials) ..."
    git clone --branch "$DEFAULT_BRANCH" --single-branch "$url" "$CLONE_PATH" 2>/dev/null
  else
    echo "Cloning ${url} ..."
    git clone --branch "$DEFAULT_BRANCH" --single-branch "$url" "$CLONE_PATH" 2>&1
  fi
}

if [[ -d "$CLONE_PATH/.git" ]]; then
  echo "Existing clone found at ${CLONE_PATH}"

  # Check for uncommitted changes
  if ! git -C "$CLONE_PATH" diff --quiet HEAD 2>/dev/null || \
     [[ -n "$(git -C "$CLONE_PATH" ls-files --others --exclude-standard 2>/dev/null)" ]]; then
    echo "WARNING: Uncommitted changes detected. Discarding (likely from a failed previous run)." >&2
    git -C "$CLONE_PATH" checkout -- . 2>/dev/null || true
    git -C "$CLONE_PATH" clean -fd 2>/dev/null || true
  fi

  # Reset to latest default branch
  git -C "$CLONE_PATH" fetch origin 2>&1 || echo "WARNING: fetch failed, continuing with local state" >&2
  # Fetch the feature branch ref if it exists on remote (required for --force-with-lease on re-runs)
  git -C "$CLONE_PATH" fetch origin "$TICKET_LOWER" 2>/dev/null || true
  git -C "$CLONE_PATH" checkout "$DEFAULT_BRANCH" 2>&1 || true
  git -C "$CLONE_PATH" reset --hard "origin/${DEFAULT_BRANCH}" 2>&1 || true
else
  mkdir -p "$(dirname "$CLONE_PATH")"

  # Try plain clone first
  if ! clone_repo "$REPO_URL"; then
    echo "Plain clone failed. Trying with token..." >&2

    # Source credentials from ~/.env
    source ~/.env 2>/dev/null || true

    # Try with token in URL (use bash substitution to avoid
    # sed special-char issues)
    TOKEN_URL=""
    if [[ "$PLATFORM" == "gitlab" && -n "${GITLAB_TOKEN:-}" ]]; then
      TOKEN_URL="${REPO_URL/https:\/\//https://oauth2:${GITLAB_TOKEN}@}"
    elif [[ "$PLATFORM" == "github" && -n "${GITHUB_TOKEN:-}" ]]; then
      TOKEN_URL="${REPO_URL/https:\/\//https://${GITHUB_TOKEN}@}"
    fi

    if [[ -n "$TOKEN_URL" ]]; then
      rm -rf "$CLONE_PATH"
      # Clone quietly to avoid leaking token in error output
      if ! clone_repo "$TOKEN_URL" true; then
        echo "ERROR: Clone failed even with token." >&2
        write_draft_repo_info
        echo "Clone failed. Orchestrator will use --draft mode."
        exit 0
      fi
    else
      echo "ERROR: Clone failed and no token available for retry." >&2
      write_draft_repo_info
      echo "Clone failed. Orchestrator will use --draft mode."
      exit 0
    fi
  fi
fi

# --- Create feature branch ---
# Delete existing branch if it exists (from a previous failed run)
git -C "$CLONE_PATH" branch -D "$TICKET_LOWER" 2>/dev/null || true
git -C "$CLONE_PATH" checkout -b "$TICKET_LOWER" 2>&1

# Set upstream tracking if remote branch exists (required for --force-with-lease)
if git -C "$CLONE_PATH" rev-parse --verify "origin/${TICKET_LOWER}" >/dev/null 2>&1; then
  git -C "$CLONE_PATH" branch --set-upstream-to="origin/${TICKET_LOWER}" "$TICKET_LOWER" 2>/dev/null || true
fi

echo "Created branch '${TICKET_LOWER}' from '${DEFAULT_BRANCH}'"

# --- Write repo-info.json ---
python3 -c "
import json, sys
print(json.dumps({
    'ticket': sys.argv[1],
    'jira_project': sys.argv[2],
    'repo_url': sys.argv[3],
    'platform': sys.argv[4],
    'default_branch': sys.argv[5],
    'format': sys.argv[6],
    'clone_path': sys.argv[7],
    'branch': sys.argv[8]
}, indent=2))
" "$TICKET" "$PROJECT_KEY" "$REPO_URL" "$PLATFORM" "$DEFAULT_BRANCH" "$FORMAT" "$CLONE_PATH" "$TICKET_LOWER" > "${OUTPUT_DIR}/repo-info.json"

echo "Wrote ${OUTPUT_DIR}/repo-info.json"
echo "Ready: ${CLONE_PATH} on branch ${TICKET_LOWER}"
