#!/bin/bash
# Token wrapper for multi-account Google Workspace CLI MCP
#
# Problem: The gws CLI stores one set of credentials at a time.
# The CREDENTIALS_FILE env var doesn't reliably route to the right account.
#
# Solution: Mint a fresh access token from the exported credential file,
# then pass it via GOOGLE_WORKSPACE_CLI_TOKEN (highest priority in gws auth chain).
#
# Usage: gws-token-wrapper.sh <credential-file.json> [gws mcp args...]
# Example: gws-token-wrapper.sh ~/.config/gws/personal.json -s gmail,drive

set -euo pipefail

CREDS_FILE="$1"
shift

if [ ! -f "$CREDS_FILE" ]; then
  echo "Error: Credential file not found: $CREDS_FILE" >&2
  exit 1
fi

# Mint a fresh access token using the refresh token (Python stdlib only)
TOKEN=$(python3 -c "
import json, urllib.request, urllib.parse, sys

try:
    with open('$CREDS_FILE') as f:
        d = json.load(f)

    data = urllib.parse.urlencode({
        'client_id': d['client_id'],
        'client_secret': d['client_secret'],
        'refresh_token': d['refresh_token'],
        'grant_type': 'refresh_token'
    }).encode()

    req = urllib.request.Request('https://oauth2.googleapis.com/token', data)
    resp = json.loads(urllib.request.urlopen(req).read())
    print(resp['access_token'])
except Exception as e:
    print(f'Token mint failed: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)

if [ -z "$TOKEN" ]; then
  echo "Error: Failed to mint access token from $CREDS_FILE" >&2
  exit 1
fi

# Run gws mcp with the minted token (suppressing stderr noise)
exec env GOOGLE_WORKSPACE_CLI_TOKEN="$TOKEN" gws mcp "$@" 2>/dev/null
