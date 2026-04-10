# Batch Controller

Autonomous batch processor for the Ambient Code Platform. Scrapes JIRA for labeled tickets and runs each through the documentation pipeline.

See [reference.md](reference.md) for JSON schemas, MR/PR creation details, config variables, and batch summary format.

## Step 0: Environment setup

Read the ACP guidelines, then run setup:

```
Read adapters/ambient/CLAUDE.md
```

If the file cannot be read, STOP and report the error.

```bash
bash adapters/ambient/setup.sh
source ~/.env 2>/dev/null
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/.claude}"
```

If setup fails, run `batch-progress.sh abort` and stop the session.

## Step 1: Discover tickets

```bash
TICKETS_JSON="$(bash adapters/ambient/scripts/batch-find-tickets.sh \
  ${DOCS_JIRA_PROJECT:+--jira-project "$DOCS_JIRA_PROJECT"})"
```

This script queries JIRA for both `ambient-docs-ready` and `ambient-docs-processing` labels, then cross-references `batch-progress.json` to filter out already-completed tickets. It returns JSON with four lists: `ready`, `orphaned`, `skipped`, and `all`.

If `all` is empty, write a batch summary, run `batch-progress.sh finish`, and end the session.

## Step 1.5: Claim tickets

For tickets in the `ready` list, swap labels to prevent double-processing:

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/skills/jira-writer/scripts/jira_writer.py \
  --issue <TICKET> \
  --labels-remove ambient-docs-ready \
  --labels-add ambient-docs-processing
```

Skip the label swap for tickets in the `orphaned` list — they already have `ambient-docs-processing` from a previous session that crashed or was interrupted.

Run per-ticket for error isolation. If a claim fails, skip that ticket. This step must complete for all tickets before processing begins.

After claiming, register all tickets (from the `all` list) with the progress tracker:

```bash
bash adapters/ambient/scripts/batch-progress.sh init <TICKET-1> <TICKET-2> ...
```

## Batch progress tracking

`setup.sh` creates `artifacts/batch-progress.json` with `status: "in_progress"` at boot. The stop hook **blocks Claude from stopping** until the batch is explicitly finished. Call `batch-progress.sh` at each pipeline transition:

| Command | When |
|---------|------|
| `init <tickets...>` | After claiming tickets (Step 1.5) |
| `step <N>` | At each sub-step (2a–2f) |
| `ticket-done` | After a ticket succeeds |
| `ticket-failed` | After a ticket fails |
| `finish` | After writing batch summary (Step 3) |
| `abort` | Fatal error — end session early |

## Step 2: Process each ticket

For each claimed ticket, run steps 2a–2g sequentially.

**Working directory:** Steps 2c and 2d run git/gh commands in the cloned target repo, which may change your working directory. Before every `batch-progress.sh` call, ensure you are in the agent-tools repo root:

```bash
cd "${REPO_ROOT}"
```

Verify this resolves to the agent-tools repo (contains `adapters/ambient/`), not a cloned docs repo under `.work/`.

### 2a. Resolve and clone target repo

```bash
bash adapters/ambient/scripts/batch-progress.sh step 2a
bash adapters/ambient/scripts/repo-setup.sh <TICKET-KEY>
```

Read `artifacts/<ticket>/repo-info.json` for `format`, `repo_url`, `clone_path`, and `platform`.

### 2b. Invoke the orchestrator

```bash
bash adapters/ambient/scripts/batch-progress.sh step 2b
```

Resolve orchestrator flags from `repo-info.json`:

```bash
REPO_FLAGS="$(bash adapters/ambient/scripts/resolve-repo-context.sh "<TICKET-KEY>")"
```

Then invoke the orchestrator with the resolved flags:

```
Skill: docs-orchestrator, args: "<TICKET-KEY> --workflow acp ${REPO_FLAGS}"
```

### 2c. Publish changes

```bash
cd "${REPO_ROOT}"
bash adapters/ambient/scripts/batch-progress.sh step 2c
```

Only if `repo_url` is non-null in `repo-info.json`:

```bash
bash adapters/ambient/scripts/repo-publish.sh <TICKET-KEY>
```

Return to the agent-tools repo root after publishing (the script operates in the cloned repo):

```bash
cd "${REPO_ROOT}"
```

### 2d. Create or update MR/PR

```bash
cd "${REPO_ROOT}"
bash adapters/ambient/scripts/batch-progress.sh step 2d
```

Only if `publish-info.json` has `pushed: true`:

```bash
bash adapters/ambient/scripts/repo-create-mr.sh <TICKET-KEY>
```

Read `artifacts/<ticket>/mr-info.json` for the MR/PR URL. Record it for the batch summary. If the script fails, log the error and continue — the branch is already pushed.

Return to the agent-tools repo root:

```bash
cd "${REPO_ROOT}"
```

### 2e. Record the result

```bash
bash adapters/ambient/scripts/batch-progress.sh step 2e
```

Track ticket key, status, MR/PR URL (if created), and any error messages.

### 2f. Update JIRA labels

```bash
bash adapters/ambient/scripts/batch-progress.sh step 2f
```

On success: `--labels-remove ambient-docs-processing --labels-add ambient-docs-generated`
On failure: `--labels-remove ambient-docs-processing --labels-add ambient-docs-failed`

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/skills/jira-writer/scripts/jira_writer.py \
  --issue <TICKET> --labels-remove ambient-docs-processing --labels-add <LABEL>
```

If the label update fails, log the error and continue.

### 2g. Continue to the next ticket

```bash
bash adapters/ambient/scripts/batch-progress.sh ticket-done   # or ticket-failed
```

Do not stop between tickets.

## Step 3: Write batch summary

Write `artifacts/batch-summary.md` (see [reference.md](reference.md) for format), then release the stop hook:

```bash
bash adapters/ambient/scripts/batch-progress.sh finish
```

## Error handling

- **JIRA access fails** (Step 1): Write error summary, run `batch-progress.sh abort`, stop.
- **Label claim fails** (Step 1.5): Skip that ticket — another session likely claimed it.
- **Single ticket fails** (Step 2): Log error, update label to failed, continue to next ticket.
- **Label update fails** (Step 2f): Log warning, continue.
- **Session dies mid-processing**: Tickets retain `ambient-docs-processing`. The next batch session will detect these as orphaned via `batch-find-tickets.sh` and resume processing automatically.
- **No tickets found**: Write summary noting zero tickets, run `batch-progress.sh finish`, end session.
