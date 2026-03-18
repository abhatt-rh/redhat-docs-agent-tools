# Design Spec: Decompose docs-workflow into Skills

**Date**: 2026-03-18
**Status**: Draft
**Scope**: `plugins/docs-tools/`

## Problem

The `docs-workflow` command (`commands/docs-workflow.md`) is a ~1300-line monolithic orchestrator that inlines all stage prompts, state management, JIRA API logic, and control flow into a single markdown file. This causes:

- **No reusability** — individual stages (e.g., requirements analysis, JIRA creation) cannot be invoked independently
- **Maintenance burden** — changes to one stage risk breaking others; reviewing diffs is difficult
- **Testing difficulty** — no way to test a single stage in isolation
- **Commands are deprecated** — the plugin architecture is moving to skills only

## Solution

Decompose the monolithic command into a **thin orchestrator skill** plus **7 stage skills**, with a **shared state management script**. The orchestrator owns the dispatch loop; each stage skill owns its agent dispatch, prompt template, and output verification. A Python script centralizes all state file operations.

### Approach

Approach B (Thin Orchestrator + Skill Library) from the brainstorming session. The orchestrator retains explicit sequential control flow (not hook-driven), while hooks provide optional cross-cutting enhancements.

## Component Inventory

### New files

```
plugins/docs-tools/skills/
  docs-workflow/
    docs-workflow.md                          # Orchestrator skill (~250 lines)
    scripts/
      workflow_state.py                       # Shared state management (~150 lines)

  docs-workflow-requirements/
    docs-workflow-requirements.md             # Stage 1 (~80 lines)

  docs-workflow-planning/
    docs-workflow-planning.md                 # Stage 2 (~70 lines)

  docs-workflow-writing/
    docs-workflow-writing.md                  # Stage 3 (~90 lines)

  docs-workflow-tech-review/
    docs-workflow-tech-review.md              # Stage 4 (~120 lines)

  docs-workflow-style-review/
    docs-workflow-style-review.md             # Stage 5 (~90 lines)

  docs-workflow-integrate/
    docs-workflow-integrate.md                # Stage 6 (~110 lines)

  docs-workflow-create-jira/
    docs-workflow-create-jira.md              # Stage 7 (~160 lines)

  docs-workflow/hooks/                        # Optional hook scripts
    workflow_preflight.sh                     # PreToolUse: validate tokens
    workflow_progress.sh                      # Stop: show progress bar
```

### Unchanged files

The 6 agent definitions remain untouched:

- `agents/requirements-analyst.md`
- `agents/docs-planner.md`
- `agents/docs-writer.md`
- `agents/technical-reviewer.md`
- `agents/docs-reviewer.md`
- `agents/docs-integrator.md`

### Deleted files

- `commands/docs-workflow.md` — replaced by the orchestrator skill

## State File Contract

All skills share a single state file at `.claude/docs/workflow/workflow_<ticket>.json`. The `workflow_state.py` script is the sole writer — stage skills never manipulate the JSON directly.

### Breaking change: `data` field removed

The old command's state schema included a `"data"` object with `jira_summary` and `related_prs` fields. These were initialized but never read by any stage. The new schema drops this field. The `workflow_state.py load` command must tolerate state files that contain a `data` field (ignore it) so that in-progress workflows created under the old schema can be resumed after migration.

### Schema

```json
{
  "ticket": "PROJ-123",
  "created_at": "2026-03-18T10:00:00Z",
  "updated_at": "2026-03-18T12:34:56Z",
  "current_stage": "writing",
  "status": "in_progress",
  "options": {
    "pr_urls": ["https://github.com/org/repo/pull/456"],
    "format": "adoc",
    "integrate": false,
    "create_jira_project": null
  },
  "stages": {
    "requirements":     { "status": "completed",   "output_file": ".claude/docs/requirements/requirements_proj_123_20260318.md", "started_at": "...", "completed_at": "..." },
    "planning":         { "status": "completed",   "output_file": ".claude/docs/plans/plan_proj_123_20260318.md",                "started_at": "...", "completed_at": "..." },
    "writing":          { "status": "in_progress", "output_file": null, "started_at": "...", "completed_at": null },
    "technical_review": { "status": "pending",     "output_file": null, "started_at": null,  "completed_at": null, "iterations": 0 },
    "review":           { "status": "pending",     "output_file": null, "started_at": null,  "completed_at": null },
    "integrate":        { "status": "pending",     "output_file": null, "started_at": null,  "completed_at": null, "phase": null },
    "create_jira":      { "status": "pending",     "output_file": null, "started_at": null,  "completed_at": null }
  }
}
```

### Stage status values

| Value | Meaning |
|---|---|
| `pending` | Not yet started |
| `in_progress` | Currently running |
| `completed` | Finished successfully |
| `failed` | Failed — workflow stopped |

### Integration phase values

| Value | Meaning |
|---|---|
| `null` | First entry — run PLAN phase |
| `awaiting_confirmation` | Plan produced, waiting for user |
| `confirmed` | User approved — run EXECUTE phase |
| `declined` | User declined — save plan, skip execution |

### Stage key naming note

The state schema uses `"review"` as the key for the style review stage (inherited from the original command), while the skill is named `docs-workflow-style-review`. The orchestrator's dispatch table maps `review → docs-tools:docs-workflow-style-review`. This mismatch is intentional — renaming the state key would break resume compatibility with in-progress workflows.

## Shared State Script: `workflow_state.py`

**Location**: `plugins/docs-tools/skills/docs-workflow/scripts/workflow_state.py`

**Invocation from within `docs-workflow` skill (co-located)**:

```bash
python3 scripts/workflow_state.py <command> [args]
```

**Invocation from other `docs-workflow-*` skills (cross-skill)**:

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/skills/docs-workflow/scripts/workflow_state.py <command> [args]
```

### Commands

```
init <ticket> [--pr <url>]... [--mkdocs] [--integrate] [--create-jira <PROJECT>]
    Create a new state file. If one already exists, treat as resume.
    Prints the absolute state file path to stdout.

load <ticket>
    Print the state file path if it exists. Exit 1 if not found.

status <ticket>
    Print a formatted status display with stage checkmarks.

next-stage <ticket>
    Print the name of the next incomplete stage. This is the sole owner
    of conditional-stage skip logic in orchestrated mode:
      - Skip integrate if options.integrate is false
      - Skip create_jira if options.create_jira_project is null
    Print "done" if all applicable stages are completed.

get <ticket> <jq-expression>
    Read a value from state and print to stdout.
    Example: get PROJ-123 '.options.format'
    Example: get PROJ-123 '.stages.requirements.output_file'

start-stage <ticket> <stage>
    Set stage status to in_progress, set started_at to now,
    set current_stage, set overall status to in_progress.

complete-stage <ticket> <stage> <output_file>
    Verify output_file exists. If not, search the stage's conventional
    output directory for the most recent matching file:
      - requirements: .claude/docs/requirements/
      - planning: .claude/docs/plans/
      - writing/technical_review/review/integrate/create_jira: .claude/docs/drafts/<ticket>/
    Set stage status to completed, set completed_at, set output_file.
    Exit 1 with error if no output file can be found.

fail-stage <ticket> <stage>
    Set stage status to failed, set overall status to failed.

set <ticket> <jq-expression>
    Apply an arbitrary jq-style update to the state file.
    Example: set PROJ-123 '.stages.integrate.phase = "confirmed"'
    Example: set PROJ-123 '.stages.technical_review.iterations += 1'

add-pr <ticket> <url>
    Append a PR URL to options.pr_urls (deduplicated).

complete-workflow <ticket>
    Set overall status to completed, set updated_at.
```

### Implementation notes

- Uses Python `json` module for reads and writes (no `jq` dependency at runtime)
- The `get` and `set` commands accept jq-like dotpath syntax but are implemented in Python. Supported subset:
  - Simple dotpaths: `.options.format`, `.stages.requirements.output_file`
  - Assignment: `.stages.integrate.phase = "confirmed"`
  - Increment: `.stages.technical_review.iterations += 1`
  - Default operator: `.stages.integrate.phase // "null"` (returns the right-hand value if the left is `null` or missing)
  - Array access is NOT supported — use dedicated commands (`add-pr`) for array operations
- The `init` command maps flags to state options: `--mkdocs` sets `options.format` to `"mkdocs"` (default: `"adoc"`), `--integrate` sets `options.integrate` to `true`, `--create-jira <PROJECT>` sets `options.create_jira_project`
- State file path convention: `.claude/docs/workflow/workflow_<safe_ticket>.json` where `<safe_ticket>` is the ticket ID lowercased with hyphens replaced by underscores
- All write operations use atomic write (write to temp file, then `os.replace`)
- Creates `.claude/docs/workflow/` directory if it does not exist

## Orchestrator Skill: `docs-workflow.md`

**Location**: `plugins/docs-tools/skills/docs-workflow/docs-workflow.md`

### Frontmatter

```yaml
---
name: docs-workflow
description: Run the multi-stage documentation workflow for a JIRA ticket. Orchestrates stage skills sequentially — requirements, planning, writing, technical review, style review, and optionally integration and JIRA creation.
argument-hint: [action] <ticket> [--pr <url>] [--create-jira <PROJECT>] [--mkdocs] [--integrate]
---
```

### Responsibilities

The orchestrator owns exactly 5 things:

1. **Argument parsing** — parse `ACTION`, `TICKET`, `--pr`, `--mkdocs`, `--integrate`, `--create-jira` from args
2. **Pre-flight token validation** — check `JIRA_AUTH_TOKEN` is set (required), warn if `GITHUB_TOKEN`/`GITLAB_TOKEN` are missing
3. **State init/load** — call `workflow_state.py init` (for `start`) or `workflow_state.py load` (for `resume`); handle `add-pr` for new URLs on resume
4. **Stage dispatch loop** — call `workflow_state.py next-stage`, invoke the corresponding `docs-workflow-*` skill, repeat until `done`
5. **Completion summary** — display final status, JIRA URL if created

### Pseudocode

```
## Step 1: Parse Arguments

Parse action ($1, default: start), ticket ($2, required), and flags.
If no ticket is provided, STOP and ask the user.

## Step 2: Pre-flight Validation

Source ~/.env if JIRA_AUTH_TOKEN is not set.
Validate JIRA_AUTH_TOKEN is present — STOP if missing.
Warn (don't stop) if GITHUB_TOKEN or GITLAB_TOKEN are missing.

## Step 3: Initialize or Load State

If action is "start":
  STATE_FILE=$(python3 scripts/workflow_state.py init $TICKET [flags])
  If state file already existed, treat as resume.

If action is "resume":
  STATE_FILE=$(python3 scripts/workflow_state.py load $TICKET)
  If not found, tell user to start first.
  Add any new --pr URLs via workflow_state.py add-pr.
  Update --integrate and --create-jira options if provided.

If action is "status":
  python3 scripts/workflow_state.py status $TICKET
  STOP — do not run any stages.

## Step 4: Run Stages

Loop:
  NEXT=$(python3 scripts/workflow_state.py next-stage $TICKET)

  If NEXT is "done", break.

  Invoke the stage skill:
    requirements    → Skill: docs-tools:docs-workflow-requirements, args: "$TICKET $STATE_FILE"
    planning        → Skill: docs-tools:docs-workflow-planning, args: "$TICKET $STATE_FILE"
    writing         → Skill: docs-tools:docs-workflow-writing, args: "$TICKET $STATE_FILE"
    technical_review → Skill: docs-tools:docs-workflow-tech-review, args: "$TICKET $STATE_FILE"
    review          → Skill: docs-tools:docs-workflow-style-review, args: "$TICKET $STATE_FILE"
    integrate       → Skill: docs-tools:docs-workflow-integrate, args: "$TICKET $STATE_FILE"
    create_jira     → Skill: docs-tools:docs-workflow-create-jira, args: "$TICKET $STATE_FILE"

  After the skill returns, loop back to next-stage.

## Step 5: Completion

python3 scripts/workflow_state.py complete-workflow $TICKET
python3 scripts/workflow_state.py status $TICKET

If create_jira completed, display the JIRA URL.
```

### What the orchestrator does NOT contain

- Stage prompts (moved to stage skills)
- Agent dispatch logic (moved to stage skills)
- Output file path construction (moved to stage skills)
- JIRA API calls (moved to `docs-workflow-create-jira`)
- Integration phase logic (moved to `docs-workflow-integrate`)
- Technical review iteration logic (moved to `docs-workflow-tech-review`)
- State file jq manipulation (moved to `workflow_state.py`)

## Stage Skill Interface Contract

Every `docs-workflow-*` stage skill follows an identical contract.

### Frontmatter pattern

```yaml
---
name: docs-workflow-<stage>
description: <One-line description>. Can be invoked standalone or as part of the docs-workflow pipeline.
allowed-tools: Read, Write, Glob, Grep, Edit, Bash, WebSearch, WebFetch
---
```

The `allowed-tools` field should match the tools needed by each stage. Most stages need `Read, Write, Glob, Grep, Edit, Bash`. Stages that dispatch agents with web access (requirements, planning) add `WebSearch, WebFetch`. The orchestrator skill needs the same set plus the ability to invoke the `Skill` tool.

### Arguments

- `$1` — `TICKET` (required)
- `$2` — `STATE_FILE` (optional — auto-detected or created if omitted)

### Lifecycle

```
0. Check preconditions (conditional stages only — integrate, create_jira)
   - This step exists ONLY in docs-workflow-integrate and docs-workflow-create-jira
   - Read the relevant option from state (options.integrate, options.create_jira_project)
   - If the option is not set, skip the stage entirely (return, do not update state)
   - In orchestrated mode, next-stage already skips these stages, so this check
     is defense-in-depth. In standalone mode, this is the only guard.
   - This check runs BEFORE start-stage to avoid leaving a stage stuck in in_progress

1. Resolve state
   - If STATE_FILE provided, use it
   - Else try workflow_state.py load $TICKET
   - Else workflow_state.py init $TICKET (standalone mode)

2. Mark in_progress
   workflow_state.py start-stage $TICKET <stage>

3. Resolve paths and read inputs
   - Construct output file path
   - Read previous stage output from state (if applicable)
   - Read options from state (format, pr_urls, etc.)

4. Dispatch agent
   - Invoke Agent tool with subagent_type, description, and fully resolved prompt
   - All <VARIABLE> placeholders expanded to actual values before passing

5. Verify output
   - Check output file exists at expected path
   - Fall back to searching stage output directory

6. Mark completed
   workflow_state.py complete-stage $TICKET <stage> $OUTPUT_FILE

On failure at any step:
   workflow_state.py fail-stage $TICKET <stage>
   STOP — do not continue
```

### Standalone invocation

Every stage skill can be invoked directly:

```
Skill: docs-tools:docs-workflow-requirements, args: "PROJ-123"
Skill: docs-tools:docs-workflow-planning, args: "PROJ-123"
Skill: docs-tools:docs-workflow-style-review, args: "PROJ-123"
```

When invoked without a state file argument, the skill auto-detects or creates a minimal state. This enables ad-hoc use — run just the requirements analysis, or just the style review, without the full pipeline.

## Stage 1: `docs-workflow-requirements`

**Location**: `plugins/docs-tools/skills/docs-workflow-requirements/docs-workflow-requirements.md`

### Agent dispatch

- **subagent_type**: `docs-tools:requirements-analyst`
- **description**: `Analyze requirements for <TICKET>`

### Output path

```bash
.claude/docs/requirements/requirements_<safe_ticket>_<timestamp>.md
```

### Inputs from state

- `options.pr_urls` — merged into the prompt as a bullet list (omitted if empty)

### Prompt

> Analyze documentation requirements for JIRA ticket `<TICKET>`.
>
> Manually-provided PR/MR URLs to include in analysis (merge with any auto-discovered URLs, dedup):
> - `<PR_URL_1>`
> - `<PR_URL_2>`
>
> Save your complete analysis to: `<OUTPUT_FILE>`
>
> Follow your standard analysis methodology (JIRA fetch, ticket graph traversal, PR/MR analysis, web search expansion). Format the output as structured markdown for the next stage.

The PR URL bullet list is conditional — include only if PR URLs exist in state.

### Output verification fallback

```bash
ls -t .claude/docs/requirements/*<safe_ticket>*.md | head -1
```

## Stage 2: `docs-workflow-planning`

**Location**: `plugins/docs-tools/skills/docs-workflow-planning/docs-workflow-planning.md`

### Agent dispatch

- **subagent_type**: `docs-tools:docs-planner`
- **description**: `Create documentation plan for <TICKET>`

### Output path

```bash
.claude/docs/plans/plan_<safe_ticket>_<timestamp>.md
```

### Inputs from state

- `stages.requirements.output_file` — previous stage output, passed as `<PREV_OUTPUT>` in prompt

### Prompt

> Create a comprehensive documentation plan based on the requirements analysis.
>
> Read the requirements from: `<PREV_OUTPUT>`
>
> The plan must include:
> 1. Gap analysis (existing vs needed documentation)
> 2. Module specifications (type, title, audience, content points, prerequisites, dependencies)
> 3. Implementation order based on dependencies
> 4. Assembly structure (how modules group together)
> 5. Content sources from JIRA and PR/MR analysis
>
> Save the complete plan to: `<OUTPUT_FILE>`
>
> Use structured markdown with clear sections for each module.

## Stage 3: `docs-workflow-writing`

**Location**: `plugins/docs-tools/skills/docs-workflow-writing/docs-workflow-writing.md`

### Agent dispatch

- **subagent_type**: `docs-tools:docs-writer`
- **description**: `Write AsciiDoc documentation for <TICKET>` (or `Write MkDocs documentation for <TICKET>`)

### Output paths

**AsciiDoc (default):**

```
.claude/docs/drafts/<ticket>/
  _index.md
  assembly_<name>.adoc
  modules/
    <concept>.adoc
    <procedure>.adoc
    <reference>.adoc
```

**MkDocs (`options.format == "mkdocs"`):**

```
.claude/docs/drafts/<ticket>/
  _index.md
  mkdocs-nav.yml
  docs/
    <concept>.md
    <procedure>.md
    <reference>.md
```

### Inputs from state

- `stages.planning.output_file` — previous stage output
- `options.format` — `"adoc"` or `"mkdocs"`, determines prompt variant and directory structure

### Prompt (AsciiDoc)

> Write complete AsciiDoc documentation based on the documentation plan for ticket `<TICKET>`.
>
> Read the plan from: `<PREV_OUTPUT>`
>
> **IMPORTANT**: Write COMPLETE .adoc files, not summaries or outlines.
>
> Output folder structure:
> ```
> <DRAFTS_DIR>/
> +-- _index.md
> +-- assembly_<name>.adoc
> +-- modules/
>     +-- <concept-name>.adoc
>     +-- <procedure-name>.adoc
>     +-- <reference-name>.adoc
> ```
>
> Save modules to: `<MODULES_DIR>/`
> Save assemblies to: `<DRAFTS_DIR>/`
> Create index at: `<DRAFTS_DIR>/_index.md`

### Prompt (MkDocs)

> Write complete Material for MkDocs Markdown documentation based on the documentation plan for ticket `<TICKET>`.
>
> Read the plan from: `<PREV_OUTPUT>`
>
> **IMPORTANT**: Write COMPLETE .md files with YAML frontmatter (title, description), not summaries or outlines. Use Material for MkDocs conventions: admonitions, content tabs, code blocks with titles, and proper heading hierarchy starting at `# h1`.
>
> Output folder structure:
> ```
> <DRAFTS_DIR>/
> +-- _index.md
> +-- mkdocs-nav.yml
> +-- docs/
>     +-- <concept-name>.md
>     +-- <procedure-name>.md
>     +-- <reference-name>.md
> ```
>
> Save pages to: `<DOCS_DIR>/`
> Create nav fragment at: `<DRAFTS_DIR>/mkdocs-nav.yml`
> Create index at: `<DRAFTS_DIR>/_index.md`

### Output verification

Check that `<DRAFTS_DIR>/_index.md` exists. The `output_file` passed to `complete-stage` is the `_index.md` path (not the directory), since `complete-stage` requires a file that exists. The `_index.md` serves as the manifest for the entire drafts directory.

## Stage 4: `docs-workflow-tech-review`

**Location**: `plugins/docs-tools/skills/docs-workflow-tech-review/docs-workflow-tech-review.md`

This is the most complex stage skill because it owns the review-fix iteration loop.

### Agent dispatch (reviewer)

- **subagent_type**: `docs-tools:technical-reviewer` (refers to `agents/technical-reviewer.md`)
- **description**: `Technical review of documentation for <TICKET>`

### Agent dispatch (writer fix)

- **subagent_type**: `docs-tools:docs-writer` (refers to `agents/docs-writer.md`)
- **description**: `Fix technical issues for <TICKET>`

**Note on `subagent_type`**: Throughout this spec, `subagent_type` values reference agent definitions in `agents/*.md`, not skills. This matches the Claude Code Agent tool convention where `subagent_type` loads agent markdown files as the subagent's system instructions.

### Output path

```bash
.claude/docs/drafts/<ticket>/_technical_review.md
```

### Inputs from state

- `stages.writing.output_file` — used to derive `DRAFTS_DIR`
- `stages.technical_review.iterations` — current iteration count

### Iteration logic

```
MAX_ITERATIONS = 3

Loop:
  1. Dispatch technical-reviewer agent
     Prompt:
       > Perform a technical review of the documentation drafts for ticket <TICKET>.
       > Source drafts location: <DRAFTS_DIR>/
       > Review all .adoc and .md files. Follow your standard review methodology.
       > Save your review report to: <TECH_REVIEW_FILE>

  2. Increment iteration counter
     workflow_state.py set $TICKET '.stages.technical_review.iterations += 1'

  3. Read TECH_REVIEW_FILE, check Overall technical confidence

  4. Branch:
     - HIGH → mark completed, return
     - MEDIUM or LOW, iterations < MAX_ITERATIONS →
         Dispatch docs-writer agent to fix:
           > The technical reviewer found issues in the documentation for ticket <TICKET>.
           > Read the technical review report at: <TECH_REVIEW_FILE>
           > Address all Critical issues and Significant issues.
           > Edit draft files in place at <DRAFTS_DIR>/.
           > Do NOT address minor issues or style concerns.
         Loop back to step 1.
     - MEDIUM or LOW, iterations >= MAX_ITERATIONS →
         Mark completed with note that manual review is recommended, return
```

### State updates

- `stages.technical_review.iterations` incremented after each reviewer dispatch
- On resume, the iteration count is preserved — the workflow continues rather than restarting

## Stage 5: `docs-workflow-style-review`

**Location**: `plugins/docs-tools/skills/docs-workflow-style-review/docs-workflow-style-review.md`

### Agent dispatch

- **subagent_type**: `docs-tools:docs-reviewer`
- **description**: `Review documentation for <TICKET>`

### Output path

```bash
.claude/docs/drafts/<ticket>/_review_report.md
```

### Inputs from state

- `options.format` — determines which review skills to include in the prompt

### Prompt branching

**AsciiDoc prompt** includes these skill lists:

- Vale linting: `vale-tools:lint-with-vale`
- Red Hat docs: `docs-tools:docs-review-modular-docs`, `docs-tools:docs-review-content-quality`
- IBM Style Guide: `ibm-sg-audience-and-medium`, `ibm-sg-language-and-grammar`, `ibm-sg-punctuation`, `ibm-sg-numbers-and-measurement`, `ibm-sg-structure-and-format`, `ibm-sg-references`, `ibm-sg-technical-elements`, `ibm-sg-legal-information`
- Red Hat SSG: `rh-ssg-grammar-and-language`, `rh-ssg-formatting`, `rh-ssg-structure`, `rh-ssg-technical-examples`, `rh-ssg-gui-and-links`, `rh-ssg-legal-and-support`, `rh-ssg-accessibility`, `rh-ssg-release-notes` (if applicable)

**MkDocs prompt** omits `docs-review-modular-docs` (AsciiDoc-specific) and `rh-ssg-release-notes`.

### Prompt structure

> Review the [AsciiDoc|MkDocs Markdown] documentation drafts for ticket `<TICKET>`.
>
> Source drafts location: `<DRAFTS_DIR>/`
>
> **Edit files in place** in the drafts folder. Do NOT create copies.
>
> For each file:
> 1. Run Vale linting once
> 2. Fix obvious errors where the fix is clear and unambiguous
> 3. Run documentation review skills: [skill list based on format]
> 4. Skip ambiguous issues that require broader context
>
> Save the review report to: `<DRAFTS_DIR>/_review_report.md`
>
> The report must include:
> - Summary of files reviewed
> - Vale linting results (errors, warnings, suggestions)
> - Issues found by each review skill (with file:line references)
> - Fixes applied
> - Remaining issues requiring manual review

## Stage 6: `docs-workflow-integrate`

**Location**: `plugins/docs-tools/skills/docs-workflow-integrate/docs-workflow-integrate.md`

### Step 0: Precondition check

Per the stage skill lifecycle contract, this check runs before `start-stage`:

```bash
INTEGRATE=$(workflow_state.py get $TICKET '.options.integrate')
```

If `integrate` is not `true`, skip this stage entirely (return, do not update state). In orchestrated mode, `next-stage` already skips this stage — this is defense-in-depth for standalone invocation.

### Agent dispatch

- **subagent_type**: `docs-tools:docs-integrator`
- **description**: `Plan integration of documentation for <TICKET>` (PLAN phase) or `Execute integration of documentation for <TICKET>` (EXECUTE phase)

### Output paths

```bash
.claude/docs/drafts/<ticket>/_integration_plan.md
.claude/docs/drafts/<ticket>/_integration_report.md
```

### Phase state machine

```
Read current phase from state:
  workflow_state.py get $TICKET '.stages.integrate.phase // "null"'

Phase dispatch:

  null (first entry):
    1. Mark in_progress
    2. Dispatch docs-integrator with "Phase: PLAN"
       Prompt:
         > Phase: PLAN
         > Plan the integration of documentation drafts for ticket <TICKET>.
         > Drafts location: <DRAFTS_DIR>/
         > Save the integration plan to: <INTEGRATION_PLAN_FILE>
    3. Verify _integration_plan.md exists
    4. Set phase to "awaiting_confirmation"
    5. Fall through to awaiting_confirmation

  awaiting_confirmation:
    1. Read _integration_plan.md
    2. Present summary: detected build framework, file count, operations table, conflicts
    3. Ask user via AskUserQuestion: "Shall I proceed with the integration? (yes/no)"
    4. Wait for response
    5. YES → set phase to "confirmed", fall through
    6. NO → set phase to "declined", fall through

  confirmed:
    1. Dispatch docs-integrator with "Phase: EXECUTE"
       Prompt:
         > Phase: EXECUTE
         > Execute the integration plan for ticket <TICKET>.
         > Drafts location: <DRAFTS_DIR>/
         > Integration plan: <INTEGRATION_PLAN_FILE>
         > Save the integration report to: <INTEGRATION_REPORT_FILE>
    2. Verify _integration_report.md exists
    3. Mark stage completed with report file as output

  declined:
    1. Mark stage completed with plan file as output
    2. Inform user the plan is saved for manual reference
```

## Stage 7: `docs-workflow-create-jira`

**Location**: `plugins/docs-tools/skills/docs-workflow-create-jira/docs-workflow-create-jira.md`

The largest stage skill. Does not dispatch an agent — uses direct Bash/curl/Python.

### Step 0: Precondition check

Per the stage skill lifecycle contract, this check runs before `start-stage`:

```bash
CREATE_JIRA_PROJ=$(workflow_state.py get $TICKET '.options.create_jira_project')
```

If null or empty, skip (return, do not update state). In orchestrated mode, `next-stage` already skips this stage — this is defense-in-depth for standalone invocation.

### Inputs from state

- `options.create_jira_project` — target JIRA project key
- `stages.planning.output_file` — documentation plan to extract description sections and attach

### Step-by-step logic

```
Step 1: Check for existing "is documented by" link
  - Fetch parent ticket's issuelinks via JIRA REST API
  - Check for link type "Document" with inwardIssue
  - If found: mark completed with note, STOP (no duplicate)

Step 2: Check project visibility
  - Unauthenticated curl to /rest/api/2/project/<PROJECT>
  - HTTP 200 → public (do NOT attach detailed plan)
  - Other status → private (attach plan)

Step 3: Extract description from documentation plan
  - Read the planning stage output file
  - Extract 3 sections:
    1. "## What is the main JTBD?..."
    2. "## How does the JTBD(s) relate to..."
    3. "## Who can provide information..."
  - Append footer with date and AI attribution
  - Footer varies: private mentions "attached markdown file", public does not

Step 4: Convert markdown to JIRA wiki markup
  - Python inline script handles: headings, bold, code, links, tables, numbered lists, horizontal rules
  - Write converted text to temp file

Step 5: Create JIRA ticket
  - Build JSON payload via Python (proper escaping)
  - POST to /rest/api/2/issue
  - Summary: "[ccs] Docs - <parent_summary>"
  - Issue type: Story
  - Component: Documentation
  - Verify response contains a key

Step 6: Link to parent ticket
  - POST to /rest/api/2/issueLink
  - Type: "Document" (singular, not "Documents")
  - outwardIssue: parent ticket (shows "documents")
  - inwardIssue: new ticket (shows "is documented by")

Step 7: Attach docs plan (private projects only)
  - Skip if project is public
  - POST to /rest/api/2/issue/<NEW_KEY>/attachments with plan file

Step 8: Update state
  - Mark stage completed with JIRA URL as output_file
```

## Hook Scripts (Optional Enhancement)

Hooks are user-configured in `settings.json`, not baked into the plugin. The plugin README documents them as optional setup for power users.

### Pre-flight validation hook

**Event**: `PreToolUse` (matcher: `Agent`)
**Script**: `workflow_preflight.sh`

```bash
# Only act if a docs-workflow state file exists and is in_progress
STATE_FILES=$(ls .claude/docs/workflow/workflow_*.json 2>/dev/null)
if [[ -z "$STATE_FILES" ]]; then exit 0; fi

for f in $STATE_FILES; do
    STATUS=$(python3 -c "import json; print(json.load(open('$f'))['status'])")
    if [[ "$STATUS" == "in_progress" ]]; then
        # Validate JIRA_AUTH_TOKEN is still set
        if [[ -z "${JIRA_AUTH_TOKEN:-}" ]]; then
            echo "WARNING: JIRA_AUTH_TOKEN is not set. Source ~/.env before continuing."
        fi
    fi
done
```

### Progress display hook

**Event**: `Stop`
**Script**: `workflow_progress.sh`

```bash
# Only act if a docs-workflow state file exists and is in_progress
STATE_FILES=$(ls .claude/docs/workflow/workflow_*.json 2>/dev/null)
if [[ -z "$STATE_FILES" ]]; then exit 0; fi

for f in $STATE_FILES; do
    STATUS=$(python3 -c "import json; print(json.load(open('$f'))['status'])")
    if [[ "$STATUS" == "in_progress" ]]; then
        python3 ${CLAUDE_PLUGIN_ROOT}/skills/docs-workflow/scripts/workflow_state.py status \
            $(python3 -c "import json; print(json.load(open('$f'))['ticket'])")
    fi
done
```

### Example settings.json configuration

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Agent",
        "command": "bash plugins/docs-tools/skills/docs-workflow/hooks/workflow_preflight.sh"
      }
    ],
    "Stop": [
      {
        "command": "bash plugins/docs-tools/skills/docs-workflow/hooks/workflow_progress.sh"
      }
    ]
  }
}
```

## Data Flow

```
User: Skill: docs-tools:docs-workflow, args: "start PROJ-123 --pr <url>"

  docs-workflow (orchestrator)
    |
    +-- Parse args, validate tokens
    +-- workflow_state.py init PROJ-123 --pr <url>
    |
    +-- Loop:
    |     workflow_state.py next-stage → "requirements"
    |     |
    |     +-- Skill: docs-workflow-requirements PROJ-123 $STATE
    |     |     +-- workflow_state.py start-stage ... requirements
    |     |     +-- Agent: requirements-analyst
    |     |     |     +-- writes requirements_proj_123.md
    |     |     +-- workflow_state.py complete-stage ... requirements
    |     |
    |     workflow_state.py next-stage → "planning"
    |     |
    |     +-- Skill: docs-workflow-planning PROJ-123 $STATE
    |     |     +-- reads requirements output from state
    |     |     +-- Agent: docs-planner
    |     |     |     +-- writes plan_proj_123.md
    |     |     +-- workflow_state.py complete-stage ... planning
    |     |
    |     workflow_state.py next-stage → "writing"
    |     |
    |     +-- Skill: docs-workflow-writing PROJ-123 $STATE
    |     |     +-- reads plan output from state
    |     |     +-- Agent: docs-writer
    |     |     |     +-- writes drafts/<ticket>/
    |     |     +-- workflow_state.py complete-stage ... writing
    |     |
    |     workflow_state.py next-stage → "technical_review"
    |     |
    |     +-- Skill: docs-workflow-tech-review PROJ-123 $STATE
    |     |     +-- Agent: technical-reviewer (iterate up to 3x)
    |     |     +-- Agent: docs-writer (fix issues if needed)
    |     |     +-- workflow_state.py complete-stage ... technical_review
    |     |
    |     workflow_state.py next-stage → "review"
    |     |
    |     +-- Skill: docs-workflow-style-review PROJ-123 $STATE
    |     |     +-- Agent: docs-reviewer
    |     |     +-- workflow_state.py complete-stage ... review
    |     |
    |     workflow_state.py next-stage → "done" (or integrate/create_jira if flagged)
    |
    +-- workflow_state.py complete-workflow PROJ-123
    +-- Display completion summary
```

## Migration Path

The decomposition can be done incrementally. Each step is independently shippable.

### Step 1: Create `workflow_state.py`

Extract all jq/state manipulation into the Python script. Test standalone:

```bash
python3 workflow_state.py init TEST-1 --pr https://example.com/pr/1
python3 workflow_state.py status TEST-1
python3 workflow_state.py start-stage TEST-1 requirements
python3 workflow_state.py next-stage TEST-1
python3 workflow_state.py complete-stage TEST-1 requirements /tmp/test.md
python3 workflow_state.py next-stage TEST-1
```

### Step 2: Extract `docs-workflow-create-jira`

Most self-contained stage (~160 lines, all bash/curl/Python, no agent dispatch). Move the JIRA creation logic (steps 1-8 from the Stage 7 section of this spec) verbatim. Verify by running the full workflow with the new skill handling the JIRA stage.

### Step 3: Extract `docs-workflow-integrate`

Second most self-contained — phase state machine, two agent dispatches, user confirmation. Move the phase dispatch logic verbatim.

### Step 4: Extract remaining stages

Extract in order: `docs-workflow-requirements`, `docs-workflow-planning`, `docs-workflow-writing`, `docs-workflow-style-review`, `docs-workflow-tech-review`.

### Step 5: Build thin orchestrator

Once all stages are extracted, write the new `docs-workflow.md` orchestrator skill with the dispatch loop.

### Step 6: Delete the command

Remove `commands/docs-workflow.md`. Update `marketplace.json` to register the new skills and deregister the command. Update any documentation references.

### Step 7: Add hook scripts (optional)

Create hook scripts and document them in the plugin README.

## Testing

### State script unit tests

Test `workflow_state.py` commands in isolation:

- `init` creates valid JSON with all required fields
- `next-stage` skips conditional stages correctly
- `complete-stage` finds fallback files when primary path is missing
- `set` handles dotpath assignment and increment
- Atomic writes don't corrupt state on interruption

### Stage skill integration tests

For each stage skill, verify:

- Standalone invocation creates/loads state automatically
- Agent is dispatched with correct subagent_type
- Output file path matches the state contract
- State is updated correctly on success and failure

### End-to-end test

Run the full orchestrator with a test ticket and verify:

- All stages execute in order
- Resume from each stage works
- Conditional stages (integrate, create-jira) are skipped when not flagged
- Status display shows correct checkmarks at each point

## Multi-Team Customization

The decomposed architecture enables multiple docs teams to modularize and customize the workflow without forking.

### How it works

Since each stage is an independent skill, teams can:

1. **Swap stages** — Replace any `docs-workflow-*` skill with a team-specific version. For example, a team that uses Confluence instead of JIRA can write `docs-workflow-create-confluence` and update their orchestrator to dispatch it instead of `docs-workflow-create-jira`.

2. **Skip stages** — A team that does technical review externally can omit the `technical_review` stage by removing it from their orchestrator's dispatch table, or by never marking it as a required stage in their state init.

3. **Add stages** — A team can add custom stages (e.g., `docs-workflow-localization`, `docs-workflow-legal-review`) by creating new stage skills that follow the interface contract and adding them to their orchestrator's dispatch table.

4. **Override agents** — Since stage skills dispatch agents by `subagent_type`, a team can provide alternate agent definitions (e.g., a `docs-writer.md` tuned for their product's conventions) without changing any skill code.

5. **Customize review skill lists** — The style review stage's prompt contains the list of review skills to apply. A team can fork `docs-workflow-style-review` to use a different set of review skills (e.g., add product-specific terminology checks, remove IBM Style Guide checks).

### Multiple concurrent workflows

The state file convention (`workflow_<safe_ticket>.json`) already supports multiple concurrent workflows — each ticket gets its own state file. A single user can run workflows for different tickets simultaneously, and the `status` action shows progress for any ticket.

### Team-specific orchestrators

For teams with significantly different pipelines, the recommended pattern is:

```
plugins/docs-tools/skills/
  docs-workflow/                    # Default orchestrator (shared)
  docs-workflow-requirements/       # Shared stage skills
  docs-workflow-planning/
  docs-workflow-writing/
  ...

plugins/team-x-docs/skills/
  team-x-workflow/                  # Team X's custom orchestrator
    team-x-workflow.md              # Different stage order, extra stages
    scripts/
      workflow_state.py → symlink   # Reuse shared state script
  team-x-legal-review/             # Team-specific stage
    team-x-legal-review.md
```

Team X's orchestrator can import shared stage skills by fully-qualified name (`docs-tools:docs-workflow-requirements`) while adding its own custom stages (`team-x-docs:team-x-legal-review`). The state script is reused via symlink or by referencing the original path.

### Customization boundaries

| What teams CAN customize | What is shared and stable |
|---|---|
| Which stages run and in what order | State file schema and `workflow_state.py` API |
| Stage prompts and agent parameters | Stage skill lifecycle contract (Step 0-6) |
| Review skill lists | Agent definitions (unless explicitly overridden) |
| Output format and directory structure | State file location convention |
| JIRA project settings and link types | `complete-stage` / `fail-stage` semantics |

The key constraint: all stage skills must use `workflow_state.py` for state management. This ensures that `status`, `resume`, and `next-stage` work correctly regardless of which stages a team has customized.

## Open Questions

1. **Skill-to-skill invocation depth** — When the orchestrator skill invokes a stage skill, and the stage skill dispatches an agent, this is 3 levels deep (orchestrator → stage skill → agent). Need to verify Claude Code handles this nesting correctly.

2. **State file locking** — If a hook and a stage skill both try to update state simultaneously, there could be a race condition. The atomic write in `workflow_state.py` mitigates this, but worth monitoring.

3. **Skill argument passing** — The current `Skill` tool supports `args` as a string. Need to verify that `args: "PROJ-123 /path/to/state.json"` is reliably parsed by each stage skill.

4. **Cross-plugin skill invocation** — For team-specific orchestrators in separate plugins, need to verify that `Skill: docs-tools:docs-workflow-requirements` works correctly when invoked from a different plugin's skill. The `${CLAUDE_PLUGIN_ROOT}` variable resolves to the calling plugin's root, so cross-plugin script references may need absolute paths or a plugin-root-resolution mechanism.
