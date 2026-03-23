# docs-tools

!!! tip

    Always run Claude Code from a terminal in the root of the documentation repository you are working on. The docs-tools commands and agents operate on the current working directory, they read local files, check git branches, and write output relative to the repo root.

## Prerequisites

- Install the [Red Hat Docs Agent Tools marketplace](https://redhat-documentation.github.io/redhat-docs-agent-tools/install/)

- [Install GitHub CLI (`gh`)](https://cli.github.com/)

    ```bash
    gh auth login
    ```

- Install system dependencies

    ```bash
    # RHEL/Fedora
    sudo dnf install python3 jq curl
    ```

- [Install gcloud CLI](https://cloud.google.com/sdk/docs/install)

    ```bash
    gcloud auth login --enable-gdrive-access
    ```

- Install Python packages

    ```bash
    python3 -m pip install python-pptx PyGithub python-gitlab jira pyyaml ratelimit requests beautifulsoup4 html2text pip-system-certs
    ```

    The `python-pptx` package is only required for Google Slides conversion. Google Docs and Sheets conversion has no extra dependencies.

- Create an `~/.env` file with your tokens:

    ```bash
    JIRA_AUTH_TOKEN=your_jira_api_token
    # Required for Atlassian Cloud authentication
    JIRA_EMAIL=you@redhat.com
    # Optional: defaults to https://redhat.atlassian.net if not set
    JIRA_URL=https://redhat.atlassian.net
    # Required scopes: "repo" for private repos, "public_repo" for public repos
    GITHUB_TOKEN=your_github_pat
    # Required scope: "api"
    GITLAB_TOKEN=your_gitlab_pat
    ```
    
- Add the following to the end of your `~/.bashrc` (Linux) or `~/.zshrc` (macOS):
    
    ```bash
    if [ -f ~/.env ]; then
        set -a
        source ~/.env
        set +a
    fi
    ```

    Restart your terminal and Claude Code for changes to take effect.

## Customizing the docs workflow

The docs orchestrator (`/docs-tools:docs-orchestrator`) runs a YAML-defined step list. You can customize it per-repo without modifying the plugin.

### Override the workflow steps

The orchestrator looks for workflow YAML in this order:

1. `.claude/docs-<name>.yaml` — if `--workflow <name>` is passed
2. `.claude/docs-workflow.yaml` — project-level default
3. Plugin default — `skills/docs-orchestrator/defaults/docs-workflow.yaml`

To customize, copy the default into your docs repo and edit it:

```bash
mkdir -p .claude
cp $(claude plugin-dir docs-tools)/skills/docs-orchestrator/defaults/docs-workflow.yaml \
   .claude/docs-workflow.yaml
```

Then modify `.claude/docs-workflow.yaml` to add, remove, or reorder steps:

```yaml
workflow:
  name: docs-workflow
  steps:
    - name: requirements
      skill: docs-tools:docs-workflow-requirements
      description: Analyze documentation requirements

    - name: planning
      skill: docs-tools:docs-workflow-planning
      inputs: [requirements]

    # Add a custom step using a local skill
    - name: sme-review
      skill: my-review-skill
      description: Domain-specific review by SME checklist
      inputs: [writing]

    # Remove or skip steps by deleting them from the list
```

### Supplement with local skills

You can reference local standalone skills (from `.claude/skills/`) alongside plugin skills in your workflow YAML. Create a local skill in your docs repo:

```
.claude/skills/my-review-skill/SKILL.md
```

Then reference it by its standalone name in the step list:

```yaml
- name: sme-review
  skill: my-review-skill
  description: Run team-specific review checklist
  inputs: [writing]
```

Local standalone skills use short names (e.g., `my-review-skill`), while plugin skills use fully qualified names (e.g., `docs-tools:docs-workflow-writing`). Both can coexist in the same workflow YAML.

### Conditional steps

Use the `when` field to make steps run only when a CLI flag is passed:

```yaml
- name: create-jira
  skill: docs-tools:docs-workflow-create-jira
  when: create_jira_project
  inputs: [planning]
```

This step only runs when `--create-jira <PROJECT>` is passed to the orchestrator.

### Multiple workflow variants

Use `--workflow <name>` to maintain different workflows for different purposes:

```bash
# Uses .claude/docs-quick.yaml
/docs-tools:docs-orchestrator PROJ-123 --workflow quick

# Uses .claude/docs-full.yaml
/docs-tools:docs-orchestrator PROJ-123 --workflow full
```


