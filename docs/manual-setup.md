# Manual Setup Guide

Step-by-step instructions for setting up Google Workspace + Slack MCP servers in Claude Code without AI assistance.

## Google Workspace MCP

### 1. Install the Google Workspace CLI

```bash
npm install -g @googleworkspace/cli
gws --version  # should be 0.7+
```

### 2. Create a GCP Project

1. Go to https://console.cloud.google.com/projectcreate
2. Name it something like `gws-mcp` (project ID must be globally unique)
3. Note the project ID

### 3. Enable APIs

```bash
gcloud services enable \
  gmail.googleapis.com \
  drive.googleapis.com \
  calendar-json.googleapis.com \
  sheets.googleapis.com \
  docs.googleapis.com \
  --project=YOUR_PROJECT_ID
```

### 4. Configure OAuth Consent Screen

1. Go to: `https://console.cloud.google.com/apis/credentials/consent?project=YOUR_PROJECT_ID`
2. Select **External** user type
3. Fill in:
   - App name: "Claude MCP" (anything works)
   - User support email: your email
   - Developer contact: your email
4. Skip scopes (they're requested at login time)
5. **Add test users**: Add **every Google account** you want to connect
6. Save

### 5. Create OAuth Desktop Client(s)

Go to: `https://console.cloud.google.com/apis/credentials?project=YOUR_PROJECT_ID`

**For each Google account you want to connect:**

1. Click "Create Credentials" → "OAuth client ID"
2. Application type: **Desktop app**
3. Name: something descriptive (e.g., "MCP - personal", "MCP - work")
4. Click "Create"
5. Download the JSON file
6. Save it:
   ```bash
   mkdir -p ~/.config/gws
   # Move the downloaded file:
   mv ~/Downloads/client_secret_*.json ~/.config/gws/client_secret_ACCOUNTNAME.json
   ```

**Why separate clients?** Using the same OAuth client ID for two Google accounts causes the second login to invalidate the first account's refresh token. This is an OAuth2 behavior, not a bug.

### 6. Authenticate Each Account

For each account (e.g., "personal" and "work"):

```bash
# Set this account's client secret as active
cp ~/.config/gws/client_secret_personal.json ~/.config/gws/client_secret.json

# Login — browser will open, sign in with the CORRECT Google account
gws auth login -s drive,gmail,calendar,sheets,docs

# Export the credentials (includes refresh token)
gws auth export --unmasked > ~/.config/gws/personal.json
```

Repeat for each additional account, swapping the client secret file each time.

### 7. Install the Token Wrapper

```bash
cp scripts/gws-token-wrapper.sh ~/.config/gws/gws-token-wrapper.sh
chmod +x ~/.config/gws/gws-token-wrapper.sh
```

**What this does:** The `gws` CLI can only hold one account's credentials at a time. The wrapper script reads the exported credential file, mints a fresh OAuth access token using the refresh token, and passes it to `gws mcp` via the `GOOGLE_WORKSPACE_CLI_TOKEN` environment variable (the highest-priority auth method).

### 8. If Using a Second Account from a Different Google Workspace Domain

The GCP project owner's account works automatically. For accounts on other domains (e.g., a work Google Workspace), you need to grant API access:

```bash
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="user:you@workdomain.com" \
  --role="roles/serviceusage.serviceUsageConsumer"
```

---

## Slack MCP (Optional)

### 1. Create a Slack App

1. Go to https://api.slack.com/apps
2. "Create New App" → "From scratch"
3. Name: "Claude MCP" (anything)
4. Select your workspace

### 2. Configure Scopes

Go to "OAuth & Permissions" → "User Token Scopes" → Add these scopes:

**Required (read-only):**
- `channels:history` — read public channel messages
- `channels:read` — list public channels
- `groups:history` — read private channel messages
- `groups:read` — list private channels
- `im:history` — read DMs
- `im:read` — list DMs
- `mpim:history` — read group DMs
- `mpim:read` — list group DMs
- `search:read` — search messages
- `users:read` — list users
- `users:read.email` — see user emails
- `usergroups:read` — list user groups

**Optional (for posting):**
- `chat:write` — send messages

### 3. Install to Workspace

1. "OAuth & Permissions" → "Install to Workspace"
2. Authorize
3. Copy the **User OAuth Token** (`xoxp-...`)

---

## Configure Claude Code

### Create `.mcp.json`

In the root of the project where you want these MCP servers available, create `.mcp.json`:

```json
{
  "mcpServers": {
    "gws-personal": {
      "command": "/Users/YOUR_USERNAME/.config/gws/gws-token-wrapper.sh",
      "args": [
        "/Users/YOUR_USERNAME/.config/gws/personal.json",
        "-s", "gmail,drive,calendar,sheets,docs"
      ]
    },
    "gws-work": {
      "command": "/Users/YOUR_USERNAME/.config/gws/gws-token-wrapper.sh",
      "args": [
        "/Users/YOUR_USERNAME/.config/gws/work.json",
        "-s", "gmail,drive,calendar,sheets,docs"
      ]
    },
    "slack": {
      "command": "npx",
      "args": ["-y", "slack-mcp-server@latest"],
      "env": {
        "SLACK_MCP_XOXP_TOKEN": "xoxp-your-token-here"
      }
    }
  }
}
```

Replace paths and tokens with your actual values.

### Global Setup (Optional)

To make these available in ALL projects, add the `mcpServers` config to `~/.claude.json` instead.

### Gitignore

**`.mcp.json` contains tokens — never commit it.**

```bash
echo ".mcp.json" >> .gitignore
```

### Restart Claude Code

MCP servers only load at session launch. You must restart after creating/editing `.mcp.json`.

---

## Verify It Works

After restarting Claude Code, test each server:

```
# Gmail — list recent emails
ToolSearch: "+gws gmail messages list"
mcp__gws-personal__gmail_users_messages_list(params: {"userId": "me", "maxResults": 3})

# Drive — search files
ToolSearch: "+gws drive files"
mcp__gws-personal__drive_files_list(params: {"q": "modifiedTime > '2024-01-01'", "pageSize": 5})

# Slack — list channels
ToolSearch: "+slack channels"
mcp__slack__channels_list(channel_types: "public_channel")
```

If tools don't appear in ToolSearch, check:
1. `.mcp.json` is at the project root (not inside `.claude/`)
2. You restarted Claude Code after creating it
3. The wrapper script is executable (`chmod +x`)
4. Credential files exist at the paths specified

---

## Troubleshooting

See the [README](../README.md#known-gotchas) for a full list of known gotchas.

### Common Issues

**"Access blocked" during OAuth login:**
→ Add the Google account as a test user on the OAuth consent screen

**Wrong account's emails showing up:**
→ Each account needs its own OAuth client ID. Check that `client_id` differs between credential files.

**MCP servers not starting (no error):**
→ `mcpServers` in `settings.local.json` is silently ignored. Must be in `.mcp.json` (project root) or `~/.claude.json` (global).

**API calls fail with "permission denied":**
→ For work accounts on a different domain, grant IAM access (see Step 8 above).
→ Also check: `gcloud auth application-default set-quota-project YOUR_PROJECT_ID`
