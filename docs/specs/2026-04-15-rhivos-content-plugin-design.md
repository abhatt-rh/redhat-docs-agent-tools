# rhivos-content Plugin Design Spec

**Date:** 2026-04-15
**Status:** Draft
**Authors:** Alex McLeod

## Problem

The RHIVOS 2.0 Core documentation needs to be built from two sources:

1. **Upstream content** from the CentOS Automotive SIG docs (`sig-docs` repo) — ~120 Markdown files using Material for MkDocs, covering AutoSD
2. **Net-new content** defined in a Google Doc skeleton ToC that outlines 8 Doc Titles for the RHIVOS 2.0 Core GA release

The upstream content is structured by feature/technology. The downstream docs must be structured by **Jobs To Be Done (JTBD)** — organized around what the user is trying to accomplish, not what the technology is. The output must be **Red Hat modular AsciiDoc** that passes Red Hat SSG, IBM Style Guide, and Vale style governance.

Each writer on the team is assigned one or more Doc Titles to work on independently.

## Solution

A new `rhivos-content` plugin in the `redhat-docs-agent-tools` marketplace, containing 5 skills that form a modular pipeline:

| Skill | Purpose |
|-------|---------|
| `rhivos-map-upstream` | Parse Google Doc ToC, map topics to upstream sig-docs files |
| `rhivos-fetch-convert` | Fetch upstream Markdown, convert to AsciiDoc with modular docs conventions |
| `rhivos-jtbd-restructure` | Restructure converted content according to JTBD principles |
| `rhivos-quality-review` | Run style governance (Red Hat SSG, IBM SG, Vale, modular docs) |
| `rhivos-workflow` | Orchestrator that chains the above with human review gates |

Each skill can be run independently or as part of the orchestrated workflow. Each produces artifacts that can be reviewed before proceeding.

## Architecture

### Plugin location

```
redhat-docs-agent-tools/
  plugins/
    rhivos-content/                    # NEW PLUGIN
      .claude-plugin/plugin.json
      skills/
        rhivos-map-upstream/SKILL.md
        rhivos-fetch-convert/SKILL.md
        rhivos-fetch-convert/scripts/md2adoc.py
        rhivos-jtbd-restructure/SKILL.md
        rhivos-quality-review/SKILL.md
        rhivos-workflow/SKILL.md
      reference/
        product-attributes.md
        modular-docs-rules.md
      README.md
```

### Dependencies

The plugin invokes skills from sibling plugins that writers already have installed:

- `docs-tools:docs-convert-gdoc-md` — Google Doc reading
- `docs-tools:docs-review-style` — Multi-agent style review
- `docs-tools:docs-review-modular-docs` — Modular docs compliance
- `vale-tools:lint-with-vale` — Vale linting
- `jtbd-tools:jtbd-analyze-adoc` — JTBD extraction from AsciiDoc
- `jtbd-tools:jtbd-compare` — Current vs proposed structure comparison
- `jtbd-tools:jtbd-consolidate` — Stakeholder consolidation report

Writers must install `jtbd-tools` in addition to the existing `docs-tools`, `dita-tools`, and `vale-tools`.

### External dependencies

- **pandoc 3.6.4+** — Base Markdown-to-AsciiDoc conversion engine
- **gcloud CLI** — For Google Docs authentication (already required by `docs-convert-gdoc-md`)
- **Python 3** — For `md2adoc.py` post-processing script

## Skill Designs

### Skill A: `rhivos-map-upstream`

**Invocation:** `/rhivos-content:rhivos-map-upstream "<google-doc-url>" --title "Doc Title" [--sig-docs-path <path>]`

**Inputs:**
- Google Doc URL (the skeleton ToC)
- Doc Title to process (one of the 8 titles in the ToC)
- Path to local sig-docs clone (default: `~/Documents/git-repos/sig-docs`)

**Process:**
1. Invoke `Skill: docs-tools:docs-convert-gdoc-md` to convert GDoc to Markdown
2. Parse the Markdown to extract the hierarchy for the specified Doc Title: topics and sub-topics
3. Read the upstream `mkdocs.yml` to build a map of all upstream files with their nav titles and paths
4. For each downstream topic, search upstream for matching content by:
   - Title similarity against upstream headings and filenames
   - Keyword overlap between topic description and upstream file content
   - File prefix matching (e.g., "Automotive Image Builder" matches `building/proc_*.md`)
5. Infer `content_type` from topic phrasing: "Understand X" -> CONCEPT, "Install X" -> PROCEDURE, "Supported configurations" -> REFERENCE
6. Present the mapping to the writer for review and correction

**Output:** `artifacts/<doc-title-slug>/upstream-mapping.yaml`

```yaml
doc_title: "RHIVOS Image Building"
mappings:
  - downstream_topic: "Understand the RHIVOS image building mechanics"
    content_type: CONCEPT
    upstream_sources:
      - path: docs/building/building_an_os_image.md
        relevance: high
        usage: adapt
      - path: docs/getting-started/about-automotive-image-builder.md
        relevance: high
        usage: adapt
    notes: "Merge these two upstream sources into a single concept module"
  - downstream_topic: "Install the Automotive Image Builder tool"
    content_type: PROCEDURE
    upstream_sources:
      - path: docs/getting-started/proc_installing-automotive-image-builder.md
        relevance: exact
        usage: adapt
    notes: ""
  - downstream_topic: "In-vehicle networking"
    content_type: CONCEPT
    upstream_sources: []
    net_new: true
    notes: "No upstream equivalent - requires SME input"
```

### Skill B: `rhivos-fetch-convert`

**Invocation:** `/rhivos-content:rhivos-fetch-convert <mapping-yaml> [--sig-docs-path <path>]`

**Inputs:**
- The `upstream-mapping.yaml` from Skill A
- Path to local sig-docs clone

**Process:**
1. Read the mapping YAML, filter to entries with `usage: adapt`
2. For each upstream Markdown file:
   a. Run `pandoc -f markdown -t asciidoc` as the base conversion
   b. Run `md2adoc.py` post-processor to handle Material for MkDocs extensions:
      - `===` tabbed content -> labeled sections
      - `!!! note/warning` admonitions -> `[NOTE]` / `[WARNING]` blocks
      - `--8<-- "path"` snippet inclusions -> `include::` directives
      - `/// figure-caption` -> AsciiDoc image macro with title
      - Fenced code blocks with `title=` -> AsciiDoc source blocks with `.Title`
      - Relative Markdown links -> AsciiDoc `xref:` cross-references
      - YAML frontmatter `title:` / `description:` -> AsciiDoc doc title and `[role="_abstract"]` paragraph
   c. Apply Red Hat modular docs conventions:
      - Add `[id="module-name_{context}"]` anchor
      - Add `:_mod-docs-content-type:` attribute from mapping's `content_type`
      - Add `[role="_abstract"]` to opening paragraph
      - Apply file naming: `con_`, `proc_`, `ref_` prefix
      - Substitute product names with attributes: "AutoSD" -> `{ProductName}`, "Automotive Stream Distribution" -> `{ProductName}`
3. For multi-source mappings (merge case), concatenate relevant sections and flag for writer reconciliation

**Output:**
```
artifacts/<doc-title-slug>/
  modules/
    con_<topic>.adoc
    proc_<topic>.adoc
    ref_<topic>.adoc
  conversion-report.md
```

**The `md2adoc.py` script** handles only syntactic post-processing of pandoc output. The skill handles the semantic layer (modular docs, product attributes, file naming).

### Skill C: `rhivos-jtbd-restructure`

**Invocation:** `/rhivos-content:rhivos-jtbd-restructure <doc-title-slug>`

**Inputs:**
- Converted `.adoc` files from Skill B (in `artifacts/<doc-title-slug>/modules/`)
- The `upstream-mapping.yaml` (for downstream intent context)
- The skeleton ToC structure (for target hierarchy)

**Process:**
1. Read converted modules and skeleton ToC
2. Invoke `Skill: jtbd-tools:jtbd-analyze-adoc` to extract JTBD records (job statements, user stories, procedures)
3. Invoke `Skill: jtbd-tools:jtbd-compare` to compare extracted structure against the skeleton ToC hierarchy
4. Restructure content:
   - Reframe headings as job-oriented titles (e.g., "Automotive Image Builder manifests" -> "Defining your image contents with a manifest")
   - Reorder sections to follow JTBD job map stages: Define -> Locate -> Prepare -> Confirm -> Execute -> Monitor -> Modify -> Conclude
   - Split or merge modules where JTBD analysis shows misalignment
   - Add abstract paragraphs with job context: "When [situation], you need to [motivation], so you can [outcome]"
   - Create stub modules for net-new topics with job statement and `TODO: Requires SME input` marker
5. Generate assembly file with `include::` directives in JTBD order
6. Invoke `Skill: jtbd-tools:jtbd-consolidate` to produce a consolidation report

**Output:**
```
artifacts/<doc-title-slug>/
  modules/                                   # Updated/restructured
    con_<topic>.adoc
    proc_<topic>.adoc
    con_<net-new-topic>.adoc                 # Stub
  assemblies/
    assembly_<doc-title>.adoc
  jtbd/
    jtbd-records.jsonl
    jtbd-toc-proposed.md
    jtbd-comparison.md
    jtbd-consolidation-report.md
```

**Constraint:** Restructuring reframes presentation, not technical content. Technical accuracy is preserved.

### Skill D: `rhivos-quality-review`

**Invocation:** `/rhivos-content:rhivos-quality-review <doc-title-slug> [--threshold <N>] [--fix]`

**Inputs:**
- Restructured `.adoc` files from Skill C
- Confidence threshold (default: 80)

**Process:**
1. Run three review passes in parallel (via Agent tool):
   - **Style guide compliance:** `Skill: docs-tools:docs-review-style --local`
   - **Vale linting:** `Skill: vale-tools:lint-with-vale` using the RHIVOS repo's `.vale.ini`
   - **Modular docs compliance:** `Skill: docs-tools:docs-review-modular-docs`
2. Collect and deduplicate issues across all passes
3. Apply RHIVOS-specific checks:
   - Product attribute usage: hardcoded "RHIVOS" or "Red Hat In-Vehicle Operating System" must use `{ProductName}` / `{ProductShortName}`
   - ASIL B content must appear inside admonitions (IMPORTANT, WARNING, NOTE, TIP) or in the module abstract
   - Safety Guidance references must be italicized with underscore delimiters
   - Reusable snippets (`snip_fusa-disclaimer.adoc`, etc.) used where appropriate
4. Filter by confidence threshold
5. Present grouped by severity (error -> warning -> suggestion)

**Modes:**
- Default: report only
- `--fix`: auto-apply fixes at confidence >=65%, prompt interactively for lower
- `--threshold <N>`: adjust confidence cutoff

**Output:**
```
artifacts/<doc-title-slug>/
  quality-review/
    review-report.md
    issues.json
    auto-fixes-applied.md        # If --fix mode
```

### Skill E: `rhivos-workflow` (Orchestrator)

**Invocation:** `/rhivos-content:rhivos-workflow "<google-doc-url>" --title "Doc Title" [--sig-docs-path <path>] [--resume]`

**Process:**
```
Stage 1: MAP    -> rhivos-map-upstream    -> GATE: interactive mapping review
Stage 2: CONVERT -> rhivos-fetch-convert  -> GATE: interactive module review
Stage 3: RESTRUCTURE -> rhivos-jtbd-restructure -> GATE: interactive JTBD review
Stage 4: REVIEW  -> rhivos-quality-review -> GATE: interactive issue triage
Stage 5: PUBLISH -> Copy final modules and assemblies into RHIVOS doc repo
                    (doc/modules/, doc/assemblies/, update master.adoc)
                    Writer commits when satisfied.
```

**Progress tracking:** `artifacts/<doc-title-slug>/workflow-state.json` — enables `--resume` from last completed gate.

**Gates are mandatory and interactive.** No stage runs until the writer approves the previous stage's output. Gates use `AskUserQuestion` to pause execution, present a structured summary, and accept writer decisions — all within a single workflow invocation.

**Publish step** copies files but does NOT commit — the writer retains git control.

#### Interactive gate design

Each gate follows a common interaction loop:

1. **Summarize** — Display a structured overview of the stage output (file counts, confidence levels, flagged items)
2. **Surface** — Highlight items needing attention inline (low-confidence results, warnings, conflicts)
3. **Prompt** — Ask the writer to choose an action via `AskUserQuestion`
4. **Apply** — If the writer requests changes, apply them and re-present the summary
5. **Advance** — On approval, update `workflow-state.json` and proceed to the next stage

The writer can iterate within a gate as many times as needed before approving.

**Gate actions available at every gate:**

| Action | Behavior |
|--------|----------|
| `approve` | Accept the stage output as-is, proceed to next stage |
| `inspect <item>` | Display the full content of a specific artifact (file, mapping entry, issue) |
| `abort` | Stop the workflow; resume later with `--resume` |

**Gate-specific actions and presentation:**

##### Gate 1: MAP

```
[Stage 1: MAP complete]
Mapped 14 topics for "RHIVOS Image Building":
  - 10 high-confidence matches (>80%)
  - 2 low-confidence (flagged below)
  - 2 net-new (no upstream equivalent)

⚠ Low confidence:
  "Configure boot options" → docs/boot/con_boot-overview.md (42%)
  "Validate image integrity" → docs/testing/proc_run-tests.md (38%)

📄 Net-new (will become stubs):
  "In-vehicle networking"
  "RHIVOS compliance matrix"

? Review mapping and continue to CONVERT?
  [approve / inspect <topic> / reassign <topic> <upstream-path> /
   set-type <topic> <CONCEPT|PROCEDURE|REFERENCE> / add-source <topic> <path> / abort]
```

| Action | Behavior |
|--------|----------|
| `reassign <topic> <path>` | Change the upstream source for a topic |
| `set-type <topic> <type>` | Override inferred content type (CONCEPT, PROCEDURE, REFERENCE) |
| `add-source <topic> <path>` | Add an additional upstream source to a topic (multi-source merge) |

Changes are written back to `upstream-mapping.yaml` before proceeding.

##### Gate 2: CONVERT

```
[Stage 2: CONVERT complete]
Converted 12 modules for "RHIVOS Image Building":
  - 8 clean conversions
  - 3 with warnings (MkDocs extensions required manual handling)
  - 1 multi-source merge (flagged for reconciliation)

⚠ Conversion warnings:
  proc_install-aib.adoc: 2 tabbed content blocks converted to labeled sections — verify layout
  con_image-build-mechanics.adoc: snippet inclusion (--8<--) could not resolve path, left as comment
  ref_manifest-options.adoc: 4 inline attributes stripped — review for lost semantics

🔀 Merge required:
  con_image-build-mechanics.adoc: merged from 2 upstream sources — sections marked with
  `// SOURCE: <path>` comments for reconciliation

? Review converted modules and continue to RESTRUCTURE?
  [approve / inspect <file> / reconvert <file> / abort]
```

| Action | Behavior |
|--------|----------|
| `inspect <file>` | Display the full converted AsciiDoc file |
| `reconvert <file>` | Re-run conversion for a specific file (after writer edits the mapping or upstream) |

##### Gate 3: RESTRUCTURE

```
[Stage 3: RESTRUCTURE complete]
Restructured "RHIVOS Image Building" using JTBD framework:
  - 12 modules reframed (3 headings changed, 2 sections reordered)
  - 2 stub modules created for net-new topics
  - 1 module split into 2 (concept + procedure)
  - Assembly file generated: assembly_rhivos-image-building.adoc

📝 Heading rewrites:
  "Automotive Image Builder manifests" → "Defining your image contents with a manifest"
  "Boot options" → "Configuring boot behavior for your target platform"
  "Testing overview" → "Verifying your image before deployment"

📄 Stubs created (require SME input):
  con_in-vehicle-networking.adoc
  ref_rhivos-compliance-matrix.adoc

? Review JTBD restructuring and continue to REVIEW?
  [approve / inspect <file> / reject-reframe <topic> / accept-reframe <topic> /
   view-comparison / view-assembly / abort]
```

| Action | Behavior |
|--------|----------|
| `reject-reframe <topic>` | Revert a specific heading/structure change to the pre-JTBD version |
| `accept-reframe <topic>` | Explicitly confirm a reframe (useful when reviewing one by one) |
| `view-comparison` | Display the full JTBD comparison report (`jtbd-comparison.md`) |
| `view-assembly` | Display the generated assembly file with `include::` directives |

##### Gate 4: REVIEW

```
[Stage 4: REVIEW complete]
Quality review of "RHIVOS Image Building" (14 modules):
  - 3 errors (must fix)
  - 8 warnings
  - 12 suggestions
  - 5 auto-fixable at ≥65% confidence

🔴 Errors:
  proc_install-aib.adoc:12 — Missing [role="_abstract"] on opening paragraph
  con_image-build-mechanics.adoc:45 — Hardcoded "RHIVOS" must use {ProductName}
  ref_manifest-options.adoc:3 — Missing :_mod-docs-content-type: attribute

🟡 Top warnings:
  proc_build-image.adoc:28 — ASIL B reference outside admonition block
  con_boot-config.adoc:15 — "Red Hat In-Vehicle Operating System" should use {ProductShortName}
  ...

? Review issues and continue to PUBLISH?
  [approve / inspect <file> / fix-all / fix <file> / reject-fix <issue-id> /
   set-threshold <N> / abort]
```

| Action | Behavior |
|--------|----------|
| `fix-all` | Apply all auto-fixes at or above the confidence threshold |
| `fix <file>` | Apply auto-fixes for a specific file only |
| `reject-fix <issue-id>` | Exclude a specific issue from auto-fix (mark as writer-will-handle) |
| `set-threshold <N>` | Change confidence threshold and re-filter the issue list |

## Artifact Structure

All intermediate and final outputs are stored under:

```
artifacts/<doc-title-slug>/
  upstream-mapping.yaml
  modules/
  assemblies/
  conversion-report.md
  jtbd/
  quality-review/
  workflow-state.json
```

The `artifacts/` directory is created in the current working directory (typically the writer's RHIVOS doc repo clone). It should be added to `.gitignore`. When skills are run independently (outside the orchestrator), they use the same `artifacts/` convention — the `<doc-title-slug>` subdirectory is the coordination point between skills.

## Installation

Writers install with:

```bash
claude plugin install rhivos-content@redhat-docs-agent-tools
claude plugin install jtbd-tools@redhat-docs-agent-tools   # If not already installed
```

Prerequisites:
- `docs-tools`, `dita-tools`, `vale-tools` already installed (standard for the team)
- `pandoc` installed (`sudo dnf install pandoc` or equivalent)
- `gcloud` CLI authenticated with `--enable-gdrive-access`

## Upstream repo details

- **Repo:** `gitlab.com/CentOS/automotive/sig-docs`
- **Local clone:** `~/Documents/git-repos/sig-docs`
- **Format:** Markdown with Material for MkDocs extensions
- **Structure:** ~120 .md files organized by topic, navigation defined in `mkdocs.yml`
- **File naming:** DITA-inspired prefixes (`con_`, `proc_`, `ref_`)
- **MkDocs extensions to handle:** tabbed content (`===`), admonitions (`!!!`), snippet inclusion (`--8<--`), figure captions (`///`), code block titles, inline attributes

## Google Doc skeleton ToC

- **URL:** `https://docs.google.com/document/d/1gT8C9R7kCpc7AxncbZcRsSJpSlNjGRg21vnPUykJ7yQ/edit`
- **Structure:** 8 Doc Titles (I through VIII) with hierarchical bullet-point topics under each
- **Doc Titles:**
  1. Release notes
  2. RHIVOS Getting Started and Core Concepts
  3. RHIVOS Image Building
  4. Application development and integration
  5. RHIVOS deployment and platform integration
  6. RHIVOS System Maintenance and Optimization
  7. RHIVOS Platform Security
  8. RHIVOS Platform Updates
- **Content mix:** Combination of upstream adaptation and net-new content
- **Note from ToC:** "The content authoring will follow JTBD guidelines"
