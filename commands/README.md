# Custom Claude Code Commands

Versioned copies of personal slash commands that depend on this repo's MCP setup.

## Available commands

| Command | What it does |
|---------|--------------|
| [`tri-mail.md`](tri-mail.md) | Daily triage of 3 Gmail accounts (gws-pro, gws-klyra, gws-perso) — auto-archives noise, labels by category, drafts replies on `0-Action`, sends a recap email to `hello@agmbt.com` |

## Install on a new machine

Copy the command to your user-level Claude Code commands folder:

```bash
cp commands/tri-mail.md ~/.claude/commands/
```

Restart Claude Code. The command becomes available as `/tri-mail` from any directory.

## Keep in sync (optional)

Instead of copying, symlink so edits in either place reflect everywhere:

```bash
ln -sf "$(pwd)/commands/tri-mail.md" ~/.claude/commands/tri-mail.md
```

Now `~/.claude/commands/tri-mail.md` points to the versioned file in this repo. Edit either path, commit changes from the repo.

## Account names in `tri-mail.md`

The command references MCP server names hardcoded as `gws-pro`, `gws-klyra`, `gws-perso`. If your `.mcp.json` (or user-scope config) uses different names, edit the command accordingly before installing.
