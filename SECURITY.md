# Security

## Reporting

Open an issue at https://github.com/youssefsiam38/wacrm-railway/issues for a problem with the template
or its wrappers. Report anything in wacrm itself to https://github.com/ArnasDon/wacrm. Do not include
credentials, API keys, cookies or public hostnames in an issue.

## What this bundle holds

Customer names and phone numbers, whole WhatsApp conversations and the media people sent, deal values,
and, encrypted with `ENCRYPTION_KEY`, the WhatsApp Business access tokens and AI provider keys the
account configures. A WhatsApp access token is the ability to message customers as the business.

## Problems this template closes

| Problem on a public platform | What the template does |
|---|---|
| Anyone who reaches `/signup` gets a working CRM account on the deployer's instance; upstream has no setting to close it | A `BEFORE INSERT` trigger on `auth.users` admits only the owner (by a one-time nonce) and people holding a valid invitation. It sits under Supabase Auth, so posting straight to the gateway does not get round it. |
| The first user of a fresh install is whoever signs up first | The owner is created before the app listens. |
| Migrations are left to the operator; a partial schema can lack the row-level security later files add | Every migration runs in its own transaction; any failure stops the start. Upstream's schema check runs after them. |
| Supabase's `.env.example` ships a working JWT secret and database password; upstream's `ENCRYPTION_KEY` example is a placeholder | Every secret is generated per deploy; the wrappers refuse the example values and short ones. |
| Invite links are built from the request's Host header, so a forged header can point them at another domain | `ALLOWED_INVITE_HOSTS` defaults to the app's own domain. |
| Cron endpoints need a shared secret passed by some external pinger | Generated once and shared with the scheduler over the private network; passed to curl on stdin, not its command line. |
| A redeploy re-running a "create owner" step would reset the owner's password | The bootstrap exits untouched once any user exists. |
| Kong's admin API, access log (Realtime puts the API key in its URL) and request-debug token | Off. |

## What is exposed

| Surface | Anonymous | Notes |
|---|---|---|
| `app` domain | Sign-in, signup form, invitation pages, `/api/whatsapp/webhook` | The webhook verifies Meta's HMAC signature with `META_APP_SECRET` and refuses everything until it is set. The public API (`/api/v1`) requires an API key; cron routes require their secret. |
| `kong` domain, no API key | 401 | |
| `kong` domain, anon key | Supabase Auth sign-in and signup (gated); REST, Storage and Realtime under row-level security | The anon key is public by design: it is in the browser bundle. |
| `kong` `/rest/v1/` schema listing | 403 unless service role | |
| `kong` `/realtime/v1/api/*` tenant API | 403 | |

The service-role key never leaves the private network. It is minted inside `app`, `storage` and `kong`,
and `tests/smoke.sh` checks that no browser chunk contains it.

## How the signup gate decides

A new user is admitted when one of these holds, and refused otherwise:

1. **Owner bootstrap.** The entrypoint stores the SHA-256 of 32 random bytes; the owner bootstrap sends
   those bytes as user metadata through the Auth admin API over the private network; the insert deletes
   the hash. The nonce is never logged, never leaves the container, and cannot be replayed.
2. **Invitation.** The metadata carries a token whose SHA-256 matches a pending invitation that has not
   expired. Invitations are created by account admins in the app. A used or expired token admits nobody.
3. **Open mode.** `WACRM_SIGNUP_MODE=open`, set deliberately.

Neither the nonce nor an invitation token is kept in `auth.users`: a second trigger removes them on the
update Supabase Auth makes right after the insert. `tests/smoke.sh` signs up a stranger, a made-up token,
a forged nonce and a reused token, and checks that none of them created a user.

## Residual risks

**A refused signup looks like a server error.** Supabase Auth reports any trigger exception as "Database
error saving new user" (HTTP 500). The message a refused visitor sees is therefore unhelpful; the refusal
itself is correct.

**Invitation links are bearer tokens.** Anyone holding a valid link can create an account and join as the
role it grants, until it is used or expires (seven days by default). Send them privately; revoke unused
ones in the app.

**E-mail addresses are not verified** (`GOTRUE_MAILER_AUTOCONFIRM=true`), because no e-mail is sent until
SMTP is configured. Admission depends on the invitation, not the address. Configure SMTP on `auth` and
turn autoconfirm off if you need verified addresses.

**Placeholders in the build.** The public Supabase URL and anon key are written into the built JavaScript
at start-up (see `ARCHITECTURE.md`). The values are public by nature and are checked against strict
shapes before they are written.

**Anyone with access to the Railway project has everything.** Project variables contain the database
password, the JWT secret (from which the service-role key follows) and `ENCRYPTION_KEY`. Treat project
membership as root on the CRM.

**Legacy HS256 API keys with a 2035 expiry.** Rotating them means rotating `JWT_SECRET` on `auth` and
redeploying every service; all sessions end.

**The Vault root key** is a file on the `db` volume, beside the data it protects, because Railway gives a
service one volume.

## Secrets

| Secret | Generated on | Referenced by | Purpose |
|---|---|---|---|
| `POSTGRES_PASSWORD` | `db` | auth, rest, realtime, storage, app | Password of every Supabase database role |
| `JWT_SECRET` | `auth` | rest, realtime, storage, kong, app | Signs sessions and the API keys |
| `DB_ENC_KEY`, `SECRET_KEY_BASE` | `realtime` | | Realtime's tenant encryption and Phoenix sessions |
| `ENCRYPTION_KEY` | `app` | | AES-256-GCM key for stored WhatsApp tokens and AI keys |
| `AUTOMATION_CRON_SECRET` | `app` | scheduler | Authenticates the cron calls |
| `OWNER_PASSWORD` | `app` | | The owner's first password |
| `META_APP_SECRET` | entered by you | | Verifies WhatsApp webhook signatures |

**Never change `ENCRYPTION_KEY` on a running install.** Every stored WhatsApp token and AI key becomes
unreadable, and each account has to reconnect.

No wrapper prints a secret; the owner's e-mail is masked in the log. `tests/smoke.sh` searches every
service's log for every test secret and both API keys.

## Recovering the owner account

Set a new `OWNER_PASSWORD` and `WACRM_RESET_OWNER_PASSWORD=true` on `app` and redeploy. The start applies
the password to the `OWNER_EMAIL` account and logs a warning to remove the switch. Remove it, or every
redeploy resets the password again.
