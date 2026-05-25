# Unattended Automation: Service Account + Domain-Wide Delegation

**Use this when you run Gmail/Workspace automation on a schedule (cron, launchd, CI) against a Google Workspace account you administer — and you're tired of it breaking every few days.**

This is the auth method that *never* needs a manual re-login.

---

## Which auth method should I use?

| Your account | Running interactively? | Running unattended (cron/launchd)? |
|---|---|---|
| **Workspace** (`you@your-company.com`, you're the admin) | refresh-token is fine | ✅ **Service account + DWD** (this guide) |
| **Consumer** (`you@gmail.com`) | refresh-token is fine | refresh-token (DWD not available — see note below) |

> **Why consumer Gmail can't use this:** domain-wide delegation is a Google Workspace feature. A `@gmail.com` account has no domain and no Admin console, so a service account cannot impersonate it. The good news: consumer accounts aren't subject to org reauthentication policies, so their refresh tokens don't get force-expired the way Workspace ones do.

---

## The problem this solves

If you automate a **Workspace** account with the standard OAuth refresh-token flow, it works for a few days, then suddenly every write call fails:

```
invalid_grant / invalid_rapt — "reauth related error"
```

`RAPT` = *ReAuthentication Proof Token*. Google Workspace organizations enforce a **reauthentication / session-control policy** (Admin console → Security → Google Cloud session control). When the session expires, the refresh token is rejected — **and it cannot be renewed without an interactive browser login.** This is by design, not a bug.

It's commonly triggered by the broad `cloud-platform` scope that some CLIs request. You'll find yourself re-running a re-auth script every ~1–7 days. For an unattended job, that means it's broken most of the time.

**The fix:** a service account with domain-wide delegation authenticates via a signed JWT. It is *never* subject to RAPT or session policies. Set it up once; it runs forever.

---

## Prerequisites

- You are a **super-admin** of the Google Workspace domain (e.g., `your-company.com`).
- [`gcloud` CLI](https://cloud.google.com/sdk/docs/install) installed and authenticated as a user with `Owner` (or `Service Account Admin`) on the GCP project.
- Python `google-auth` library:
  ```bash
  pip3 install --user google-auth
  ```

---

## Setup

### 1. Create the service account + key (gcloud)

```bash
PROJECT=your-gcp-project-id

# Enable the APIs you'll use
gcloud services enable iam.googleapis.com gmail.googleapis.com --project=$PROJECT

# Create the service account
gcloud iam service-accounts create tri-mail-bot \
  --project=$PROJECT \
  --display-name="Automation bot (domain-wide delegation)"

SA=tri-mail-bot@$PROJECT.iam.gserviceaccount.com

# Create a JSON key and secure it
mkdir -p ~/.config/gws
gcloud iam service-accounts keys create ~/.config/gws/sa-key.json --iam-account=$SA
chmod 600 ~/.config/gws/sa-key.json

# Get the numeric Client ID you'll authorize in the Admin console
gcloud iam service-accounts describe $SA --project=$PROJECT --format="value(oauth2ClientId)"
```

Note the **numeric Client ID** printed by the last command (a ~21-digit number, e.g. `1234567890987654321`).

### 2. Authorize the service account in the Admin console

This is the only step that must be done in a browser, by a domain super-admin.

Go to **[admin.google.com](https://admin.google.com)** → **Security → Access and data control → API controls → Domain-wide delegation** → **Add new**:

- **Client ID:** the numeric ID from step 1
- **OAuth scopes:** least-privilege list of what your automation actually needs. For Gmail triage (read, label, archive, drafts, send):
  ```
  https://www.googleapis.com/auth/gmail.modify,https://www.googleapis.com/auth/gmail.send
  ```

Click **Authorize**.

> **Multiple domains?** One service account can be authorized in several domains. Repeat this step in each domain's Admin console using the same Client ID and scopes.
>
> **Propagation:** authorization can take a few minutes to take effect.

### 3. Point the account config at the service account

Create one JSON file per Workspace account you impersonate. Example `~/.config/gws/work.json`:

```json
{
  "mode": "service_account",
  "sa_key": "/Users/YOU/.config/gws/sa-key.json",
  "subject": "you@your-company.com",
  "scopes": [
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/gmail.send"
  ]
}
```

- `subject` = the Workspace user the bot acts **as**. The scopes here must be a subset of what you authorized in step 2.
- For a second domain (e.g. `you@other-company.com`), create another file with the same `sa_key` and that domain's `subject`.

### 4. Install the dual-mode wrapper

The [`gws-token-wrapper.sh`](../scripts/gws-token-wrapper.sh) auto-detects the mode: if the config has `sa_key`, it mints an impersonated token via the service account; otherwise it falls back to the refresh-token flow (for consumer accounts).

```bash
cp scripts/gws-token-wrapper.sh ~/.config/gws/gws-token-wrapper.sh
chmod +x ~/.config/gws/gws-token-wrapper.sh
```

Your `.mcp.json` (or `~/.claude.json`) entry is unchanged — it still calls the wrapper with the account file:

```json
"gws-work": {
  "command": "/Users/YOU/.config/gws/gws-token-wrapper.sh",
  "args": ["/Users/YOU/.config/gws/work.json", "-s", "gmail,drive,calendar,sheets,docs"]
}
```

### 5. Test

```bash
python3 - <<'PY'
import json, urllib.request
from google.oauth2 import service_account
from google.auth.transport.requests import Request

d = json.load(open("/Users/YOU/.config/gws/work.json"))
c = service_account.Credentials.from_service_account_file(
    d["sa_key"], scopes=d["scopes"], subject=d["subject"])
c.refresh(Request())
req = urllib.request.Request(
    "https://gmail.googleapis.com/gmail/v1/users/me/profile",
    headers={"Authorization": "Bearer " + c.token})
print("OK:", json.loads(urllib.request.urlopen(req).read())["emailAddress"])
PY
```

Expected: `OK: you@your-company.com`. Restart Claude Code to load the MCP server with the new auth.

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `unauthorized_client: Client is unauthorized...` | DWD not authorized yet, or still propagating | Re-check step 2 (exact Client ID + scopes), wait a few minutes |
| `invalid_scope` / `access_denied` | A scope in your config wasn't authorized in the Admin console | The config `scopes` must be a subset of the DWD-authorized scopes |
| `Precondition check failed` (403) | Impersonating a user outside the domain you authorized | Authorize the SA in *that* user's domain too |
| `ModuleNotFoundError: google` | `google-auth` not installed | `pip3 install --user google-auth` |

---

## Security notes

- The SA key (`sa-key.json`) is a long-lived credential — `chmod 600`, never commit it (it's covered by `.gitignore`).
- Authorize **only the scopes you need** in the Admin console. The service account can impersonate any user in the domain *only for the scopes you grant* — keep that list minimal.
- To revoke everything instantly: delete the DWD entry in the Admin console, or delete the service account key with `gcloud iam service-accounts keys delete`.
