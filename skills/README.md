# Skills

This directory ships an AI-agent skill that explains how to use `multipart_resumable` correctly. The skill is in the [Anthropic Skills](https://docs.claude.com/en/docs/agents-and-tools/agent-skills/overview) format (YAML frontmatter + Markdown), and is also compatible with any agent that loads `SKILL.md` files.

## Install (Claude Code)

Per-project (recommended — the skill loads only when you're working in this project):

```bash
mkdir -p .claude/skills
cp -r skills/multipart_resumable .claude/skills/
```

Or globally for all projects on your machine:

```bash
mkdir -p ~/.claude/skills
cp -r skills/multipart_resumable ~/.claude/skills/
```

After copying, restart Claude Code (or run `/skills reload`). The skill auto-triggers when you import `package:multipart_resumable/...` or reference any of its public types.

## Use with Claude Agent SDK

When building agents with `@anthropic-ai/sdk` or the Python SDK, point your agent at this directory in the `skills` parameter:

```python
client.beta.messages.create(
    model="claude-opus-4-7",
    skills=[{"path": "skills/multipart_resumable"}],
    ...
)
```

## Use with other agents

The `SKILL.md` file is plain Markdown — Cursor, Continue, Aider, and other agents that pick up files matching `SKILL*` or `AGENTS*` patterns will use it directly. For agents that prefer a single root-level file, see the package's [`AGENTS.md`](../AGENTS.md).
