---
description: Tri quotidien des 3 boites Gmail (gws-pro, gws-klyra, gws-perso) avec drafts auto sur 0-Action
---

# Tri Mail Quotidien — Anthony Gombert

Tu vas trier les emails des 3 comptes Google de l'utilisateur selon son système GTD déjà en place. Tu opères en mode autonome — le user voit le résumé final.

## Comptes (ordre de traitement)

1. **gws-pro** — hello@agmbt.com (pro principal, clients, factures)
2. **gws-klyra** — anthony@klyra.io (Klyra Studio)
3. **gws-perso** — perso@gmail.com (perso, gros volume)

## Workflow par compte

### Étape 1 — Charger les outils

Pour chaque compte, charge ces tools via ToolSearch (un seul call par compte) :
```
select:mcp__gws-{account}__gmail_users_messages_list,mcp__gws-{account}__gmail_users_messages_get,mcp__gws-{account}__gmail_users_messages_batchModify,mcp__gws-{account}__gmail_users_drafts_create,mcp__gws-{account}__gmail_users_labels_list
```

Pour `gws-pro` uniquement, ajoute aussi `mcp__gws-pro__gmail_users_messages_send` (pour l'email récap final).

### Étape 2 — Lister INBOX 24h

```
mcp__gws-{account}__gmail_users_messages_list(params: {"userId": "me", "q": "in:inbox newer_than:1d -subject:\"Tri Mail Récap\"", "maxResults": 50})
```

L'exclusion `-subject:"Tri Mail Récap"` garantit que l'email récap envoyé en fin de run (cf. Étape 6) ne sera jamais re-traité au prochain tri.

Si zéro mail : skip ce compte, passe au suivant.

### Étape 3 — Récupérer headers en parallèle

Pour chaque message, `gmail_users_messages_get` avec :

```
params: {
  "userId": "me",
  "id": "<msgId>",
  "format": "full",
  "fields": "id,threadId,snippet,labelIds,payload/headers"
}
```

Lance toutes les lectures en parallèle.

⚠️ **Important — pourquoi `format: "full"` et pas `metadata`** : le wrapper MCP des serveurs `gws-*` a un bug — en `format: "metadata"`, il **ne propage pas `payload.headers`** dans la réponse, même quand `metadataHeaders` et `fields: "...,payload/headers"` sont explicitement fournis. Résultat : tu te retrouves à classifier sur `snippet` + `labelIds` seuls, sans From/Subject. Vérifié par test direct sur `mcp__gws-klyra__gmail_users_messages_get` le 2026-05-12.

La parade : `format: "full"` **combiné avec `fields: "id,threadId,snippet,labelIds,payload/headers"`**. Le `fields` filtre côté Google API → la réponse contient les headers complets mais **exclut `payload.body` et `payload.parts`**, donc pas de HTML 30-100k. Taille typique : 5-10k par mail (headers DKIM/SPF inclus). Reste léger pour le contexte.

**Ne JAMAIS appeler `format: "full"` sans `fields`** — c'est ce mode-là qui renvoie le body HTML complet et explose le contexte.

Si une réponse dépasse quand même la limite (cas rare : mail avec 50+ headers de routing), passe au mail suivant, laisse-le en INBOX, note-le comme "skipped (réponse API trop grosse)" dans le récap. **N'utilise pas de fichier sauvegardé en fallback.**

Si malgré `format: "full"` + `fields`, `payload.headers` revient vide ou absent (cas pathologique), classifie sur `snippet` + `labelIds` (CATEGORY_PROMOTIONS, CATEGORY_UPDATES sont des signaux forts) : archive si confiance haute, sinon laisse en INBOX + note dans le récap.

### Étape 4 — Classification

**A. AUTO-ARCHIVE** (retirer INBOX, pas de label) si UN de ces critères :
- Header `List-Unsubscribe` présent ET (sender contient "newsletter"/"news"/"updates"/"digest"/"weekly"/"daily")
- Sender = `no-reply@*` / `noreply@*` / `notifications@*` / `mailer-daemon@*` / `notify@*`
- Sender domain ∈ {`github.com`, `linear.app`, `notion.so`, `vercel.com`, `figma.com`, `slack.com`} pour des notifs auto
- Subject contient `[Calendar]` ou `Reminder:` ou `réservation confirmée` ou `payment received` (notif simple)

**B. LABELLISER PUIS ARCHIVER** (retirer INBOX + ajouter label) :
- Factures Stripe/Webflow/SaaS, reçus, "Your receipt" → `3-Factures`
- Notifs paiement bancaire (Qonto, Revolut, Wise) → `_Admin/Finance`
- LinkedIn (notifs ou DMs) → `_LinkedIn`
- Newsletter IA → `_Newsletter/IA`
- Newsletter Web/dev → `_Newsletter/Web`
- Newsletter Nocode → `_Newsletter/Nocode`
- Newsletters autres → `_Newsletter`
- Prospect entrant (lead, demande de devis, "intéressé par vos services") → `_Sales Opportunity`
- Invite meeting/visio (Calendly, Cal.com, Google Calendar invite) → `_Visio`
- Coliving/coworking (Outsite, Selina, etc.) → `_Co-Working/Living`
- Offres d'emploi → `_Offres d'emploi`

**C. LABELLISER ET GARDER VISIBLE** (ne PAS retirer INBOX) :
- Humain attend ma réponse < 2 jours → `0-Action`
- J'attends une réponse (relance, devis envoyé, suivi en cours) → `1-EnAttente`
- Article/doc long à lire, pas urgent → `2-ALire`
- À garder pour référence, pas d'action → `4-Reference`

**Règle d'or** : si tu hésites, laisse en INBOX sans label. Mieux vaut sous-classifier que de mal classer.

### Étape 5 — Drafts sur 0-Action

⚠️ Drafts UNIQUEMENT pour `gws-pro` et `gws-klyra`. Jamais pour `gws-perso` (contexte privé — pas de draft auto sur le compte personnel).

Pour chaque mail nouvellement labellisé `0-Action` :

1. Récupère le contenu du mail avec `format: "full"` **mais en filtrant les attachments via `fields`** pour éviter les réponses trop grosses :

```
params: {
  "userId": "me",
  "id": "<msgId>",
  "format": "full",
  "fields": "id,threadId,payload/headers,payload/body,payload/parts(mimeType,body/data,parts(mimeType,body/data))"
}
```

Si la réponse dépasse quand même la limite (cas rare des mails très longs sans attachments), skip le draft et note dans le récap : "draft non créé — mail trop volumineux".

2. Rédige une réponse en français :
   - **gws-pro** (hello@agmbt.com) : ton pro chaleureux, direct, signature `Anthony`
   - **gws-klyra** (anthony@klyra.io) : voix Klyra Studio, expertise design+nocode, ton concis et confiant, signature `Anthony / Klyra Studio`
3. Crée le draft :
```
mcp__gws-{account}__gmail_users_drafts_create(
  params: {"userId": "me"},
  body: {"message": {"threadId": "<threadId>", "raw": "<base64-encoded-MIME>"}}
)
```

Le `raw` doit être un message MIME RFC 5322 encodé en base64url, avec headers `In-Reply-To`, `References` (depuis le Message-ID original), `To` (sender du mail original), `Subject` (préfixé "Re: " si pas déjà), et le corps en réponse.

**Si tu n'arrives pas à construire un draft propre, skip et note-le dans le résumé.**

### Étape 6 — Email récap (une seule fois, après les 3 comptes)

Une fois les 3 comptes traités, envoie un email récapitulatif depuis `gws-pro` vers `hello@agmbt.com`. C'est un envoi réel (pas un draft) — c'est la seule exception à la règle "jamais d'envoi automatique", parce que c'est un mail à soi-même.

1. Construis un MIME RFC 5322 avec :
   - `From: hello@agmbt.com`
   - `To: hello@agmbt.com`
   - `Subject: 🗂 Tri Mail Récap — {YYYY-MM-DD}` (le préfixe exact `Tri Mail Récap` est obligatoire — c'est lui qui exclut le mail des futurs tris)
   - `Content-Type: text/plain; charset=UTF-8`
   - Corps : le même résumé que celui posté dans le chat (cf. format ci-dessous)

2. Encode en base64url et envoie :
```
mcp__gws-pro__gmail_users_messages_send(
  params: {"userId": "me"},
  body: {"raw": "<base64url-MIME>"}
)
```

Le mail apparaît dans l'INBOX de `gws-pro`. Au prochain `/tri-mail`, il sera filtré par le `-subject:"Tri Mail Récap"` de l'Étape 2.

## Format de l'output final

```
🗂  Tri Mail — {YYYY-MM-DD HH:MM}

▸ gws-pro (hello@agmbt.com) : N emails traités
  ✓ X archivés (bruit)
  ✓ Y labellisés : {breakdown par label}
  ✓ Z drafts créés sur 0-Action
  ⚠ W laissés en INBOX sans label (à toi de voir)

▸ gws-klyra (anthony@klyra.io) : ...
▸ gws-perso (perso@gmail.com) : ...

📬 Top emails 0-Action à traiter (priorité subjective) :
  1. [pro] "Sujet" — de Expéditeur (draft prêt)
  2. [klyra] "Sujet" — de Expéditeur (draft prêt)
  ...

📧 Récap envoyé à hello@agmbt.com
```

Le même contenu est envoyé par email (Étape 6) — chat + inbox `gws-pro`.

## Règles inviolables

1. **Jamais d'envoi automatique** — uniquement des drafts. Seule exception : l'email récap final envoyé à soi-même (`hello@agmbt.com` → `hello@agmbt.com`).
2. **Jamais de suppression** (pas de `messages_trash` ou `messages_delete`).
3. **Si ambigu → laisser en INBOX**, sans label.
4. **gws-perso** : pas de drafts auto.
5. **Idempotence** : si un mail a déjà un label utilisateur (autre que système), ne re-classifie pas — archive juste si pertinent.
