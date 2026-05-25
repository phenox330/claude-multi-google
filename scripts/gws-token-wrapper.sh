#!/bin/bash
# Token wrapper for multi-account Google Workspace CLI MCP
#
# Mints a fresh access token, then passes it to `gws mcp` via
# GOOGLE_WORKSPACE_CLI_TOKEN (highest priority in the gws auth chain).
#
# Two auth modes, auto-detected from the credential JSON:
#
#   1. service_account  (Google Workspace accounts you administer)
#      Config: { "mode": "service_account", "sa_key": "/path/sa-key.json",
#                "subject": "user@your-domain.com",
#                "scopes": ["https://www.googleapis.com/auth/gmail.modify", ...] }
#      Uses domain-wide delegation — impersonates `subject`. JWT auth, NEVER
#      subject to RAPT / org reauthentication policies. Does not break over time.
#      Requires `google-auth`:  pip3 install --user google-auth
#      Use this for unattended automation (cron/launchd). See docs/service-account-setup.md
#
#   2. refresh_token  (consumer @gmail.com accounts)
#      Config: { "client_id": "...", "client_secret": "...", "refresh_token": "...",
#                "type": "authorized_user" }
#      Classic OAuth refresh-token grant (Python stdlib only). Domain-wide
#      delegation is not available for consumer accounts, so this is the only option.
#
# Usage: gws-token-wrapper.sh <credential-file.json> [gws mcp args...]
# Example: gws-token-wrapper.sh ~/.config/gws/work.json -s gmail,drive

set -euo pipefail

CREDS_FILE="$1"
shift

if [ ! -f "$CREDS_FILE" ]; then
  echo "Error: Credential file not found: $CREDS_FILE" >&2
  exit 1
fi

TOKEN=$(python3 -c "
import json, sys

with open('$CREDS_FILE') as f:
    d = json.load(f)

# --- Mode 1: service account impersonation (domain-wide delegation) ---
if d.get('mode') == 'service_account' or 'sa_key' in d:
    try:
        from google.oauth2 import service_account
        from google.auth.transport.requests import Request
        creds = service_account.Credentials.from_service_account_file(
            d['sa_key'], scopes=d['scopes'], subject=d['subject'])
        creds.refresh(Request())
        print(creds.token)
    except Exception as e:
        print(f'SA token mint failed for {d.get(\"subject\")}: {e}', file=sys.stderr)
        sys.exit(1)

# --- Mode 2: refresh-token grant (consumer accounts, stdlib only) ---
else:
    import urllib.request, urllib.parse
    try:
        data = urllib.parse.urlencode({
            'client_id': d['client_id'],
            'client_secret': d['client_secret'],
            'refresh_token': d['refresh_token'],
            'grant_type': 'refresh_token',
        }).encode()
        req = urllib.request.Request('https://oauth2.googleapis.com/token', data)
        resp = json.loads(urllib.request.urlopen(req).read())
        print(resp['access_token'])
    except Exception as e:
        print(f'Refresh-token mint failed: {e}', file=sys.stderr)
        sys.exit(1)
" 2>/dev/null)

if [ -z "$TOKEN" ]; then
  echo "Error: Failed to mint access token from $CREDS_FILE" >&2
  exit 1
fi

# Run gws mcp with the minted token (suppressing stderr noise)
exec env GOOGLE_WORKSPACE_CLI_TOKEN="$TOKEN" gws mcp "$@" 2>/dev/null
