# wacrm on Railway

A community Railway template for [wacrm][upstream], an open-source CRM for WhatsApp: a shared inbox on
the official WhatsApp Business Platform, contacts, sales pipelines, broadcasts, no-code automations and
an AI reply assistant. It is not affiliated with the wacrm project.

wacrm is built on Supabase and upstream expects you to bring a **Supabase Cloud** project and run its
migrations from your own machine. This template runs **all of it on Railway, in one project**: a
self-hosted Supabase (Postgres, Auth, PostgREST, Realtime, Storage and the Kong gateway), wacrm itself,
and a small scheduler for automations. No Supabase account, nothing to set up first.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/wacrm-supabase)

## What you get

- **Eight services wired over Railway's private network**, with every secret generated at deploy
  time. Two are public: the CRM, and the Supabase gateway the browser talks to.
- **Migrations applied for you.** All of upstream's ordered migrations run on first start, each in its
  own transaction, and upstream's own schema check runs after them. A later release applies only the
  migrations it adds.
- **An owner account before anyone else can reach the app**, created from the e-mail you enter when
  deploying and a generated password.
- **Signup by invitation only.** In upstream wacrm, anyone who finds `/signup` gets a working CRM
  account of their own on your instance, and there is no setting to close it. This template closes it
  in the database: a new user is admitted only with a valid invitation link from inside your account.
  Invited teammates sign up exactly as upstream intends.
- **Automations that run.** Wait steps and flows need something to call wacrm's cron endpoints;
  upstream leaves that to you. A scheduler service does it every minute over the private network.
- An image built from a pinned upstream commit and tested as a whole bundle in CI before it is pushed.

## First run

1. Deploy the template and enter `OWNER_EMAIL`, the address you will sign in with.
2. Wait for the `app` service to go green. The first start applies the migrations, so allow a few
   minutes.
3. Copy `OWNER_PASSWORD` from the `app` service's **Variables** tab and sign in on the app's domain.
   Change the password under **Settings → Login & security**.
4. Connect WhatsApp under **Settings → WhatsApp** with your Meta app's phone number ID, WhatsApp Business
   Account ID, access token and a verify token of your choosing. In the Meta developer console, set the
   webhook to `https://<app-domain>/api/whatsapp/webhook` with that verify token.
5. Set `META_APP_SECRET` (Meta for Developers → App settings → Basic) on the `app` service and redeploy
   it. Until then the app refuses every inbound webhook, because it cannot verify their signatures.
6. Invite teammates from **Settings → Team members**. The invite link is what lets them sign up.

## Services

| Service | What it is | Image | Public | Volume |
|---|---|---|---|---|
| `app` | wacrm | `ghcr.io/youssefsiam38/wacrm-railway-app` | yes | |
| `scheduler` | Calls the automation and flow cron endpoints | `ghcr.io/youssefsiam38/wacrm-railway-scheduler` | | |
| `kong` | Supabase API gateway | `ghcr.io/youssefsiam38/wacrm-railway-kong` | yes | |
| `db` | Supabase Postgres | `ghcr.io/youssefsiam38/wacrm-railway-db` | | `/var/lib/postgresql/data` |
| `auth` | Supabase Auth (GoTrue) | `supabase/gotrue` | | |
| `rest` | PostgREST | `postgrest/postgrest` | | |
| `realtime` | Supabase Realtime | `supabase/realtime` | | |
| `storage` | Supabase Storage | `ghcr.io/youssefsiam38/wacrm-railway-storage` | | `/var/lib/storage` |

See `ARCHITECTURE.md` for how the pieces fit together.

## Variables you may want to change

All on the `app` service unless noted.

| Variable | Default | Meaning |
|---|---|---|
| `OWNER_EMAIL` | asked at deploy | The owner account's e-mail. |
| `OWNER_PASSWORD` | generated | The owner's first password. Read on the first start only. |
| `OWNER_NAME`, `ACCOUNT_NAME` | `Owner`, `My company` | The owner's display name and the account's name. |
| `META_APP_SECRET` | unset | Verifies WhatsApp webhooks. Required before inbound messages work. |
| `META_APP_ID` | unset | Needed only for message templates with an image header. |
| `WACRM_SIGNUP_MODE` | `invite-only` | `open` lets anyone sign up and get their own account. |
| `WACRM_RESET_OWNER_PASSWORD` | unset | Set `true` with a new `OWNER_PASSWORD` to recover the owner; remove afterwards. |
| `WACRM_CRON_INTERVAL` (`scheduler`) | `60` | Seconds between cron calls. |
| `GOTRUE_SMTP_*` (`auth`) | unset | Optional SMTP for password-reset e-mails. |

Upstream's optional settings (`WHATSAPP_TEMPLATES_DRY_RUN`, `AI_REQUEST_TIMEOUT_MS`,
`AI_CONTEXT_MESSAGE_LIMIT`, `ALLOWED_INVITE_HOSTS`) pass through unchanged. AI keys are added per account
in the app, stored encrypted with `ENCRYPTION_KEY`.

## Persistent data

| Service | Path | Holds | If lost |
|---|---|---|---|
| `db` | `/var/lib/postgresql/data` | Everything in the CRM, users, and the Vault root key | Everything |
| `storage` | `/var/lib/storage` | Avatars, flow media, and copies of received WhatsApp media | Attachments. Meta deletes its copy after about 30 days. |

## Before you rely on it

- **The UI is English.** Upstream bakes the language into the build; this image is built once, so it
  stays on upstream's default.
- **No e-mail is sent until you configure SMTP on `auth`.** Accounts are created confirmed, and "forgot
  password" cannot reach anyone. Use `WACRM_RESET_OWNER_PASSWORD` to recover the owner.
- **`ENCRYPTION_KEY` must never change.** It encrypts every stored WhatsApp access token and AI key.
- A refused signup shows Supabase's generic "Database error saving new user". The refusal is deliberate;
  see `SECURITY.md`.

## Local development

```bash
docker compose build
tests/static.sh
tests/smoke.sh
tests/persistence.sh
```

The compose file mirrors the Railway services one-to-one with fixed, public, local-test-only secrets.
The app is served on `http://localhost:13500` and the gateway on `http://kong.localhost:18500`; move them
with `WACRM_TEST_PORT` and `WACRM_TEST_GATEWAY_PORT`.

After deploying:

```bash
tests/railway-smoke.sh https://<app-domain> https://<kong-domain>
```

## Documents

| File | Contents |
|---|---|
| `ARCHITECTURE.md` | Service graph, start-up, build-time values, migrations, the signup gate |
| `SECURITY.md` | Threat model, what is exposed, residual risks |
| `RAILWAY_TEMPLATE.md` | The exact template configuration |
| `UPSTREAM.md` | Pinned versions, digests, and what this repository changes |
| `MAINTENANCE.md` | Release process, bumping upstream, rollback |
| `MARKETPLACE_AUDIT.md` | Why this template exists |
| `THIRD_PARTY_NOTICES.md` | Licences |

## Licence

MIT for this repository. wacrm is MIT; the Supabase components are MIT, Apache-2.0 and the PostgreSQL
licence. See `THIRD_PARTY_NOTICES.md`. WhatsApp is a trademark of Meta; this template uses Meta's
official WhatsApp Business Platform through wacrm.

[upstream]: https://github.com/ArnasDon/wacrm
