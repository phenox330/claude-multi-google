# Multi-Account Google Workspace + Slack MCP for Claude Code

Connect Claude Code to your Gmail, Google Drive, Calendar, Sheets, Docs, and Slack — with support for multiple Google accounts.

## The Problem

Claude Code doesn't have built-in Google Workspace integration (unlike Claude Desktop/Cowork). Setting it up yourself involves:

- Google's official [Workspace CLI](https://github.com/googleworkspace/cli) (`gws`) which has an MCP mode
- A GCP project with OAuth consent screen
- Separate OAuth clients per Google account (one client for two accounts **breaks** — refresh tokens invalidate each other)
- A token wrapper script (the `CREDENTIALS_FILE` env var doesn't reliably route to the right account)
- Config in `.mcp.json` at the project root (NOT `settings.local.json` — that's **silently ignored**)

This repo automates what it can and guides you through the rest.

## What You Get

| MCP Server | What It Does |
|------------|-------------|
| `gws-<name>` | Gmail, Drive, Calendar, Sheets, Docs for a Google account |
| `gws-<name2>` | Same, for a second Google account (optional) |
| `slack` | Read channels, search messages, browse threads in a Slack workspace |

Once set up, Claude Code can:
- Search and read your email
- Search and read Google Drive files
- Check your calendar
- Read and write spreadsheets
- Search Slack channels and threads

## Quick Start

### Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and working
- [Node.js](https://nodejs.org/) 18+ (for `npx`)
- [Python 3](https://www.python.org/) (for token minting — uses only stdlib)
- A Google account with Gmail/Drive access
- (Optional) A Slack workspace where you can create an app

### Setup

1. **Clone this repo** and open Claude Code in it:
   ```bash
   git clone https://github.com/YOUR_USERNAME/claude-code-google-workspace.git
   cd claude-code-google-workspace
   claude
   ```

2. **Tell Claude Code**: "Set up Google Workspace MCP for me"

   Claude Code will read the `CLAUDE.md` and walk you through the setup interactively. It will:
   - Install the `gws` CLI
   - Guide you through GCP project creation + OAuth setup (browser steps)
   - Create the token wrapper script
   - Write the `.mcp.json` config
   - Test everything works

3. **Restart Claude Code** to load the new MCP servers.

### Manual Setup

If you prefer to set things up yourself, see [docs/manual-setup.md](docs/manual-setup.md).

## Using in Your Own Projects

After setup, copy two things to any project where you want Google Workspace + Slack access:

1. **`.mcp.json`** — the MCP server config (contains tokens, keep gitignored)
2. **`~/.config/gws/`** — credential files + wrapper script (created once, shared across projects)

Or add the MCP config to `~/.claude.json` for global access across all projects.

## Architecture

```
┌─────────────────┐     ┌──────────────────────┐
│   Claude Code   │────▶│  gws-token-wrapper.sh │
│                 │     │  (mints access token)  │
│                 │     └──────────┬─────────────┘
│                 │                │
│                 │     ┌──────────▼─────────────┐
│                 │     │  gws mcp               │
│                 │     │  (Google Workspace CLI) │
│                 │     └──────────┬─────────────┘
│                 │                │
│                 │     ┌──────────▼─────────────┐
│                 │     │  Google APIs            │
│                 │     │  (Gmail, Drive, etc.)   │
└─────────────────┘     └────────────────────────┘
```

**Why the wrapper?** The `gws` CLI stores one set of credentials at a time. For multiple accounts, we mint a fresh OAuth access token from each account's stored refresh token and pass it via `GOOGLE_WORKSPACE_CLI_TOKEN` (the highest-priority auth method in the `gws` CLI).

**Why separate OAuth clients?** If you use the same OAuth client ID for two Google accounts, logging into account B invalidates account A's refresh token. Each account needs its own OAuth Desktop App client in your GCP project.

## Known Gotchas

| Gotcha | Impact | Fix |
|--------|--------|-----|
| `mcpServers` in `settings.local.json` is **silently ignored** | Servers never start, no error | Use `.mcp.json` (project root) or `~/.claude.json` (global) |
| Same OAuth client for two accounts | Second login invalidates first account's refresh token | Create separate OAuth Desktop clients per account |
| `CREDENTIALS_FILE` env var unreliable | Wrong account's data returned | Use `GOOGLE_WORKSPACE_CLI_TOKEN` via wrapper script |
| MCP servers only start at session launch | Config changes don't take effect | Restart Claude Code after any `.mcp.json` change |
| `gws` CLI uses Go-style single-dash flags | `--transport stdio` fails | Use `-t stdio` or omit (stdio is default) |
| Access tokens expire after ~1 hour | API calls fail on long sessions | Restart Claude Code for fresh tokens |
| Slack MCP `--transport` flag | Double-dash doesn't work (Go binary) | Omit flag entirely (stdio is default) |

## Caveats

- **Written March 2026** — `gws` CLI v0.7, Claude Code may change MCP config format
- Google and Anthropic will likely make this easier natively over time
- GCP project + OAuth consent screen setup requires manual browser steps (can't be fully automated)
- Access tokens minted at session start expire after ~1 hour — restart for long sessions
- This is tested on macOS — Linux should work, Windows untested

## Contributing

Issues and PRs welcome. If you hit a new gotcha, please open an issue so we can add it.

## License

MIT
