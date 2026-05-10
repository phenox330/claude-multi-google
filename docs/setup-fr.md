# Setup multi-comptes Google Workspace pour Claude Code

> Documentation complète — installation pas-à-pas, pièges rencontrés, et configuration finale.
> Réalisé le 10 mai 2026 sur macOS pour 3 comptes Google (perso + pro + klyra).

---

## 🎯 Objectif

Connecter **plusieurs comptes Google Workspace** (Gmail, Drive, Calendar, Sheets, Docs) à Claude Code via des serveurs MCP, en évitant le problème classique de l'invalidation des refresh tokens quand on a plusieurs comptes.

**Résultat** : Claude Code peut lire/écrire emails, fichiers Drive, agendas, sheets et docs pour chaque compte indépendamment.

---

## 📋 Prérequis

| Outil | Install | Notes |
|---|---|---|
| Node.js 18+ | `brew install node` | Pour `npx` et `npm install -g` |
| Python 3 | Préinstallé sur macOS | Stdlib uniquement, aucun pip |
| Homebrew | `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` | Pour gcloud |
| Claude Code | https://docs.anthropic.com/en/docs/claude-code | Installé et fonctionnel |
| 1 compte GCP | https://console.cloud.google.com/ | Gratuit pour ce usage |
| N comptes Google | — | 1 par "personnalité" (perso/pro/clients) |

---

## 🚧 Pièges majeurs (lis-les AVANT de te lancer)

Ces problèmes ont coûté ~2-3h à diagnostiquer. Documentés ici pour t'épargner ça.

### Piège 1 : Le repo original cible `gws` v0.7 — la v0.22+ a RETIRÉ le mode MCP

Le repo [claude-code-google-workspace](https://github.com/evolsb/claude-code-google-workspace) repose sur la commande `gws mcp` qui existait dans `@googleworkspace/cli` v0.7.0.

**Cette commande a été supprimée en v0.8.0** (commit dd3fc90).

➡️ **Toujours installer `@googleworkspace/cli@0.7.0` exactement** :
```bash
npm install -g @googleworkspace/cli@0.7.0
```

NE PAS faire `npm install -g @googleworkspace/cli` (qui pull la dernière, qui n'a plus `mcp`).

### Piège 2 : OAuth Desktop ≠ OAuth Web

Quand tu crées un client OAuth dans GCP, il y a 2 types principaux :
- **Application Web** ❌ → nécessite un `redirect_uri` configuré (ne marche pas pour CLI)
- **Application de bureau (Desktop)** ✅ → utilise localhost loopback automatique

Si tu choisis "Application Web", `gws auth login` va échouer avec une erreur OAuth obscure. **Toujours choisir "Desktop app" / "Ordinateur de bureau".**

### Piège 3 : 1 OAuth client = 1 compte Google

Si tu utilises le **même client OAuth** pour 2 comptes Google, Google **invalide automatiquement** le refresh token du premier compte quand tu en authentifies un deuxième. Tu te retrouves obligé de te reconnecter en boucle.

➡️ **Créer 1 client OAuth Desktop par compte Google**, dans le même projet GCP.

### Piège 4 : `~/.claude/settings.local.json` ignore silencieusement `mcpServers`

Si tu mets ta config MCP dans `settings.local.json` (où on s'attendrait à la mettre), Claude Code ne la lira jamais — sans aucune erreur ou warning.

➡️ Il faut écrire dans :
- `.mcp.json` à la racine du projet (pour MCP par projet)
- **OU** `~/.claude.json` clé `mcpServers` (pour MCP global, accessible partout)

Voir [Claude Code Issue #24477](https://github.com/anthropics/claude-code/issues/24477).

### Piège 5 : MCP servers ne démarrent qu'au lancement de session

Modifier `.mcp.json` ou `~/.claude.json` pendant que Claude Code tourne ne fait **rien**. Il faut **quitter complètement et relancer** (`Cmd+Q` puis `claude`).

### Piège 6 : `gws auth login` utilise le browser au premier plan

Si plusieurs comptes Google sont connectés dans ton browser, le sélecteur Google **devrait** apparaître (grâce à `prompt=select_account` dans l'URL). Mais si un seul compte est connecté, Google skip le sélecteur et utilise direct ce compte → tu te retrouves authentifié avec le mauvais compte sans t'en rendre compte.

➡️ **Avant chaque `gws auth login`** : ouvre https://accounts.google.com et vérifie que **le bon compte est connecté** (idéalement le seul).

### Piège 7 : Modes Web vs Desktop dans Claude Code (terminal interactif)

Le mode `! command` de Claude Code ne supporte pas bien les commandes interactives (impossible de coller un code OAuth). Pour `gcloud auth login` ou `gws auth login` : **utilise un vrai terminal séparé** (Terminal.app, iTerm, Ghostty…).

### Piège 8 : `gws auth export` mélange stderr et stdout

Si tu fais `gws auth export --unmasked > creds.json 2>&1`, le fichier va contenir une ligne `Using keyring backend: keyring` AVANT le JSON, ce qui le rend invalide.

➡️ Bonne version : `gws auth export --unmasked > creds.json 2>/dev/null`

---

## 🛠️ Installation pas-à-pas

### 1. Installer les CLIs

```bash
# gws CLI v0.7.0 EXACTEMENT (ne pas mettre @latest)
npm install -g @googleworkspace/cli@0.7.0

# gcloud CLI (~200 MB)
brew install --cask google-cloud-sdk

# Vérifications
gws --version    # Doit afficher : gws 0.7.0
gcloud --version # Doit afficher Google Cloud SDK + numéro
```

### 2. Créer le projet GCP

1. Aller sur https://console.cloud.google.com/projectcreate
2. **Project name** : `gws-mcp-<ton-nom>` (ex: `gws-mcp-klyra`)
3. **Project ID** sera auto-généré (ex: `gws-mcp-klyra-495912`) — **note-le**
4. Cliquer **Create**

### 3. Authentifier gcloud

Dans **un vrai terminal séparé** (pas dans Claude Code) :

```bash
gcloud auth login
gcloud config set project <PROJECT_ID>
```

### 4. Activer les APIs Google

```bash
gcloud services enable \
  gmail.googleapis.com \
  drive.googleapis.com \
  calendar-json.googleapis.com \
  sheets.googleapis.com \
  docs.googleapis.com \
  --project=<PROJECT_ID>
```

### 5. Configurer l'OAuth Consent Screen

Sur GCP Console (interface 2025+, l'OAuth est éclaté en plusieurs onglets) :

**A. Branding (Marque)**
- Lien direct : `https://console.cloud.google.com/auth/branding?project=<PROJECT_ID>`
- App name : libre (ex: "Claude MCP")
- User type : **External** (sauf si workspace org → Internal)
- User support email + Developer contact email : ton email principal

**B. Audience**
- Lien direct : `https://console.cloud.google.com/auth/audience?project=<PROJECT_ID>`
- Publishing status : laisse **Test** (PAS production — éviter le processus de vérification Google)
- Test users → **Ajouter TOUS les emails** que tu veux connecter

**C. Data access** : skip (les scopes sont demandés au login par `gws`)

### 6. Créer N clients OAuth Desktop (1 par compte)

Sur https://console.cloud.google.com/auth/clients?project=<PROJECT_ID> :

Pour chaque compte Google :
1. **+ Créer un client**
2. Type d'application : **Application de bureau** (Desktop app)
3. Nom : `MCP - <nom-compte>` (ex: `MCP - perso`, `MCP - klyra`)
4. **Créer** → cliquer **DOWNLOAD JSON**

Tu devrais avoir N fichiers `client_secret_<random>.apps.googleusercontent.com.json` dans `~/Downloads`.

### 7. Préparer le dossier de config

```bash
mkdir -p ~/.config/gws
```

### 8. Renommer et déplacer les credentials

Tu dois associer chaque JSON téléchargé à son compte. Va sur la page "Clients" de GCP : tu vois un tableau Name + Client ID. Le Client ID est le préfixe du nom de fichier téléchargé.

Pour chaque compte :
```bash
mv ~/Downloads/client_secret_<client_id>.apps.googleusercontent.com.json \
   ~/.config/gws/client_secret_<nom_compte>.json
```

Exemple final :
```
~/.config/gws/
├── client_secret_perso.json
├── client_secret_pro.json
└── client_secret_klyra.json
```

### 9. Authentifier chaque compte (répéter pour chaque)

Pour chaque compte (`<NOM>` = perso, pro, klyra…) :

```bash
# A. Activer le bon client_secret
cp ~/.config/gws/client_secret_<NOM>.json ~/.config/gws/client_secret.json

# B. Logout de la session précédente (si tu as déjà auth un autre compte)
gws auth logout

# C. Login (dans un terminal séparé, pas Claude Code)
gws auth login -s drive,gmail,calendar,sheets,docs
# - Une URL s'affiche → copie-la dans ton browser
# - Sélectionne le BON compte Google
# - "Avancé" → "Continuer vers Claude MCP" (warning normal pour app non-vérifiée)
# - Coche TOUS les scopes → Continuer

# D. Exporter les credentials décryptées vers un fichier dédié
gws auth export --unmasked > ~/.config/gws/<NOM>.json 2>/dev/null

# E. Vérifier
python3 -c "
import json
d = json.load(open('$HOME/.config/gws/<NOM>.json'))
print('client_id:', d['client_id'][:40] + '...')
print('has refresh_token:', 'refresh_token' in d)
"
```

### 10. Installer le token wrapper script

Le script `gws-token-wrapper.sh` mint un access token frais à chaque démarrage de session Claude Code (les access tokens expirent après 1h).

```bash
# Depuis le repo cloné
cp scripts/gws-token-wrapper.sh ~/.config/gws/
chmod +x ~/.config/gws/gws-token-wrapper.sh
```

Contenu du wrapper (15 lignes shell + Python stdlib, zéro dépendance) :
- Lit le fichier credentials (`client_id`, `client_secret`, `refresh_token`)
- POST vers `https://oauth2.googleapis.com/token`
- Récupère un `access_token` valide 1h
- Lance `gws mcp` avec `GOOGLE_WORKSPACE_CLI_TOKEN=<access_token>` (méthode d'auth la plus prioritaire)

### 11. Configurer Claude Code (`~/.claude.json`)

⚠️ **Backup d'abord** :
```bash
cp ~/.claude.json ~/.claude.json.backup-$(date +%Y%m%d-%H%M%S)
```

Ajouter dans la clé `mcpServers` (sans toucher aux serveurs MCP existants) :

```json
{
  "mcpServers": {
    "gws-perso": {
      "command": "/Users/<USER>/.config/gws/gws-token-wrapper.sh",
      "args": [
        "/Users/<USER>/.config/gws/perso.json",
        "-s", "gmail,drive,calendar,sheets,docs"
      ]
    },
    "gws-pro": {
      "command": "/Users/<USER>/.config/gws/gws-token-wrapper.sh",
      "args": [
        "/Users/<USER>/.config/gws/pro.json",
        "-s", "gmail,drive,calendar,sheets,docs"
      ]
    },
    "gws-klyra": {
      "command": "/Users/<USER>/.config/gws/gws-token-wrapper.sh",
      "args": [
        "/Users/<USER>/.config/gws/klyra.json",
        "-s", "gmail,drive,calendar,sheets,docs"
      ]
    }
  }
}
```

Remplacer `<USER>` par ton username macOS (`whoami` te le donne).

### 12. Pré-validation (optionnel mais recommandé)

Avant de restart Claude Code, vérifier que chaque MCP server répond :

```bash
for ACCOUNT in perso pro klyra; do
  RESULT=$(echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}' \
    | ~/.config/gws/gws-token-wrapper.sh ~/.config/gws/${ACCOUNT}.json -s gmail,drive,calendar,sheets,docs 2>&1 | head -1)
  if echo "$RESULT" | grep -q '"serverInfo"'; then
    echo "  $ACCOUNT  ✅ MCP server responds"
  else
    echo "  $ACCOUNT  ❌ FAIL: $RESULT"
  fi
done
```

Si les 3 répondent ✅ → restart Claude Code et tout marchera.

### 13. Restart Claude Code

```bash
# Quitte complètement (Cmd+Q ou /exit)
# Puis relance
claude
```

---

## 🧪 Test

Dans Claude Code, demander :
> *"Liste mes 3 derniers emails depuis le compte perso"*

Claude utilisera `mcp__gws-perso__gmail_users_messages_list` automatiquement.

Pareil pour :
> *"Cherche dans mon Drive Klyra les fichiers contenant 'pricing'"*

---

## 🔄 Re-authentification

Si un compte arrête de marcher (refresh token révoqué, mot de passe changé…) :

```bash
# 1. Réactiver le client de ce compte
cp ~/.config/gws/client_secret_<NOM>.json ~/.config/gws/client_secret.json

# 2. Logout + relogin
gws auth logout
gws auth login -s drive,gmail,calendar,sheets,docs
# (dans le browser : choisir le bon compte)

# 3. Re-exporter
gws auth export --unmasked > ~/.config/gws/<NOM>.json 2>/dev/null

# 4. Restart Claude Code
```

---

## ❓ FAQ

### Combien de comptes max ?

Pas de limite technique stricte. Limites pratiques :
- **Performance contexte Claude** : chaque compte charge ~50 outils MCP (Gmail+Drive+Calendar+Sheets+Docs). À 5+ comptes (250+ outils), la qualité des réponses baisse
- **Quotas GCP** : 100 OAuth clients par projet GCP (large marge)
- **Naming** : nomme bien tes serveurs MCP (`gws-clientX` pas `gws-1`) pour que Claude sache lequel appeler

➡️ Recommandation : 1-3 comptes "permanents" + activer/désactiver les comptes clients à la demande dans `~/.claude.json`.

### Pourquoi pas Service Account au lieu d'OAuth user ?

Les service accounts Google ne peuvent pas accéder aux comptes Gmail/Drive personnels sans **domain-wide delegation**, qui nécessite Google Workspace Enterprise + setup admin. OAuth user est la seule option pour les comptes perso ou les Google Workspace standards.

### Mes credentials sont-ils en sécurité ?

- `~/.config/gws/*.json` contiennent `refresh_token` + `client_secret` → équivalent d'un mot de passe d'accès Google API
- **Permissions filesystem** : `chmod 600 ~/.config/gws/*.json` recommandé
- **Jamais commit** dans git (`.mcp.json` dans `.gitignore` aussi si projet)
- **Révocation** : https://myaccount.google.com/permissions → tu peux révoquer "Claude MCP" à tout moment, ce qui invalide tous les refresh tokens

### Slack ?

Pas inclus dans ce setup mais facile à ajouter via [`slack-mcp-server`](https://github.com/nichochar/slack-mcp-server). Voir le [README du repo original](https://github.com/evolsb/claude-code-google-workspace#slack-setup-optional) pour la procédure (création Slack App + token `xoxp-`).

---

## 📦 Récap des fichiers créés

```
~/.config/gws/
├── client_secret.json              # Client actif (changé selon le compte authentifié)
├── client_secret_perso.json        # Backup client OAuth perso
├── client_secret_pro.json          # Backup client OAuth pro
├── client_secret_klyra.json        # Backup client OAuth klyra
├── credentials.enc                 # Credentials chiffrées de la dernière auth (interne gws)
├── gws-token-wrapper.sh            # Script wrapper qui mint les tokens
├── perso.json                      # Credentials décryptées perso (utilisées par le wrapper)
├── pro.json                        # Credentials décryptées pro
└── klyra.json                      # Credentials décryptées klyra

~/.claude.json                      # Config Claude Code (modifiée avec mcpServers)
~/.claude.json.backup-<timestamp>   # Backup avant modification
```

---

## 🔮 Pour aller plus loin

### Idées d'évolution

1. **Lead magnet / tutoriel public** : ce guide est complet et reproductible. Possibles formats :
   - Article de blog avec captures d'écran
   - Vidéo YouTube step-by-step
   - GitHub repo "fork amélioré" du repo original (avec script `setup.sh` automatisé qui guide l'user)

2. **Service simplifié de connexion** : automatiser tout le setup en un wizard interactif :
   - Création GCP project via API
   - OAuth flow géré dans une UI
   - Génération automatique du `.mcp.json`
   - Génération du wrapper script avec les bons paths
   - Vente à des freelances/agences qui veulent connecter rapidement leurs comptes Workspace à Claude Code

3. **Améliorer la sécurité** :
   - Utiliser le keyring système au lieu de fichiers JSON décryptés (le wrapper devrait lire `credentials.enc` directement)
   - Rotation automatique des refresh tokens

4. **Multi-machines** : sync chiffré du dossier `~/.config/gws/` entre laptops via 1Password Items / Bitwarden / age-encrypted git

### Liens utiles

- Repo de référence : https://github.com/evolsb/claude-code-google-workspace
- Google Workspace CLI (gws) : https://github.com/googleworkspace/cli
- Slack MCP server : https://github.com/nichochar/slack-mcp-server
- Doc Claude Code MCP : https://docs.anthropic.com/en/docs/claude-code/mcp
- Spec MCP : https://modelcontextprotocol.io/

---

## 📝 Notes contextuelles (ce setup spécifique)

- **Date** : 10 mai 2026
- **Machine** : macOS Darwin 24.6.0 (Apple Silicon)
- **gws CLI** : v0.7.0 (figée — ne pas upgrade vers v0.8+ qui n'a plus `mcp`)
- **Claude Code** : Opus 4.7
- **Comptes Google connectés** : 3 (perso `perso@gmail.com`, pro `hello@agmbt.com`, klyra `anthony@klyra.io`)
- **Projet GCP** : `gws-mcp-claude-495912`
- **Slack** : pas configuré (à faire plus tard si besoin)

Backup de `~/.claude.json` avant modif : `~/.claude.json.backup-20260510-151409`
