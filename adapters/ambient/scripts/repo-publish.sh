#!/usr/bin/env bash
# Commit manifest-listed files and push the feature branch.
# Reads repo-info.json and the writing manifest (_index.md) to determine
# which files to commit. Only commits files listed in the manifest.
#
# Usage: bash repo-publish.sh <ticket-id> [--dry-run]
#
# Dependencies: git, python3
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

# --- Argument parsing ---
TICKET=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    -*) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
    *) TICKET="$1"; shift ;;
  esac
done

if [[ -z "$TICKET" ]]; then
  echo "ERROR: Ticket ID is required." >&2
  echo "Usage: bash repo-publish.sh <ticket-id> [--dry-run]" >&2
  exit 1
fi

TICKET_LOWER="$(echo "$TICKET" | tr '[:upper:]' '[:lower:]')"
OUTPUT_DIR="${REPO_ROOT}/artifacts/${TICKET_LOWER}"

# --- Read repo-info.json ---
REPO_INFO="${OUTPUT_DIR}/repo-info.json"

if [[ ! -f "$REPO_INFO" ]]; then
  echo "No repo-info.json found at ${REPO_INFO}. Nothing to publish."
  exit 0
fi

eval "$(python3 -c "
import json, sys, shlex
d = json.load(open(sys.argv[1]))
print(f'REPO_URL={shlex.quote(d.get(\"repo_url\") or \"\")}')
print(f'CLONE_PATH={shlex.quote(d[\"clone_path\"])}')
print(f'BRANCH={shlex.quote(d[\"branch\"])}')
print(f'PLATFORM={shlex.quote(d[\"platform\"])}')
print(f'DEFAULT_BRANCH={shlex.quote(d.get(\"default_branch\", \"main\"))}')
" "$REPO_INFO")"

if [[ -z "$REPO_URL" ]]; then
  echo "repo_url is null in repo-info.json. Nothing to publish (draft mode)."
  exit 0
fi

# --- Validate clone path is under .work/ ---
if [[ "$CLONE_PATH" != "${REPO_ROOT}/.work/"* ]]; then
  echo "ERROR: clone_path '${CLONE_PATH}' is not under ${REPO_ROOT}/.work/. Refusing to proceed." >&2
  exit 1
fi

if [[ ! -d "$CLONE_PATH/.git" ]]; then
  echo "ERROR: Clone path does not exist: ${CLONE_PATH}" >&2
  exit 1
fi

# --- Branch safety check ---
CURRENT_BRANCH=$(git -C "$CLONE_PATH" rev-parse --abbrev-ref HEAD)
if [[ "$CURRENT_BRANCH" == "main" || "$CURRENT_BRANCH" == "master" ]]; then
  echo "ERROR: Refusing to push to '${CURRENT_BRANCH}'. All pushes must go to feature branches." >&2
  exit 1
fi

# --- Read manifest ---
MANIFEST="${OUTPUT_DIR}/writing/_index.md"

if [[ ! -f "$MANIFEST" ]]; then
  echo "No manifest found at ${MANIFEST}. Orchestrator may not have completed the writing step."
  python3 -c "
import json, sys
print(json.dumps({
    'branch': sys.argv[1],
    'commit_sha': None,
    'files_committed': [],
    'platform': sys.argv[2],
    'repo_url': sys.argv[3],
    'pushed': False,
    'skip_reason': 'no manifest'
}, indent=2))
" "$BRANCH" "$PLATFORM" "$REPO_URL" > "${OUTPUT_DIR}/publish-info.json"
  exit 0
fi

# Extract file paths from the manifest table that are under the clone path.
# Manifest table rows look like: | /absolute/path/to/file.md | TYPE | Description |
# Uses Python for portability (grep -P is not available on macOS).
readarray -t MANIFEST_FILES < <(python3 -c "
import sys, re
clone = sys.argv[1]
with open(sys.argv[2]) as f:
    for line in f:
        for m in re.findall(r'\|\s*(' + re.escape(clone) + r'\S+)', line):
            print(m)
" "$CLONE_PATH" "$MANIFEST" 2>/dev/null)

if [[ ${#MANIFEST_FILES[@]} -eq 0 ]]; then
  echo "No files found in manifest under ${CLONE_PATH}."
  python3 -c "
import json, sys
print(json.dumps({
    'branch': sys.argv[1],
    'commit_sha': None,
    'files_committed': [],
    'platform': sys.argv[2],
    'repo_url': sys.argv[3],
    'pushed': False,
    'skip_reason': 'no files in manifest'
}, indent=2))
" "$BRANCH" "$PLATFORM" "$REPO_URL" > "${OUTPUT_DIR}/publish-info.json"
  exit 0
fi

# --- Dry run ---
if [[ "$DRY_RUN" == true ]]; then
  echo "=== Dry Run ==="
  echo "Ticket:     $TICKET"
  echo "Clone path: $CLONE_PATH"
  echo "Branch:     $BRANCH"
  echo "Platform:   $PLATFORM"
  echo ""
  echo "Files to commit (${#MANIFEST_FILES[@]}):"
  for f in "${MANIFEST_FILES[@]}"; do
    # Show path relative to clone
    echo "  - ${f#${CLONE_PATH}/}"
  done
  exit 0
fi

# --- Check for changes ---
cd "$CLONE_PATH"

if git diff --quiet HEAD 2>/dev/null && \
   [[ -z "$(git ls-files --others --exclude-standard 2>/dev/null)" ]]; then
  echo "No changes detected in ${CLONE_PATH}. Nothing to commit."
  python3 -c "
import json, sys
print(json.dumps({
    'branch': sys.argv[1],
    'commit_sha': None,
    'files_committed': [],
    'platform': sys.argv[2],
    'repo_url': sys.argv[3],
    'pushed': False,
    'skip_reason': 'no changes'
}, indent=2))
" "$BRANCH" "$PLATFORM" "$REPO_URL" > "${OUTPUT_DIR}/publish-info.json"
  exit 0
fi

# --- Stage manifest files ---
STAGED_FILES=()
for filepath in "${MANIFEST_FILES[@]}"; do
  if [[ -f "$filepath" ]]; then
    git add "$filepath" || { echo "WARNING: failed to stage ${filepath}" >&2; continue; }
    STAGED_FILES+=("${filepath#${CLONE_PATH}/}")
  else
    echo "WARNING: Manifest lists ${filepath} but file does not exist. Skipping." >&2
  fi
done

if [[ ${#STAGED_FILES[@]} -eq 0 ]]; then
  echo "No manifest files exist on disk. Nothing to commit."
  exit 0
fi

# --- Build commit message ---
COMMIT_MSG="docs(${TICKET_LOWER}): add generated documentation

Files:
$(printf '  - %s\n' "${STAGED_FILES[@]}")

Generated by docs-pipeline for ${TICKET}"

# --- Commit ---
git commit -m "$COMMIT_MSG" 2>&1

COMMIT_SHA=$(git rev-parse HEAD)
echo "Committed: ${COMMIT_SHA}"

# --- Push ---
# Use --force-with-lease: these are pipeline-generated branches, not collaborative
# work. Re-runs create a fresh branch from main, diverging from the remote.
# Force push is safe here — the branch safety check above already prevents
# pushing to main/master.
if git push --force-with-lease -u origin "$BRANCH" 2>&1; then
  PUSH_STATUS="true"
  echo "Pushed branch '${BRANCH}' to origin"
else
  PUSH_STATUS="false"
  echo "ERROR: Push failed. Branch committed locally but not pushed." >&2
fi

# --- Write publish-info.json ---
python3 -c "
import json, sys
files = sys.argv[6:]
print(json.dumps({
    'branch': sys.argv[1],
    'commit_sha': sys.argv[2],
    'files_committed': files,
    'platform': sys.argv[3],
    'repo_url': sys.argv[4],
    'pushed': sys.argv[5] == 'true'
}, indent=2))
" "$BRANCH" "$COMMIT_SHA" "$PLATFORM" "$REPO_URL" "$PUSH_STATUS" "${STAGED_FILES[@]}" > "${OUTPUT_DIR}/publish-info.json"

echo "Wrote ${OUTPUT_DIR}/publish-info.json"
