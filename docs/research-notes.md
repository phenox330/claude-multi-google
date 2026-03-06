# Research Notes: Getting Google Workspace + Slack into Claude Code

This documents the full investigation — what we tried, what failed, what we learned, and why the final solution looks the way it does. Written March 2026.

## The Starting Point

**Goal:** Give Claude Code access to Gmail, Google Drive, Calendar, Sheets, and Docs — for multiple Google accounts (personal + work). Also Slack.

**Context:** Claude Desktop and Claude Cowork have built-in Google Workspace integrations you can enable with a toggle. Claude Code has none. You're on your own.

**What exists:**
- [Google Workspace CLI](https://github.com/googleworkspace/cli) (`gws`) — Google's official CLI for Workspace APIs, includes an MCP server mode (`gws mcp`). Written in Rust, distributed via npm. v0.7.0 as of March 2026.
- [slack-mcp-server](https://github.com/nichochar/slack-mcp-server) — Slack MCP server. Go binary distributed via npm. Supports reading channels, search, threads, unreads. Message posting disabled by default.
- Claude Code's [MCP config system](https://docs.anthropic.com/en/docs/claude-code/mcp) — `.mcp.json` at project root for project-scoped servers, `~/.claude.json` for global servers.
- Legacy `google-workspace` MCP plugin — Python-based, runs on port 8000, single-account only.

## Approach 1: Legacy google-workspace Plugin (Failed for Multi-Account)

The existing `google-workspace` plugin (available in Claude Code's plugin marketplace) works fine for a single Google account. But:

- **Port 8000 conflict:** It runs a local OAuth callback server on port 8000. You can't run two instances for two accounts.
- **No account switching:** There's no way to tell it which account to use per-request.
- **Python OAuth flow:** Uses its own OAuth implementation, separate from Google's official tooling.

**Verdict:** Works for single account, dead end for multi-account.

## Approach 2: Google Workspace CLI as MCP Server (The Right Foundation)

The `gws` CLI has a built-in MCP mode: `gws mcp -s gmail,drive,calendar,sheets,docs`. This is the right tool — it's Google's official CLI, actively maintained, and designed for exactly this.

**Install:**
```bash
npm install -g @googleworkspace/cli
```

**The auth flow:**
1. Create a GCP project with OAuth consent screen
2. Create an OAuth Desktop App client
3. Run `gws auth login -s gmail,drive,calendar,...` — opens browser for consent
4. Credentials stored locally (encrypted)

This worked immediately for one account. The problems started with two accounts.

## Problem 1: One OAuth Client, Two Accounts (Token Invalidation)

**What we tried:** Create one OAuth Desktop client, authenticate account A, export credentials. Then authenticate account B, export credentials. Use different credential files for each MCP server.

**What happened:** After authenticating account B, account A's exported credential file stopped working. API calls returned account B's data regardless of which credential file was specified.

**Root cause:** OAuth2 refresh token invalidation. When a Desktop App client issues a new refresh token (for account B), Google's OAuth infrastructure invalidates the previous refresh token issued by that same client (for account A). This is documented but not obvious — it's a security feature to prevent token accumulation.

**Fix:** Create a **separate OAuth Desktop App client** in the GCP project for each Google account. Each client has its own `client_id` and `client_secret`, so refresh tokens don't interfere.

**Source:** Discovered through trial and error. Google's OAuth docs mention that "a refresh token might stop working" when "the user revokes access" or "the token has not been used for six months," but the cross-account invalidation via shared client_id is less well-documented. See [Google OAuth docs on token expiration](https://developers.google.com/identity/protocols/oauth2#expiration).

## Problem 2: CREDENTIALS_FILE Env Var Doesn't Route Correctly

**What we tried:** Set `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE` to point to different credential files for each account's MCP server.

**What happened:** Both servers returned the same account's data. The env var appeared to be ignored or overridden by the `gws` CLI's internal credential store.

**Root cause:** The `gws` CLI has an internal credential store (`~/.config/gws/`). The `CREDENTIALS_FILE` env var is supposed to override it, but in practice it doesn't reliably determine which account's tokens are used. The CLI may still prefer its internal state.

**Fix:** Use `GOOGLE_WORKSPACE_CLI_TOKEN` instead. This is the **highest-priority** auth method in the `gws` CLI's auth chain. It accepts a raw OAuth access token and bypasses all credential file resolution.

**The auth priority chain in `gws`** (discovered by reading the source):
1. `GOOGLE_WORKSPACE_CLI_TOKEN` — raw access token (highest priority)
2. `GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE` — path to credential file
3. Internal credential store — whatever `gws auth login` last stored

**Solution: Token wrapper script.** A shell script that:
1. Reads the exported credential file (which has `client_id`, `client_secret`, `refresh_token`)
2. Calls Google's token endpoint to mint a fresh access token
3. Passes it via `GOOGLE_WORKSPACE_CLI_TOKEN` to `gws mcp`

This is reliable because each credential file has its own client_id, so token minting always hits the right OAuth client. See `scripts/gws-token-wrapper.sh`.

## Problem 3: settings.local.json Silently Ignores mcpServers (4+ Hours Lost)

This was the single most frustrating issue. No error, no warning, no log entry.

**What we tried:** Added `mcpServers` to `~/.claude/settings.local.json` (the documented location for user-local settings in Claude Code). Restarted Claude Code. MCP servers didn't start.

**What we checked:**
- `ps aux | grep gws` — no processes
- `ps aux | grep slack` — no processes
- Verified JSON syntax was valid
- Tried multiple restart methods
- Confirmed the same config worked when tested manually from the command line

**What we tried next:**
- Moved config to `.claude/settings.json` (project settings) — also didn't work
- Moved config to `~/.claude.json` (user-level config) — **worked**
- Moved config to `.mcp.json` at project root — **worked**

**Root cause:** Claude Code only reads `mcpServers` from two locations:
1. `.mcp.json` at the project root (project-scoped)
2. `~/.claude.json` (user-scoped / global)

The `settings.json` and `settings.local.json` files accept the `mcpServers` key without error (valid JSON, no schema validation), but Claude Code never reads MCP config from those files. The servers simply don't start, and there's no indication why.

**Source:** [Claude Code GitHub Issue #24477](https://github.com/anthropics/claude-code/issues/24477). The confusion is compounded by the fact that `claude mcp add` writes to `~/.claude.json`, not to `settings.local.json`, which is a clue — but not documented.

**Debugging red herring:** One MCP server (`posthog`) appeared to load from `settings.local.json`, which made us think that was the right location. It turned out `posthog` was actually loading from `~/.claude.json` where a previous `claude mcp add` command had written it.

## Problem 4: Too Many OAuth Scopes

**What happened:** Running `gws auth login` without specifying scopes prompted for all 85+ available Google API scopes. Google's consent screen for unverified apps blocks requests with too many scopes.

**Fix:** Specify only the scopes you need: `-s drive,gmail,calendar,sheets,docs` (~10 scopes total). The `gws` CLI maps these short names to the actual OAuth scope URLs.

## Problem 5: "Access Blocked" for Work Accounts

**What happened:** OAuth flow worked for the personal Google account (which owned the GCP project) but showed "Access blocked" for the work Google Workspace account.

**Two fixes needed:**

1. **Add as test user:** On the OAuth consent screen in GCP, add the work email as a test user. Unverified apps only allow explicitly listed test users.

2. **Grant IAM access:** The work account needs permission to use the GCP project's APIs:
   ```bash
   gcloud projects add-iam-policy-binding PROJECT_ID \
     --member="user:work@example.com" \
     --role="roles/serviceusage.serviceUsageConsumer"
   ```

3. **Set quota project:** If `gcloud` ADC is configured, make sure the quota project points to the right GCP project:
   ```bash
   gcloud auth application-default set-quota-project PROJECT_ID
   ```

## Problem 6: Slack MCP Double-Dash Flags

**What happened:** Configured `slack-mcp-server --transport stdio` in the MCP config. Server failed to start.

**Root cause:** `slack-mcp-server` is a Go binary (not Node.js). Go's `flag` package uses single-dash flags: `-t stdio`, not `--transport stdio`.

**Fix:** Either use `-t stdio` or omit the flag entirely (stdio is the default transport).

**Source:** [slack-mcp-server README](https://github.com/nichochar/slack-mcp-server). The Go convention vs Node convention is easy to miss.

## Problem 7: gws CLI Browser Opens Wrong Profile

**What happened:** `gws auth login` opens the default/foreground browser. If you have multiple Chrome profiles, it may open the wrong one, authenticating the wrong Google account.

**Fix:** Before running `gws auth login`, bring the correct Chrome profile window to the foreground. There's no `--browser` or `--profile` flag — the CLI uses the OS default browser handler.

## What We Evaluated But Didn't Use

### Claude Desktop / Cowork Built-in Integration
These have native Google Workspace toggles, but they're different products. Claude Code is CLI-based and has no equivalent built-in integration as of March 2026.

### Google Workspace MCP from Anthropic's Plugin Marketplace
The `google-workspace` plugin works for single accounts but can't do multi-account (port 8000 conflict). The `gws` CLI is Google's official tool and supports MCP natively.

### Service Account Authentication
Could avoid the OAuth dance entirely, but:
- Service accounts can't access personal Gmail/Drive without domain-wide delegation
- Domain-wide delegation requires Google Workspace admin access
- Not practical for personal accounts at all

### API Key Authentication
Google Workspace APIs don't support API key auth for user data. OAuth2 is required.

## Tools and Sources Referenced

| Tool/Source | URL | What It Is |
|-------------|-----|-----------|
| Google Workspace CLI | https://github.com/googleworkspace/cli | Official Google CLI with MCP mode |
| slack-mcp-server | https://github.com/nichochar/slack-mcp-server | Go-based Slack MCP server |
| Claude Code MCP docs | https://docs.anthropic.com/en/docs/claude-code/mcp | How MCP servers work in Claude Code |
| Claude Code Issue #24477 | https://github.com/anthropics/claude-code/issues/24477 | settings.local.json silent ignore bug |
| Google OAuth2 docs | https://developers.google.com/identity/protocols/oauth2 | OAuth flow, token lifecycle |
| Google OAuth token expiration | https://developers.google.com/identity/protocols/oauth2#expiration | When refresh tokens stop working |
| MCP Specification | https://modelcontextprotocol.io/ | The Model Context Protocol spec |

## Architecture Decision: Why a Wrapper Script

We considered several approaches for multi-account support:

1. **Multiple `gws` instances with different credential files** — doesn't work (CREDENTIALS_FILE unreliable)
2. **Multiple `gws` instances with different config directories** — possible but fragile (would need to set `XDG_CONFIG_HOME` per-process)
3. **Token wrapper that mints access tokens** — works reliably, simple, uses only Python stdlib

The wrapper won because:
- It's 15 lines of shell + Python
- Uses only Python stdlib (no pip installs)
- Each invocation gets a fresh token from the right credential file
- `GOOGLE_WORKSPACE_CLI_TOKEN` is the highest-priority auth method, so it always wins
- Tokens are ephemeral (expire in ~1 hour) — no state management needed

The downside: tokens expire after ~1 hour. For long Claude Code sessions, you need to restart to get fresh tokens. This is acceptable because Claude Code sessions typically don't run much longer than that anyway, and the restart is quick.

## Timeline

This setup took approximately 6 hours to get fully working, across two parallel sessions (one for Google Workspace, one for Slack). The bulk of the time was spent on:

1. **~2 hours:** Discovering that `settings.local.json` silently ignores `mcpServers`
2. **~1.5 hours:** Figuring out the OAuth client token invalidation issue
3. **~1 hour:** Working around the `CREDENTIALS_FILE` env var unreliability
4. **~1 hour:** GCP project setup, consent screen, test users, IAM
5. **~30 min:** Slack setup + debugging the Go flag convention

---
*Written March 2026. Versions: gws CLI v0.7.0, Claude Code (current), slack-mcp-server (latest via npx).*
