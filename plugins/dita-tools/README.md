# dita-tools


!!! tip

    Always run Claude Code from a terminal in the root of the documentation repository you are working on. The dita-tools command operates on the current working directory, reading local files, checking git branches, and writing output relative to the repo root.

!!! warning

    Always validate your reworked content with the [AsciiDocDITA Vale style](https://github.com/jhradilek/asciidoctor-dita-vale) (`vale --config=.vale.ini --glob='*.adoc'`) before submitting a PR/MR for merge. The `/dita-rework` command runs Vale checks during the workflow, but you must confirm that no new issues have been introduced and all reported issues are resolved before merging.

## Prerequisites

- Install the [Red Hat Docs Agent Tools marketplace](https://redhat-documentation.github.io/redhat-docs-agent-tools/install/)

- Install [software dependencies](https://redhat-documentation.github.io/redhat-docs-agent-tools/install/#software-dependencies)

## Suggested workflow

The `dita-rework` command prepares AsciiDoc content for DITA conversion. It operates in three modes: a script-based cleanup pipeline (default), an LLM-guided rewrite mode, and a review mode.

### Command syntax

```
/dita-tools:dita-rework <file.adoc|assembly.adoc> [--rewrite [--no-commit] [--dry-run] [--branch <name>]] [--review]
```

The `<file>` argument is required. It can be a single AsciiDoc module, an assembly file, or a folder of `.adoc` files. If an assembly is provided, all included modules are discovered and processed automatically.

### Modes and switches

| Switch | Mode | Description |
|--------|------|-------------|
| _(none)_ | Default (Phase D) | Script-based rework pipeline. Runs all DITA cleanup skills in sequence against the target file and its includes. Each skill is committed separately. |
| `--rewrite` | Rewrite (Phase W) | LLM-guided rewrite pipeline. Reads each file, reviews Vale AsciiDocDITA issues, and applies targeted fixes using AI. |
| `--review` | Review (Phase R) | Post-rework review. Compares reworked files against the upstream/main branch and produces a diff report. |

#### Rewrite mode options

These switches are only valid when `--rewrite` is also specified:

| Switch | Description |
|--------|-------------|
| `--no-commit` | Skip git commit creation after each file is fixed. |
| `--dry-run` | Show what would be done without modifying any files. |
| `--branch <name>` | Use a custom branch name instead of the auto-generated one. |

### Running the default pipeline

The default mode runs the full suite of DITA cleanup skills in sequence:

```
/dita-tools:dita-rework guides/master.adoc
```

This creates a working branch, discovers all included files, runs a baseline Vale check, and then executes each cleanup skill in order:

1. `dita-content-type` — add or update `:_mod-docs-content-type:` attribute
2. `dita-document-id` — generate missing anchor IDs
3. `dita-callouts` — transform callouts to bullet lists
4. `dita-entity-reference` — replace HTML entities with Unicode
5. `dita-line-break` — remove hard line breaks
6. `dita-related-links` — normalize Additional resources sections
7. `dita-add-shortdesc-abstract` — add missing `[role="_abstract"]` attributes
8. `dita-task-contents` — add missing `.Procedure` block titles
9. `dita-task-step` — fix list continuations in procedure steps
10. `dita-task-title` — remove unsupported block titles from procedures
11. `dita-block-title` — fix unsupported block titles
12. `dita-check-asciidoctor` — validate AsciiDoc syntax

Each skill is committed individually. After all skills run, a final Vale check compares the results against the baseline and a summary is written to `/tmp/dita-rework-pr-summary.md`.

### Running the rewrite pipeline

The rewrite mode uses the LLM to analyze and fix Vale AsciiDocDITA violations file by file:

```
/dita-tools:dita-rework guides/master.adoc --rewrite
```

To preview changes without modifying files:

```
/dita-tools:dita-rework guides/master.adoc --rewrite --dry-run
```

To run on a named branch without auto-committing:

```
/dita-tools:dita-rework guides/master.adoc --rewrite --no-commit --branch my-dita-fixes
```

### Running the review

After reworking content, run the review mode to compare your changes against the upstream branch:

```
/dita-tools:dita-rework guides/master.adoc --review
```

This renders both versions to plain text, generates a diff, and writes a review report to `/tmp/dita-rework-review-report.md`.

### Running with Ralph Loop

For large assemblies with many modules, you can use Ralph Loop to iterate the rewrite pipeline until all Vale issues are resolved. Ralph Loop re-runs the command automatically, checking progress after each iteration and stopping when the completion promise is met or the iteration limit is reached.

```
/ralph-loop:ralph-loop "Run /dita-tools:dita-rewrite on guides/master.adoc including all referenced modules. Fix all Vale AsciiDocDITA rule violations" --completion-promise "0 errors, 0 warnings" --max-iterations 20
```

This tells Ralph Loop to keep running the rewrite workflow until Vale reports zero errors and zero warnings, with a maximum of 20 iterations.

### Typical end-to-end workflow

1. **Rework** — Run the default pipeline to apply script-based fixes:
    ```
    /dita-tools:dita-rework guides/master.adoc
    ```
2. **Rewrite** — Run the rewrite pipeline to fix remaining issues with LLM-guided edits:
    ```
    /dita-tools:dita-rework guides/master.adoc --rewrite
    ```
3. **Validate** — Confirm that all AsciiDocDITA Vale rules pass:
    ```
    vale --config=.vale.ini --glob='*.adoc' guides/
    ```
4. **Review** — Compare your changes against the upstream branch:
    ```
    /dita-tools:dita-rework guides/master.adoc --review
    ```
5. **Submit** — Push the branch and open a PR/MR for merge.
