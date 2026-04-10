#!/usr/bin/env bash
# ACP session setup. Skills, agents, and reference files are pre-committed
# as symlinks in .claude/ — no runtime copying needed.
# This script handles credential mapping and output directory setup.
set -euo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"

# Verify symlinks resolve correctly
if [ ! -f "${REPO_ROOT}/.claude/skills/docs-orchestrator/SKILL.md" ]; then
  echo "ERROR: Skill symlinks not resolving. Ensure the full repository is cloned." >&2
  echo "Expected: .claude/skills/docs-orchestrator/SKILL.md" >&2
  exit 1
fi

# Map ACP-injected credentials to script-expected names.
# Unquoted heredoc expands env vars at write time → plain KEY=VALUE lines.
cat > ~/.env <<ENVEOF
JIRA_API_TOKEN=${JIRA_API_TOKEN:-}
JIRA_EMAIL=${JIRA_EMAIL:-}
JIRA_URL=${JIRA_URL:-https://redhat.atlassian.net}
GITHUB_TOKEN=${GITHUB_TOKEN:-}
GITLAB_TOKEN=${GITLAB_TOKEN:-}
ENVEOF

echo "Credentials mapped to ~/.env:"
[[ -n "${JIRA_API_TOKEN:-}" ]] && echo "  JIRA: available" || echo "  JIRA: not available"
[[ -n "${GITHUB_TOKEN:-}" ]]   && echo "  GitHub: available" || echo "  GitHub: not available"
[[ -n "${GITLAB_TOKEN:-}" ]]   && echo "  GitLab: available" || echo "  GitLab: not available"

# Install Python dependencies required by pipeline scripts
echo "Installing Python dependencies..."
python3 -m pip install --quiet jira ratelimit PyYAML 2>&1 | tail -1 || {
  echo "WARNING: pip install failed. Scripts requiring these packages will fail." >&2
}

# Route artifacts to ACP platform directory when available.
# /workspace/artifacts/ is the ACP-standard output directory surfaced in the UI.
# A symlink lets all scripts (which use ${REPO_ROOT}/artifacts/) write there
# transparently, with no changes to skill files or downstream scripts.
if [[ -d /workspace/artifacts && "$(readlink -f /workspace/artifacts)" != "$(readlink -f "${REPO_ROOT}/artifacts" 2>/dev/null)" ]]; then
  rm -rf "${REPO_ROOT}/artifacts" 2>/dev/null || true
  ln -sfn /workspace/artifacts "${REPO_ROOT}/artifacts"
  echo "Artifacts: symlinked to /workspace/artifacts/"
else
  mkdir -p "${REPO_ROOT}/artifacts"
  echo "Artifacts: ${REPO_ROOT}/artifacts/"
fi

# Count resolved skills/agents/references for verification
skill_count=$(find "${REPO_ROOT}/.claude/skills" -maxdepth 1 -mindepth 1 \( -type d -o -type l \) | wc -l)
agent_count=$(find "${REPO_ROOT}/.claude/agents" -maxdepth 1 -name '*.md' \( -type f -o -type l \) | wc -l)
ref_count=$(find "${REPO_ROOT}/.claude/reference" -maxdepth 1 -name '*.md' \( -type f -o -type l \) | wc -l)
echo "Available: ${skill_count} skills, ${agent_count} agents, ${ref_count} reference files"

# --- Install batch-completion stop hook ---
# Prevents Claude from stopping mid-batch pipeline.
HOOKS_DIR="${REPO_ROOT}/.claude/hooks"
SETTINGS_FILE="${REPO_ROOT}/.claude/settings.json"
HOOK_SRC="${REPO_ROOT}/adapters/ambient/hooks/batch-completion-check.sh"

if [ -f "$HOOK_SRC" ]; then
  mkdir -p "$HOOKS_DIR"
  cp "$HOOK_SRC" "$HOOKS_DIR/"
  chmod +x "$HOOKS_DIR/batch-completion-check.sh"

  # Create settings file if missing
  if [ ! -f "$SETTINGS_FILE" ]; then
    echo '{}' > "$SETTINGS_FILE"
  fi

  # Install Stop hook (skip if already present)
  HAS_BATCH_HOOK=$(jq '[(.hooks.Stop // []) | .[] | .hooks // [] | .[] | select(.command? | contains("batch-completion-check"))] | length' "$SETTINGS_FILE" 2>/dev/null || echo 0)

  if [ "$HAS_BATCH_HOOK" -gt 0 ]; then
    echo "Batch completion hook: already installed"
  else
    jq '.hooks.Stop = (.hooks.Stop // []) + [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "bash ${CLAUDE_PROJECT_DIR}/.claude/hooks/batch-completion-check.sh",
        "timeout": 10
      }]
    }]' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
    echo "Batch completion hook: installed"
  fi
else
  echo "WARNING: batch-completion-check.sh not found at ${HOOK_SRC}" >&2
fi

# --- Create initial batch progress file ---
# This makes the stop hook block by default from session start.
# Only batch-progress.sh finish/abort can release it.
# Clears any stale counter from a previous crashed session.
rm -f "${REPO_ROOT}/artifacts/.batch_stop_count"
python3 -c "
import json, sys
from datetime import datetime, timezone
print(json.dumps({
    'status': 'in_progress',
    'created_at': datetime.now(timezone.utc).isoformat(),
    'updated_at': datetime.now(timezone.utc).isoformat(),
    'tickets': [],
    'current_ticket': None,
    'current_step': 'init',
    'completed_tickets': [],
    'failed_tickets': [],
    'batch_summary_written': False
}, indent=2))
" > "${REPO_ROOT}/artifacts/batch-progress.json"
echo "Batch progress: initialized (stop hook active)"

# Verify results field in ambient.json references the correct output directory
if python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
results = data.get('results', {})
bad = [k for k, v in results.items() if not v.startswith('artifacts/')]
if bad:
    print(f'WARNING: results field has paths not under artifacts/: {bad}', file=sys.stderr)
    sys.exit(1)
" "${REPO_ROOT}/.ambient/ambient.json" 2>&1; then
  echo "Results field: validated"
else
  echo "WARNING: results field may have stale paths" >&2
fi

# Write sentinel so orchestrator pre-flight can skip redundant setup
touch "${REPO_ROOT}/artifacts/.setup-complete"
echo "Setup sentinel: written"
