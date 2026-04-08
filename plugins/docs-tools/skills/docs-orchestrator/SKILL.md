---
name: docs-orchestrator
description: Documentation workflow orchestrator. Reads the step list from .claude/docs-workflow.yaml (or the plugin default). Runs steps sequentially, manages progress state, handles iteration and confirmation gates. Claude is the orchestrator — the YAML is a step list, not a workflow engine.

argument-hint: <ticket> [--workflow <name>] [--pr <url>]... [--repo <url-or-path>] [--mkdocs] [--draft] [--repo-path <path>] [--create-jira <PROJECT>]

allowed-tools: Read, Write, Glob, Grep, Edit, Bash, Skill, AskUserQuestion
---

# Docs Orchestrator

Claude is the orchestrator. The YAML is a step list. The hook is a safety net.

This skill teaches you how to run a documentation workflow pipeline. You read the step list from YAML, run each step skill sequentially, manage progress state via a JSON file, and handle iteration loops and confirmation gates.

## Pre-flight

Check if setup has already been completed by an upstream script (e.g., ACP's `setup.sh`):

```bash
if [[ -f "artifacts/.setup-complete" ]]; then
  echo "Setup already completed (sentinel found). Skipping pre-flight checks."
fi
```

If the sentinel file exists, skip directly to **Parse arguments**. Otherwise, run the full pre-flight:

```bash
# Source ~/.env if JIRA_API_TOKEN is not set
if [[ -z "${JIRA_API_TOKEN:-}" ]]; then
  set -a && source ~/.env 2>/dev/null && set +a
fi
```

1. If `JIRA_API_TOKEN` is still unset:
   - In interactive mode: **STOP** and ask the user to set it in `~/.env`
   - In headless mode (no user interaction available, e.g., ACP): log a warning and continue — agents will use `~/.env` credentials for JIRA access (populated by `setup.sh`)
2. Warn (don't stop) if `GITHUB_TOKEN` or `GITLAB_TOKEN` are unset
3. Install hooks (safe to re-run):

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/setup-hooks.sh
```

## Parse arguments

- `$1` — JIRA ticket ID (required). If missing, STOP and ask the user.
- `--workflow <name>` — Use `.claude/docs-<name>.yaml` instead of `docs-workflow.yaml`
- `--pr <url>` — PR/MR URLs (repeatable, accumulated into a list)
- `--mkdocs` — Use Material for MkDocs format instead of AsciiDoc
- `--draft` — Write documentation to a staging area instead of directly into the repo. When set, the writing step uses DRAFT placement mode (no framework detection, no branch creation). Without this flag, UPDATE-IN-PLACE is the default

- `--repo-path <path>` — Target repository for UPDATE-IN-PLACE mode. The docs-writer agent explores this directory for framework detection and writes files there, instead of writing to the repository at the current working directory. **Precedence**: if both `--repo-path` and `--draft` are passed, `--repo-path` wins — log a warning and ignore `--draft`
- `--repo <url-or-path>` — Source code repository. Can be a local path or a remote URL (https://, git@, ssh://). When provided without `--pr`, enables repo-driven documentation mode where the entire repo (or scoped subdirectories) is the subject matter. When provided alongside `--pr`, the PR branch is checked out within the provided repo.
>>>>>>> e4cd7e9 (feat: Add source repo orchestration and post-requirements auto-discovery)
- `--create-jira <PROJECT>` — Create a linked JIRA ticket in the specified project

## Resolve source repository

After parsing arguments and before running steps, resolve the source code repository if one is configured. This makes the repo available to all downstream steps that need it (requirements, code-evidence, writing).

### Determine source configuration

Check for source information in priority order:

1. **CLI `--repo` flag** — if provided, use it directly
2. **Per-ticket source config** — check for `<base-path>/source.yaml`. If found, read it
3. **PR-derived** — if `--pr` URLs were provided but no `--repo`, resolve the repo from the PR before steps run (see below)
4. **Post-requirements discovery** — if none of the above apply, defer source resolution until after the requirements step completes. The requirements analyst often discovers PR/MR URLs from the JIRA ticket graph. After requirements finishes, the orchestrator scans `requirements.md` for PR URLs, resolves the repo, and enables code-evidence. See [Post-requirements source resolution](#post-requirements-source-resolution) below
5. **None** — no source found even after requirements. Steps with `when: has_source_repo` that are still `deferred` are marked `skipped`

If source (1) or (2) is available, proceed to clone/verify below.

If source (3) applies (PR-only, no `--repo`), resolve the repo from the PR URL before steps run. Extract the repo URL and PR branch from the first `--pr` URL:

```bash
REPO_URL=$(gh pr view "$PR_URL" --json headRepository --jq '.headRepository.url')
PR_BRANCH=$(gh pr view "$PR_URL" --json headRefName --jq '.headRefName')
```

Then proceed with clone/verify below using these values. Set `has_source_repo` to true. This centralizes all repo acquisition in the orchestrator — code-evidence no longer handles cloning.

### Distinguish URL from local path

- If the value starts with `https://`, `git@`, or `ssh://` → treat as a remote URL and clone
- Otherwise → treat as a local path and verify it exists

### Per-ticket source config schema

Writers can create `<base-path>/source.yaml` before starting a workflow to pre-configure the source repo and scope. The orchestrator also writes this file from `--repo` on first run so that resume picks it up automatically.

```yaml
# .claude/docs/<ticket>/source.yaml
repo: https://github.com/org/operator   # URL or local path (required)
ref: main                                # branch, tag, or commit (default: HEAD)
scope:
  include:                               # glob patterns — what to index and search
    - "src/controllers/**"
    - "pkg/api/v1/**"
    - "README.md"
  exclude:                               # glob patterns — what to skip
    - "**/vendor/**"
    - "**/testdata/**"
    - "**/*_test.go"
```

All fields except `repo` are optional. If `scope` is omitted, the entire repository is in scope.

### Clone or verify the repo

Set `CLONE_DIR="${BASE_PATH}/code-repo"`.

**If `repo` is a local path:**
- Verify it exists and is a directory. If not, STOP with error: "Source repo path does not exist: `<path>`"
- Set `REPO_PATH` to the local path (do not copy it)

**If `repo` is a URL:**
- If `$CLONE_DIR` already exists, reuse it. Run `git -C "$CLONE_DIR" rev-parse HEAD` to verify it's a valid git repo. If `ref` in source config differs from what's checked out, fetch and checkout the requested ref.
- If `$CLONE_DIR` does not exist, clone:

  ```bash
  # If ref is specified
  git clone --depth 1 --branch "$REF" "$REPO_URL" "$CLONE_DIR"

  # Fallback if branch clone fails (e.g., ref is a commit hash)
  git clone --depth 1 "$REPO_URL" "$CLONE_DIR"
  cd "$CLONE_DIR" && git fetch origin "$REF" && git checkout FETCH_HEAD
  ```

- If clone fails, STOP with error: "Cannot clone `<REPO_URL>`. For private repos, ensure `gh` is authenticated. Alternatively, clone manually and provide `--repo <local_path>`."

Set `REPO_PATH` to the resolved path.

**If `--pr` URLs were also provided:**
- Extract the PR branch: `gh pr view "$PR_URL" --json headRefName --jq '.headRefName'`
- Override `ref` with the PR branch (the PR code is what's being documented)
- PR overrides `ref` only — `scope` from `source.yaml` is preserved

### Persist source config

If the source was provided via CLI `--repo` and no `source.yaml` exists yet, write one **after** successful clone/verify:

```yaml
repo: <url-or-path>
ref: <ref>
```

This ensures resume picks up the same source without re-specifying CLI args. Do not write `source.yaml` before clone succeeds — a failed clone should not leave stale config.

### Record in progress file

Add the resolved source to the progress file `options`:

```json
"options": {
  "source": {
    "repo_path": ".claude/docs/proj-123/code-repo",
    "repo_url": "https://github.com/org/operator",
    "ref": "main",
    "scope": {
      "include": ["src/controllers/**", "pkg/api/v1/**"],
      "exclude": ["**/vendor/**"]
    }
  }
}
```

If no source was configured, `options.source` is `null`.

## Load the step list

### 1. Determine the YAML file

- If `--workflow <name>` was specified → `.claude/docs-<name>.yaml`
- Otherwise → `.claude/docs-workflow.yaml`
- If neither exists → use the plugin default at `skills/docs-orchestrator/defaults/docs-workflow.yaml`

### 2. Read the YAML

Read the YAML file and extract the ordered step list. Each step has: `name`, `skill`, `description`, optional `when`, and optional `inputs`.

### 3. Evaluate `when` conditions

- `when: create_jira_project` → run this step only if `--create-jira` was passed
- `when: has_source_repo` → evaluation depends on timing:
  - If a source repo was already resolved pre-flight (via `--repo`, `--pr`, or `source.yaml`) → step runs normally (`pending`)
  - If no source is resolved yet but post-requirements discovery is possible (case 4 above) → mark the step `deferred` (not `skipped`). The orchestrator re-evaluates after requirements completes
  - After post-requirements resolution: `deferred` steps become `pending` (source found) or `skipped` (no source found)
- Steps with no `when` always run
- Steps that don't meet their `when` condition and cannot be deferred are marked `skipped` in the progress file

### 4. Validate the step list

All of the following must be true. If any check fails, **STOP** with a clear error:

- All step names are unique
- All `skill` references resolve to a known skill (bare names like `docs-workflow-writing` are preferred; fully qualified `plugin:skill` format is also accepted)
- Input dependencies are satisfied — for each step with `inputs`, every referenced step name must be present in the step list (unless it has a `when` condition that would skip it)

### Input dependencies

Steps declare their inputs as a list of upstream step names in the YAML:

```yaml
- name: writing
  skill: docs-workflow-writing
  inputs: [planning]

- name: create-jira
  skill: docs-workflow-create-jira
  when: create_jira_project
  inputs: [planning]
```

The orchestrator validates at load time that every step name in `inputs` exists in the step list. Step skills read their input data from the upstream step's output folder by convention (see below).

**Conditional input dependencies**: If an upstream step in `inputs` has a `when` condition and was `skipped`, that dependency is considered satisfied. The downstream step is responsible for checking whether the optional input data actually exists (e.g., the writing step checks for `evidence.json` and uses it if present, but proceeds without it). Only upstream steps that ran and `failed` block downstream execution.

**Custom workflow validation**: If a step's `inputs` references a step that does not exist in the current YAML step list, fail at load time with an error (e.g., "Step 'writing' requires 'planning', but 'planning' is not in the step list").

## Output conventions

Every step writes to a predictable folder based on the ticket ID and step name:

```
artifacts/<ticket>/<step-name>/
```

The ticket ID is converted to **lowercase** for directory names (e.g., `PROJ-123` → `proj-123`).

### Resolve base path

Resolve the base path to an absolute path so agents (which may run in a different working directory) can locate files correctly:

```bash
BASE_PATH="$(cd "$(git rev-parse --show-toplevel)" && pwd)/artifacts/${TICKET_LOWER}"
```

Use this absolute `BASE_PATH` for the progress file's `base_path` field and for all `--base-path` arguments passed to step skills.

### Folder structure

```
artifacts/proj-123/
  source.yaml                        (per-ticket source config, if applicable)
  code-repo/                         (cloned source repo, if applicable)
>>>>>>> e4cd7e9 (feat: Add source repo orchestration and post-requirements auto-discovery)
  requirements/
    requirements.md
  planning/
    plan.md
  code-evidence/                     (if source repo is available)
    evidence.json
    summary.md
  prepare-branch/
    branch-info.md
  writing/
    _index.md
    assembly_*.adoc (or docs/*.md for mkdocs)
    modules/
  technical-review/
    review.md
  style-review/
    review.md
  workflow/
    docs-workflow_proj-123.json
```

Each step skill knows its own output folder and writes there. Each step reads input from upstream step folders referenced in its `inputs` list. The orchestrator passes the base path `artifacts/<ticket>/` — step skills derive everything else by convention.

## Progress file

Claude writes the progress file directly using the Write tool. Create it after parsing arguments, before step 1. Update it after each step.

**Location**: `artifacts/<ticket>/workflow/<workflow-type>_<ticket>.json`

The `workflow_type` field and filename prefix match the YAML's `workflow.name`. This allows multiple workflow types to run against the same ticket without conflict.

### Schema

```json
{
  "workflow_type": "<workflow.name from YAML>",
  "ticket": "<TICKET>",
  "base_path": "/absolute/path/to/artifacts/<ticket>",
  "status": "in_progress",
  "created_at": "<ISO 8601>",
  "updated_at": "<ISO 8601>",
  "options": {
    "format": "adoc",
    "draft": false,
    "create_jira_project": null,
    "pr_urls": [],
    "source": null
  },
  "step_order": ["requirements", "planning", "writing", ...],
  "steps": {
    "<step-name>": {
      "status": "pending",
      "output": null
    }
  }
}
```

The `output` field records the step's output folder path (e.g., `artifacts/proj-123/writing/`) once completed.

### Status values

| Value | Meaning |
|---|---|
| `pending` | Not yet started |
| `in_progress` | Currently running |
| `completed` | Finished successfully |
| `failed` | Failed — needs retry |
| `skipped` | Conditional step not applicable |
| `deferred` | Waiting for upstream step to determine if condition is met |

### `step_order`

A top-level array listing steps in canonical order. This field exists so the Stop hook can determine step ordering without a hardcoded bash array. It **must** always be written by the orchestrator and kept in sync with the YAML step list.

## Check for existing work

Before starting, check for a progress file at `artifacts/<ticket>/workflow/<workflow-type>_<ticket>.json`.

**If a progress file exists:**

1. Read it and identify which steps have status `"completed"` or `"skipped"`
2. For each `"completed"` step, verify its output folder still exists on disk. If it has been deleted, reset that step to `"pending"` and reset all downstream dependent steps to `"pending"` as well
3. Resume from the first step with status `"pending"` or `"failed"`
4. Before running the resume step, validate its input dependencies are satisfied
5. Tell the user: "Found existing work for `<ticket>`. Resuming from `<step>`."
6. If the user provided additional flags on resume (e.g., `--create-jira`), update the progress file options accordingly

**If no progress file exists**, start from step 1 and create a new progress file.

## Running workflow steps

Run steps in the order defined by the YAML. For each step:

- If the step's status is `deferred`, skip it for now — it will be re-evaluated after post-requirements source resolution
- If the step's status is `skipped`, skip it permanently

### Before the step

1. Validate input dependencies — for each step name in the step's YAML `inputs`, the referenced upstream step must have `status: "completed"` (or `"skipped"` if the upstream step has a `when` condition) and a non-null `output` folder in the progress file. If any required input step has status `"failed"`, **fail the current step immediately** with a clear error (e.g., "Step 'writing' requires 'planning', but planning has status 'failed'"). Upstream steps that were `skipped` are treated as satisfied — the downstream step is responsible for checking whether the optional input data actually exists
2. Update the step's status to `"in_progress"` in the progress file

### Construct arguments

Build the args string for the step skill:

<<<<<<< HEAD
1. **Always**: `<ticket> --base-path <base_path>` — the ticket ID and the **absolute** base output path
2. **If source repo is resolved**: `--repo <repo_path>` — passed to steps that can use it
3. **From orchestrator context**: Step-specific args from parsed CLI flags:
   - `requirements`: `[--pr <url>]... [--repo <repo_path>]`
   - `prepare-branch`: `[--draft] [--repo-path <path>]`
   - `code-evidence`: `--repo <repo_path> [--scope-include <globs>] [--scope-exclude <globs>] [--reindex]` — scope globs come from `source.yaml` or `options.source.scope` in the progress file
   - `writing`: `--format <adoc|mkdocs> [--draft] [--repo <repo_path>] [--repo-path <path>]`
   - `style-review`: `--format <adoc|mkdocs>`
   - `create-jira`: `--project <PROJECT>`

Step skills derive their own output folder and input folders from `--base-path` and step name conventions. No per-input flag wiring needed.

### Invoke the step skill

```
Skill: <step.skill>, args: "<constructed args>"
```

### After the step

1. Verify the output folder exists (for steps that produce files). If the expected output folder is missing, mark the step as `failed` in the progress file and **STOP**
2. Update the step's status to `"completed"` with the output folder path in the progress file
3. Update the progress file's `updated_at` timestamp
4. **If the just-completed step is `requirements` AND `options.source` is `null`** → run [Post-requirements source resolution](#post-requirements-source-resolution) before continuing to the next step. This may change `deferred` steps to `pending` or `skipped`

## Post-requirements source resolution

This section triggers **only** when the `requirements` step completes AND `options.source` is still `null` (i.e., no source was resolved pre-flight). It implements case 4 from "Determine source configuration".

### 1. Scan requirements for PR URLs

Read `<base-path>/requirements/requirements.md` and extract all GitHub/GitLab PR/MR URLs. Look for URLs matching these patterns:

- `https://github.com/<org>/<repo>/pull/<number>`
- `https://gitlab.com/<org>/<repo>/-/merge_requests/<number>`

URLs may appear as bare links or inside markdown links (e.g., `[PR #1651](https://github.com/org/repo/pull/1651)`). Extract the URL itself, not the link text.

### 2. Group by repository

Extract the `<org>/<repo>` segment from each URL and group the PRs by repository.

### 3. Select the source repository

- **No PRs found** → update all `deferred` steps to `skipped`, continue the workflow without code-evidence. Log: "No PR URLs found in requirements. Skipping code-evidence."
- **Single repo** → use it directly. Resolve the repo URL and branch from the first PR:

  ```bash
  REPO_URL=$(gh pr view "$PR_URL" --json headRepository --jq '.headRepository.url')
  PR_BRANCH=$(gh pr view "$PR_URL" --json headRefName --jq '.headRefName')
  ```

- **Multiple repos** → use the repo with the most PR references (heuristic: more PRs = more relevant to the ticket). Log a warning listing all discovered repos:

  > Auto-selected `<org>/<repo>` (3 PRs). Also found: `<other-org>/<other-repo>` (1 PR). Override with `--repo` if needed.

  Resolve the repo URL and branch from the first PR of the selected repo.

### 4. Clone and configure

1. Clone the repo using the existing "Clone or verify the repo" procedure with `CLONE_DIR="${BASE_PATH}/code-repo"`
2. If `PR_BRANCH` was resolved, check out that branch
3. Write `source.yaml` for resume:

   ```yaml
   repo: <repo_url>
   ref: <pr_branch or main>
   ```

4. Update the progress file `options.source`:

   ```json
   "source": {
     "repo_path": "<base-path>/code-repo",
     "repo_url": "<repo_url>",
     "ref": "<branch>",
     "scope": null
   }
   ```

5. Update all `deferred` steps to `pending`

### 5. Handle clone failure

If the clone fails, log a warning and degrade gracefully:

> Could not clone `<repo_url>`. Code-evidence will be skipped. To retry, run with `--repo <url-or-local-path>`.

Update all `deferred` steps to `skipped`. The workflow continues without code-evidence — the writing step proceeds using only the requirements and plan.

## Technical review iteration

The technical review step runs in a loop until confidence is acceptable or three iterations are exhausted:

1. Invoke `docs-workflow-tech-review` with the standard args
2. Read the output file and check for `Overall technical confidence: (HIGH|MEDIUM|LOW)`
   - If the confidence line is **missing** from the output, treat it as a step failure — mark the step `failed` and stop iteration
3. If `HIGH` → mark completed, proceed to next step
4. If `MEDIUM`, check for the `Severity counts:` line in the review output:
   - If present and both `critical=0` AND `significant=0` → treat as acceptable. Log: "MEDIUM confidence with zero critical/significant issues — proceeding (remaining items require SME review)." Mark completed and proceed to next step.
   - If the severity line is missing, or either `critical > 0` or `significant > 0` → continue to step 5 for iteration
5. If `MEDIUM` (with fixable issues) or `LOW` and fewer than 3 iterations completed → run the fix skill:
   ```
   Skill: docs-workflow-writing, args: "<ticket> --base-path <base_path> --fix-from <base_path>/technical-review/review.md"
   ```
   Then re-run the reviewer (go to step 1)
6. After 3 iterations without reaching `HIGH`:
   - `MEDIUM` is acceptable — proceed with a warning that manual review is recommended
   - `LOW` after max iterations — ask the user whether to proceed or stop

## Completion

After all steps complete (or are skipped):

1. Update the progress file: `status → "completed"`
2. Display a summary:
   - List all output folders with paths
   - Note any warnings (tech review didn't reach `HIGH`, etc.)
   - Show JIRA URL if a ticket was created

## Resume behavior

### Same session

The progress file is already in context. Skip completed steps and continue from the first `pending` or `failed` step. The Stop hook ensures Claude doesn't stop prematurely.

### New session

User says: `"Resume docs workflow for PROJ-123"`

1. Invoke this skill with the ticket
2. Check for an existing progress file
3. Read it, skip completed steps, resume from first `pending` or `failed` step
4. Before running the resume step, **validate its input dependencies** — every required upstream step must have `status: "completed"` and a non-null `output` folder. If a dependency is `failed` or `pending`, re-run that dependency first
5. For each upstream dependency, verify the output folder still exists on disk. If an output folder was deleted, mark that step as `pending` and re-run it
6. The user can provide additional flags on resume (e.g., add `--create-jira`) — update the progress file options accordingly

### After failure

Same as new session. The progress file shows which steps completed and which failed. Walk back to the earliest incomplete dependency and resume from there.

## Follow-on work

### Requirements-analyst agent: repo-aware analysis

When `--repo` is passed to the requirements step, the `requirements-analyst` agent should use the repo to enrich its analysis. This is **not yet implemented** — the requirements step currently accepts `--repo` but the agent does not act on it. Future work:

- Scan the repo's `README.md`, `CHANGELOG.md`, and `docs/` directory for existing documentation
- Note what documentation already exists and what gaps remain (feeds directly into the planning step's gap analysis)
- Extract project metadata: language, build system, major dependencies, directory structure
- Identify existing code examples, tutorials, or quickstart guides that the writer could reference or update rather than recreate
- If no `--pr` was provided, use the repo structure itself to identify the key components and features that need documentation

This work requires changes to the `requirements-analyst` agent definition (`agents/requirements-analyst.md`), not just the step skill.
