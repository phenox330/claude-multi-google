# Multi-Account Google Workspace + Slack MCP for Claude Code

Give Claude Code access to Gmail, Google Drive, Calendar, Sheets, Docs, and Slack — with full support for multiple Google accounts (e.g., personal + work).

## Background

**No Claude product supports multiple Google accounts natively.**

- Claude.ai (web), Claude Desktop, and Claude Cowork all have built-in Google Workspace integrations — but **single-account only**. You connect one Gmail, one Drive, and that's it.
- Claude Code has **zero** native Google Workspace integration — single-account or otherwise.

If you juggle several Google accounts (personal + work + side project), you're stuck. As of March 2026, no Anthropic product solves this. There's no official plugin, no documentation, no toggle.

This repo is the result of ~6 hours of research and debugging to get multi-account working end-to-end on Claude Code. The final solution is simple, but getting there required discovering several undocumented behaviors in Claude Code's MCP system, Google's OAuth2 implementation, and the `gws` CLI.

### What makes this hard

It's not one problem — it's a stack of them, each undocumented:

1. **Claude Code silently ignores MCP config in the wrong file.** If you put `mcpServers` in `settings.local.json` (where you'd expect it), servers don't start. No error. No log. You can spend hours restarting and re-checking JSON syntax. The config must go in `.mcp.json` at the project root. ([Claude Code Issue #24477](https://github.com/anthropics/claude-code/issues/24477))

2. **One OAuth client for two Google accounts breaks both.** Google invalidates account A's refresh token when you authenticate account B with the same OAuth client. You need separate OAuth Desktop App clients — one per account — in the same GCP project.

3. **The credential file env var doesn't work.** `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE` is supposed to let you point the [Google Workspace CLI](https://github.com/googleworkspace/cli) at different credential files, but it doesn't reliably route to the right account. You have to mint fresh access tokens and pass them via `GOOGLE_WORKSPACE_CLI_TOKEN` (the highest-priority auth method).

4. **Go binaries use single-dash flags.** Both the `gws` CLI and [`slack-mcp-server`](https://github.com/nichochar/slack-mcp-server) are Go binaries. `--transport stdio` fails silently. It's `-t stdio` — or just omit it (stdio is the default).

5. **MCP servers only start at session launch.** Config changes don't take effect until you restart Claude Code entirely.

Each of these individually cost 30-120 minutes to diagnose. Together they make the setup feel broken when it's actually a solvable configuration problem.

### What we tried and rejected

| Approach | Why It Failed |
|----------|--------------|
| Legacy `google-workspace` Claude Code plugin | Single-account only, port 8000 conflict blocks second instance |
| Single OAuth client for both accounts | Google invalidates first account's refresh token on second auth |
| `CREDENTIALS_FILE` env var per MCP server | Doesn't reliably route to the right account |
| `mcpServers` in `settings.local.json` | Silently ignored — Claude Code never reads MCP config from there |
| `mcpServers` in `.claude/settings.json` | Also silently ignored |
| Service account auth | Can't access personal Gmail/Drive without domain-wide delegation |
| Requesting all 85+ OAuth scopes | Google blocks unverified apps requesting too many scopes |

For the full investigation log, see [docs/research-notes.md](docs/research-notes.md).

## The Solution

The working setup uses:

- **[Google Workspace CLI](https://github.com/googleworkspace/cli)** (`gws` v0.7+) — Google's official CLI with built-in MCP server mode
- **Separate OAuth Desktop clients** — one per Google account, in the same GCP project
- **A token wrapper script** — mints fresh access tokens from each account's credential file, passes them via the highest-priority env var
- **`.mcp.json` at project root** — the only config location Claude Code actually reads for MCP servers
- **[slack-mcp-server](https://github.com/nichochar/slack-mcp-server)** — Go-based Slack MCP, read-only by default

### What you get

| MCP Server | Capabilities |
|------------|-------------|
| `gws-personal` | Gmail, Drive, Calendar, Sheets, Docs for your personal Google account |
| `gws-work` | Same, for your work Google account (optional) |
| `slack` | Read channels, search messages, browse threads, list users |

Once running, Claude Code can search your email, read Drive files, check your calendar, read/write spreadsheets, and search Slack — all through natural language.

## Quick Start

### Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and working
- [Node.js](https://nodejs.org/) 18+ (for `npx`)
- [Python 3](https://www.python.org/) (for token minting — uses only stdlib)
- [gcloud CLI](https://cloud.google.com/sdk/docs/install) (for enabling APIs and IAM)
- A Google account with Gmail/Drive access
- (Optional) A Slack workspace where you can create an app

### AI-Guided Setup

1. **Clone this repo** and open Claude Code in it:
   ```bash
   git clone https://github.com/phenox330/claude-multi-google.git
   cd claude-multi-google
   claude
   ```

2. **Tell Claude Code**: "Set up Google Workspace MCP for me"

   The `CLAUDE.md` in this repo contains machine-readable setup instructions. Claude Code will walk you through each step, prompting you only for browser-based OAuth steps that can't be automated.

3. **Restart Claude Code** to load the new MCP servers.

### Manual Setup

If you prefer step-by-step instructions: [docs/manual-setup.md](docs/manual-setup.md) (English) — or [docs/setup-fr.md](docs/setup-fr.md) (French, with troubleshooting log from a real 3-account setup).

### Full Research Log

To understand every decision and failed approach: [docs/research-notes.md](docs/research-notes.md).

## Architecture

```
Claude Code session start
        │
        ├─── reads .mcp.json (project root)
        │
        ├─── starts gws-personal server:
        │      │
        │      ├── gws-token-wrapper.sh personal.json
        │      │     │
        │      │     ├── reads personal.json (client_id_A + refresh_token)
        │      │     ├── POST https://oauth2.googleapis.com/token → access_token
        │      │     └── exec: GOOGLE_WORKSPACE_CLI_TOKEN=<token> gws mcp -s gmail,drive,...
        │      │
        │      └── gws mcp ←→ Google APIs (Gmail, Drive, Calendar, Sheets, Docs)
        │
        ├─── starts gws-work server:
        │      │
        │      └── (same flow, different credential file with client_id_B)
        │
        └─── starts slack server:
               │
               └── npx slack-mcp-server (SLACK_MCP_XOXP_TOKEN env var)
```

### Why the wrapper script?

The `gws` CLI stores one set of credentials at a time internally. For multiple accounts, we can't rely on its credential file routing (`CREDENTIALS_FILE` env var is unreliable). Instead, we:

1. Read the exported credential file (has `client_id`, `client_secret`, `refresh_token`)
2. Call Google's token endpoint directly to mint a fresh access token
3. Pass it via `GOOGLE_WORKSPACE_CLI_TOKEN` — the highest-priority auth method in the `gws` auth chain

This is 15 lines of shell + Python stdlib. No dependencies.

### Why separate OAuth clients?

OAuth2 Desktop App clients have a behavior where issuing a new refresh token for account B invalidates the existing refresh token for account A — if they share the same `client_id`. Creating separate OAuth Desktop clients in the same GCP project gives each account its own independent token lifecycle.

## Using in Your Own Projects

After setup, you need two things in any project where you want these MCP servers:

1. **`.mcp.json` at the project root** — copy from this repo's template and fill in your paths
2. **`~/.config/gws/`** — credential files + wrapper script (created once during setup, shared across all projects)

Or add the `mcpServers` config to `~/.claude.json` for global access in every project.

**Always gitignore `.mcp.json`** — it contains OAuth tokens.

## Custom Commands

Personal slash commands that build on this MCP setup live in [`commands/`](commands/). See [commands/README.md](commands/README.md) for install instructions.

Notably:
- **`/tri-mail`** — daily triage of multiple Gmail accounts (archive, label, draft replies, recap email)

## Known Gotchas

These are ordered by how much time they'll cost you if you hit them unaware:

| # | Gotcha | Time Cost | Symptom | Fix |
|---|--------|-----------|---------|-----|
| 1 | `mcpServers` in `settings.local.json` is **silently ignored** | 2+ hours | Servers never start, zero errors | Use `.mcp.json` (project root) or `~/.claude.json` (global). [Issue #24477](https://github.com/anthropics/claude-code/issues/24477) |
| 2 | Same OAuth client for two accounts | 1-2 hours | First account stops working after second account authenticates | Create separate OAuth Desktop clients per account |
| 3 | `CREDENTIALS_FILE` env var unreliable | 1 hour | Wrong account's data returned | Use `GOOGLE_WORKSPACE_CLI_TOKEN` via wrapper script |
| 4 | Work account shows "Access blocked" | 30 min | OAuth consent screen blocks non-test users | Add all accounts as test users on OAuth consent screen + grant IAM `serviceUsageConsumer` role |
| 5 | MCP servers only start at session launch | 15 min | Config changes don't take effect | Restart Claude Code after any `.mcp.json` change |
| 6 | Go binaries use single-dash flags | 15 min | `--transport stdio` fails silently | Use `-t stdio` or omit (stdio is default) |
| 7 | Access tokens expire after ~1 hour | 5 min | API calls fail on long sessions | Restart Claude Code for fresh tokens |
| 8 | `gws auth login` opens foreground browser | 5 min | Wrong Chrome profile = wrong account authenticated | Bring correct Chrome profile to front before running |
| 9 | Too many OAuth scopes requested | 10 min | Google blocks unverified app | Use `-s drive,gmail,calendar,sheets,docs` (not all scopes) |

## Caveats

- **Written March 2026** — tested with `gws` CLI v0.7.0 and current Claude Code
- Google and Anthropic will likely make this easier natively — this repo fills the gap until then
- GCP project + OAuth consent screen setup requires manual browser steps (can't be fully automated)
- Access tokens minted at session start expire after ~1 hour — restart for long sessions
- Tested on macOS — Linux should work, Windows untested
- The `gws` CLI is pre-1.0 — flags and auth behavior may change

## References

- [Google Workspace CLI](https://github.com/googleworkspace/cli) — the core tool powering Google Workspace access
- [slack-mcp-server](https://github.com/nichochar/slack-mcp-server) — Slack MCP server
- [Claude Code MCP docs](https://docs.anthropic.com/en/docs/claude-code/mcp) — official MCP server documentation
- [MCP Specification](https://modelcontextprotocol.io/) — the Model Context Protocol spec
- [Google OAuth2 documentation](https://developers.google.com/identity/protocols/oauth2) — OAuth flow and token lifecycle
- [Claude Code Issue #24477](https://github.com/anthropics/claude-code/issues/24477) — `settings.local.json` silent ignore bug

## Contributing

Issues and PRs welcome. If you hit a new gotcha, please open an issue — every undocumented behavior we capture saves someone hours.

## License

MIT

---

Built by [Anthony](https://agmbt.com) at [Klyra Studio](https://klyra.io) — we help teams ship faster with design, no-code, and AI automation. If this saved you hours, that's exactly what Klyra does for clients every day. [Get in touch →](mailto:hello@agmbt.com)
