# Scope Requirements Audit: Design Spec

**Date:** 2026-04-21
**Branch:** `code-evidence-index-req-check`
**Status:** Approved

---

## Problem

The docs-orchestrator workflow extracts requirements from JIRA, plans modules, and writes documentation, but never validates which requirements are actually implemented in the codebase. This leads to two failure modes:

1. **Gaps** — Implemented features are not documented because the planner didn't recognize their significance in the JIRA description (e.g., control plane architecture, Kueue integration, Python SDK usage in the EvalHub workflow).
2. **Hallucination** — Unimplemented features are documented as if real because the JIRA ticket described aspirational scope (e.g., audit logging, horizontal scaling, GitOps integration in the EvalHub workflow).

The comparison report (`specs/2026-04-16-code-evidence-comparison-report.md`) identifies this gap explicitly: "Requirements are comparable across branches. This is expected — the requirements step runs before code-evidence and is not influenced by it."

## Solution

Add a `scope-req-audit` step between `requirements` and `planning` that queries the code-finder index once per JIRA requirement, classifies each as grounded/partial/absent, and passes evidence annotations to the planning step. The planner then excludes absent requirements (preventing hallucination) and includes grounded requirements with confidence (reducing gaps).

## Data flow

**Current:**
```
requirements → planning → code-evidence → writing
```

**Proposed:**
```
requirements → scope-req-audit → planning → code-evidence → writing
```

The existing `code-evidence` step (post-planning, topic-level, two-pass retrieval for writing) is unchanged. The new step is a lighter, coarser pass focused on existence/absence per requirement, not detailed code snippets.

### Relationship to code-evidence

| Aspect | scope-req-audit (new) | code-evidence (existing) |
|---|---|---|
| Runs after | requirements | planning |
| Query source | REQ items from requirements.md | Topics from plan.md |
| Query count | 1 per requirement (typically 3-12) | 5-15 per plan + pattern queries |
| Retrieval passes | Single (unfiltered) | Two-pass (scoped + unfiltered) |
| Purpose | Existence classification | Detailed snippets for writing |
| Consumer | Planning step | Writing + tech review |

Both use the same `find_evidence.py` script and the same code-finder index. scope-req-audit creates the index on first run; code-evidence reuses the cached index at `{repo}/.vibe2doc/index.db`.

## Design decisions

### Absent requirements are excluded by default

Absent requirements are deferred, not deleted. The plan document contains a "Deferred requirements (no code evidence)" section listing them with recommended actions. The writer skips deferred modules, but the information is preserved for human review.

### No interactive gate

The step annotates and passes — no user prompt, no blocking gate. This keeps the pipeline headless-compatible (CI jobs, ACP). The orchestrator logs a summary line (e.g., "scope-req-audit completed: 8 grounded, 1 partial, 3 absent") for visibility.

### Claude-generated recommended actions

For each partial or absent requirement, Claude generates contextual recommended actions based on the requirement text, what was found (if anything), and discovered repos. A Python script cannot reason about "this looks like a feature in a companion SDK" — LLM judgment is needed.

### Primary repo only

Queries run against the primary source repo only. If a requirement is absent, the recommended actions may suggest checking companion repos (informed by the discovery section), but the step does not auto-clone or query additional repos. Multi-repo querying is a follow-on.

### Conservative classification

The "partial" classification is the safe default for borderline cases. Only requirements with genuinely no signal (top score below 0.25, zero relevant snippets) are classified absent. The bar for exclusion is high to avoid false negatives that would regress documentation coverage.

### Composability preserved

The planning step's use of evidence-status.json is conditional — the prompt addition is only included when the file exists on disk. If scope-req-audit is skipped, not configured, or someone invokes the planning skill standalone, the planner works exactly as it does today. No degradation.

### No regression to code-evidence

scope-req-audit is purely additive. It does not modify, filter, or interfere with the code-evidence step. The worst case (false negative on a borderline requirement) results in a requirement appearing in the plan's deferred section where a human can catch it. The best case prevents hallucinated documentation for unimplemented features.

## Step specification

### Skill location

`plugins/docs-tools/skills/docs-workflow-scope-req-audit/SKILL.md`

### Arguments

- `$1` — JIRA ticket ID (required)
- `--base-path <path>` — Base output path
- `--repo <path>` — Path to source code repository (required, provided by orchestrator)
- `--grounded-threshold <float>` — Minimum top score for grounded classification (default: 0.5)
- `--absent-threshold <float>` — Maximum top score for absent classification (default: 0.25)

### Input

```
<base-path>/requirements/requirements.md
<repo-path>/
```

### Output

```
<base-path>/scope-req-audit/evidence-status.json
<base-path>/scope-req-audit/summary.md
```

### evidence-status.json schema

```json
{
  "ticket": "PROJ-123",
  "repo_path": "/path/to/repo",
  "thresholds": { "grounded": 0.5, "absent": 0.25 },
  "requirements": [
    {
      "id": "REQ-001",
      "title": "CA bundle configuration support",
      "query": "CA bundle configuration implementation",
      "status": "grounded",
      "top_score": 0.87,
      "snippet_count": 4,
      "key_files": ["pkg/controllers/tls_config.go", "api/v1/types.go"],
      "recommended_action": null
    },
    {
      "id": "REQ-002",
      "title": "Custom certificate rotation",
      "query": "certificate rotation implementation",
      "status": "absent",
      "top_score": 0.12,
      "snippet_count": 0,
      "key_files": [],
      "recommended_action": "Feature may not be implemented. eval-hub-sdk (referenced in README.md:42) may contain this functionality. Confirm with SME before documenting."
    },
    {
      "id": "REQ-003",
      "title": "PEM format validation",
      "query": "PEM certificate format validation",
      "status": "partial",
      "top_score": 0.41,
      "snippet_count": 1,
      "key_files": ["pkg/util/cert.go"],
      "recommended_action": "Stub exists but no full implementation found. Flag for SME review."
    }
  ],
  "summary": {
    "grounded": 1,
    "partial": 1,
    "absent": 1,
    "total": 3
  },
  "discovered_repos": [
    {
      "url": "https://github.com/eval-hub/eval-hub-sdk",
      "source": "README.md:42",
      "relevance": "Python SDK referenced in project README"
    }
  ]
}
```

### Execution steps

**Step 1: Parse arguments and validate inputs.**
Extract ticket, `--base-path`, `--repo`, and optional threshold overrides. Verify `requirements.md` and repo path exist.

**Step 2: Discover related repos.**
Scan the source repo's top-level markdown files (README.md, CONTRIBUTING.md, docs/*.md) for GitHub/GitLab repository URLs. Filter out the current repo URL. Store as `discovered_repos` for use in recommended actions.

**Step 3: Parse requirements.**
Read `requirements.md` and extract each requirement's ID, title, and summary using the existing `REQ-NNN: [title]` + `**Summary**:` pattern that the requirements-analyst produces.

**Step 4: Build queries and run batch retrieval.**
Generate one natural-language query per requirement (e.g., REQ "Python SDK support" becomes query "Python SDK client library implementation"). Write the queries to `${OUTPUT_DIR}/queries.json` and call `find_evidence.py` from the code-evidence skill directory (`plugins/docs-tools/skills/docs-workflow-code-evidence/scripts/find_evidence.py`) with `--queries-file` — single-pass, unfiltered. Follow the same code-finder install detection pattern as the code-evidence step (check for `claude_context` module, fall back to `uv run --with code-finder`). This creates the code-finder index on the first query (cached for the later code-evidence step).

**Step 5: Classify results.**
For each requirement, apply threshold-based classification:
- **Grounded:** top score >= grounded threshold (default 0.5) AND 2+ snippets
- **Partial:** top score between absent and grounded thresholds, OR only 1 snippet above grounded threshold
- **Absent:** top score < absent threshold (default 0.25), or empty results

**Step 6: Generate recommended actions.**
For each partial or absent requirement, Claude generates a contextual recommended action based on: the requirement text, what (if anything) was found, and the discovered repos list.

**Step 7: Write output.**
Write `evidence-status.json` and `summary.md` (human-readable version with the same information).

## Workflow YAML change

Insert after requirements, update planning inputs:

```yaml
steps:
  - name: requirements
    skill: docs-tools:docs-workflow-requirements
    description: Analyze documentation requirements

  - name: scope-req-audit
    skill: docs-tools:docs-workflow-scope-req-audit
    description: Classify requirements by code evidence status
    when: has_source_repo
    inputs: [requirements]

  - name: planning
    skill: docs-tools:docs-workflow-planning
    description: Create documentation plan
    inputs: [requirements, scope-req-audit]
```

## Planning step changes

A conditional paragraph is added to the planner dispatch prompt in `docs-workflow-planning/SKILL.md`. It is only included when `evidence-status.json` exists:

> Code evidence status is available at `<base-path>/scope-req-audit/evidence-status.json`. Read it and use the evidence status when making scoping decisions:
>
> - **Grounded** requirements: create full module specifications as normal
> - **Partial** requirements: create module specifications but note what evidence was found and what is missing — flag for SME review
> - **Absent** requirements: do NOT create module specifications. Instead, list them in a "Deferred requirements (no code evidence)" section at the end of the plan, including the recommended action from the evidence status. These may be unimplemented features — documenting them risks fabrication
>
> If `discovered_repos` lists repos that weren't indexed, note them in the deferred section as potential sources for resolving absent requirements.

No changes to the planner agent definition (`docs-planner.md`).

## Orchestrator changes

**Argument construction** — add to the step-specific args section:
```
scope-req-audit: --repo <repo_path> [--grounded-threshold <float>] [--absent-threshold <float>]
```

**Console logging** — after the step completes, log summary counts.

No interactive gate, no new conditions, no iteration loop.

## Files to create and modify

**New:**
- `plugins/docs-tools/skills/docs-workflow-scope-req-audit/SKILL.md`

**Modified:**
- `plugins/docs-tools/skills/docs-orchestrator/defaults/docs-workflow.yaml`
- `plugins/docs-tools/skills/docs-workflow-planning/SKILL.md`
- `plugins/docs-tools/skills/docs-orchestrator/SKILL.md`

**Renamed:**
- `plugins/docs-tools/skills/docs-workflow-scope-audit/` → `plugins/docs-tools/skills/docs-workflow-scope-req-audit/`

**Not modified:**
- `docs-workflow-code-evidence/` — completely untouched
- `docs-workflow-requirements/` — completely untouched
- `docs-workflow-writing/` — completely untouched
- Any agent definitions
- `find_evidence.py` — reused as-is

## Out of scope

- Modifying the requirements-analyst agent itself
- Changing the existing code-evidence step
- Multi-repo querying (follow-on work)
- Feeding evidence status back into requirements (the requirements step is already complete when scope-req-audit runs)
- Auto-cloning discovered repos
