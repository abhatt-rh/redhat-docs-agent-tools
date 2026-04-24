# Red Hat Docs Agent Tools

Follow the shared project conventions in @AGENTS.md for repository structure, skill naming, contributing rules, and general script invocation patterns. The instructions below apply only to Claude Code.

## Coding guidelines

Behavioral rules to reduce common mistakes. These bias toward caution over speed — use judgment for trivial tasks.

### Think before coding

- State assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### Simplicity first

- No features beyond what was asked.
- No duplication of existing functionality.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### Surgical changes

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it — don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: every changed line should trace directly to the user's request.

### Goal-driven execution

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

## Script calls in skills

The runtime working directory is the **project root**, not the skill directory. Bare relative paths like `scripts/foo.py` will fail. Use the appropriate substitution variable:

- **`${CLAUDE_SKILL_DIR}`** — resolves to the directory containing the skill's `SKILL.md`. Use for scripts bundled with the same skill.
- **`${CLAUDE_PLUGIN_ROOT}`** — resolves to the plugin's installation directory. Use for cross-skill calls and hook/MCP/LSP subprocess contexts.

```bash
# Same-skill call (skill invoking its own script)
python3 ${CLAUDE_SKILL_DIR}/scripts/git_pr_reader.py info <url> --json

# Cross-skill call (skill invoking another skill's script)
ruby ${CLAUDE_PLUGIN_ROOT}/skills/dita-callouts/scripts/callouts.rb "$file"
bash ${CLAUDE_PLUGIN_ROOT}/skills/dita-includes/scripts/find_includes.sh "$file"
```

**Note for Cursor users:** If you use Cursor instead of Claude Code, see [AGENTS.md](AGENTS.md) for workspace-relative path guidance.

## Referencing files from agents and skills

`@` references (e.g., `@plugins/docs-tools/reference/file.md`) are a **user input feature** resolved by the Claude Code CLI when typing in the chat prompt. They are NOT resolved inside agent or skill body text — the body becomes the system prompt verbatim.

**In skills (SKILL.md):** Use relative markdown links for progressive disclosure. Claude follows these by reading the files on demand:

```markdown
See [FORMS.md](FORMS.md) for the complete guide
See [reference/finance.md](reference/finance.md) for revenue metrics
```

**In agents (subagents):** Use `${CLAUDE_PLUGIN_ROOT}` paths with explicit Read instructions. Agent bodies become system prompts where markdown links are not auto-resolved:

```markdown
## CRITICAL: Mandatory reference loading

Read: ${CLAUDE_PLUGIN_ROOT}/reference/jtbd-framework.md
Read: ${CLAUDE_PLUGIN_ROOT}/reference/asciidoc-reference.md

If either file cannot be read, STOP and report the error.
```

**Reference files** under `plugins/<name>/reference/` contain domain knowledge (frameworks, templates, style guides) shared across agents. Agents MUST read them at runtime via the Read tool — they are not automatically injected.

## Skill logic must live in scripts

Skills that contain procedural logic — argument parsing, mode determination, input validation, path computation, directory creation — **must defer that logic to a script** under `skills/<skill-name>/scripts/`. The SKILL.md itself should only contain:

- Frontmatter and description
- Instructions to run the script and capture its output
- Domain knowledge (prompt templates, checklists, review criteria)
- Agent dispatch instructions referencing the script's output
- Output verification

Do NOT embed procedural logic (conditionals, path construction, validation) inline in SKILL.md. If a skill needs to make decisions before dispatching an agent, those decisions belong in a script that emits structured output (typically JSON on stdout, errors on stderr).

## Workflow step skills must write step-result.json

All `docs-workflow-*` step skills must write a `step-result.json` sidecar alongside their primary output. This lightweight metadata file lets the orchestrator read structured results without parsing markdown.

- Follow the common schema defined in `plugins/docs-tools/skills/docs-orchestrator/schema/step-result-schema.md`
- Every sidecar must include `schema_version`, `step`, `ticket`, and `completed_at`
- Add step-specific fields as per-step extensions in the schema doc
- Do NOT inline the JSON structure only in the SKILL.md — add the schema entry first, then reference it from the skill's write step
- Verify the sidecar exists in the skill's final verification step

## Authoring skills, agents, and plugins — Anthropic documentation compliance

When creating or modifying skills, agents, hooks, or plugin components, follow the official Anthropic documentation. Do NOT rely on training data for schemas, frontmatter fields, or best practices — use WebFetch to consult the canonical docs listed below before generating any component.

### Canonical documentation references

Before creating any component, consult the relevant page:

| Component | Documentation |
|---|---|
| Skill authoring best practices | https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices.md |
| Skills overview and structure | https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview.md |
| Skills in Claude Code | https://code.claude.com/docs/en/skills.md |
| Plugin schema and reference | https://code.claude.com/docs/en/plugins-reference.md |
| Plugin creation guide | https://code.claude.com/docs/en/plugins.md |
| Subagents | https://code.claude.com/docs/en/sub-agents.md |
| Hooks | https://code.claude.com/docs/en/hooks.md |
| Tools reference | https://code.claude.com/docs/en/tools-reference.md |
| CLAUDE.md and memory | https://code.claude.com/docs/en/memory.md |
| Plugin marketplaces | https://code.claude.com/docs/en/plugin-marketplaces.md |

### Skill files

New skills must use the directory-based format: `skills/<skill-name>/SKILL.md`. The `commands/<name>.md` format is legacy and should not be used for new work. Existing commands continue to work.

For frontmatter fields, content guidelines, string substitution variables, and best practices, consult the canonical docs:
- https://code.claude.com/docs/en/skills.md
- https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview.md
- https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices.md

### Agent files (subagents)

For the full subagent schema (required/optional frontmatter fields), consult https://code.claude.com/docs/en/sub-agents.md

Key behavioral constraints:
- The markdown body becomes the agent's system prompt — agents do NOT receive the full Claude Code system prompt
- `@` references in agent body text are NOT resolved — use `${CLAUDE_PLUGIN_ROOT}` paths with explicit Read instructions instead (see "Referencing files from agents and skills" above)
- Plugin agents cannot use `hooks`, `mcpServers`, or `permissionMode` frontmatter fields (these are ignored for security)
- Subagents cannot spawn other subagents

### Hooks

For valid event names, hook types, exit codes, and matchers, consult https://code.claude.com/docs/en/hooks.md

Project conventions:
- Use `${CLAUDE_PLUGIN_ROOT}` for all script paths in plugin hooks
- Scripts must be executable (`chmod +x`)

### Plugin structure

Required directory layout — components at plugin root, NOT inside `.claude-plugin/`:

```
my-plugin/
├── .claude-plugin/
│   └── plugin.json          # Only manifest here
├── commands/                # At root level
├── skills/                  # At root level (skill-name/SKILL.md)
├── agents/                  # At root level
├── hooks/
│   └── hooks.json           # At root level
├── .mcp.json                # MCP server definitions
├── .lsp.json                # LSP server configurations
└── settings.json            # Default settings
```

For `plugin.json` schema (required/optional fields, component path overrides), consult https://code.claude.com/docs/en/plugins-reference.md

All paths in plugin.json must be relative and start with `./`. Plugins cannot reference files outside their directory (no `../`).

### marketplace.json

For the marketplace schema (required fields, plugin entry format, source types), consult https://code.claude.com/docs/en/plugin-marketplaces.md

Version management: use semver (`MAJOR.MINOR.PATCH`) in `plugin.json` only — do not set version in `marketplace.json`. If version is unchanged, users will not receive updates due to caching.
