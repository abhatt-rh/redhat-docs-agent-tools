# Batch Controller Reference

## repo-info.json schema

Written by `repo-setup.sh` to `artifacts/<ticket>/repo-info.json`:

| Field | Type | Description |
|-------|------|-------------|
| `ticket` | string | Original ticket key (e.g., `VROOM-123`) |
| `jira_project` | string | Extracted project key (e.g., `VROOM`) |
| `repo_url` | string\|null | Target repo URL, or null if no mapping / clone failed |
| `clone_path` | string | Absolute path to local clone (under `.work/`) |
| `branch` | string | Feature branch name (lowercase ticket key) |
| `platform` | string | `github` or `gitlab` |
| `default_branch` | string | Target branch for MR/PR (usually `main`) |
| `format` | string | `mkdocs` or `adoc` |

## publish-info.json schema

Written by `repo-publish.sh` to `artifacts/<ticket>/publish-info.json`:

| Field | Type | Description |
|-------|------|-------------|
| `branch` | string | Feature branch name |
| `commit_sha` | string\|null | Commit SHA if committed, null if skipped |
| `files_committed` | string[] | List of committed file paths (relative to repo root) |
| `platform` | string | `github` or `gitlab` |
| `repo_url` | string | Target repo URL |
| `pushed` | boolean | Whether the branch was pushed to remote |
| `skip_reason` | string | Present only if `pushed` is false |

## Step 2d: MR/PR creation details

> **Note:** MR/PR creation is now handled by `adapters/ambient/scripts/repo-create-mr.sh`. The details below are retained for reference and debugging.

Read `artifacts/<ticket>/publish-info.json`. Only proceed if `pushed` is `true`.

First, check if an MR/PR already exists for the source branch. Re-runs force-push to the same branch, which automatically updates any open MR/PR.

**For GitLab** (`platform` = `gitlab`):

Use the GitLab API with `GITLAB_TOKEN` from `~/.env`. Extract the project path from `repo_url` (URL-encode it for the API).

1. Check for existing MR: `GET /api/v4/projects/<encoded_path>/merge_requests?source_branch=<branch>&state=opened`
2. If an open MR exists: record its URL
3. If no open MR: create via `POST /api/v4/projects/<encoded_path>/merge_requests` with `source_branch`, `target_branch` (from default_branch), `title: "docs(<ticket>): <summary>"`, `description` listing committed files and JIRA link

**For GitHub** (`platform` = `github`):

Use `gh` CLI (authenticates via `GITHUB_TOKEN`):

1. Check: `gh pr list --head "<branch>" --repo "<owner/repo>" --json url`
2. If exists: record URL
3. If not: `gh pr create --repo "<owner/repo>" --head "<branch>" --base "<default_branch>" --title "docs(<ticket>): <summary>" --body "<description>"`

Record the MR/PR URL in the batch summary. If creation fails, log and continue — the branch is already pushed.

## Configuration

| Variable | Purpose | Default |
|----------|---------|---------|
| `DOCS_TRIGGER_LABEL` | Label marking tickets for processing | `ambient-docs-ready` |
| `DOCS_PROCESSING_LABEL` | Label added when ticket is claimed | `ambient-docs-processing` |
| `DOCS_DONE_LABEL` | Label added after success | `ambient-docs-generated` |
| `DOCS_FAILED_LABEL` | Label added after failure | `ambient-docs-failed` |
| `DOCS_JIRA_PROJECT` | Limit to specific JIRA project | — |

## Batch summary format

Write to `artifacts/batch-summary.md`:

```markdown
# Batch Summary

**Date**: YYYY-MM-DD HH:MM UTC
**Tickets processed**: N
**Successful**: X
**Failed**: Y

## Results

| Ticket | Status | Output Path | MR/PR | Notes |
|--------|--------|-------------|-------|-------|
| PROJ-123 | success | artifacts/proj-123/ | <url> | 5 modules written |
| PROJ-456 | failed | — | — | Error: ... |

## Errors

### PROJ-456

<error details>
```
