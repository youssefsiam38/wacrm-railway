# Railway template configuration

The template's exact configuration. Reproduce it from this file if it ever has to be rebuilt.

| | |
|---|---|
| Name | wacrm + Supabase |
| Code | `wacrm-supabase` |
| Template id | `b015844a-2fa4-48e4-842f-71edcba3920e` |
| Deploy URL | https://railway.com/deploy/wacrm-supabase |
| Category | Automation |
| Card description | WhatsApp CRM on Meta's official API, with a self-hosted Supabase |
| Icon | `assets/icon.png` |
| Overview markdown | `marketplace/OVERVIEW.md` (Railway enforces its section headings) |

Generated values use Railway's `secret()` function: `hexN` is `${{secret(N, "abcdef0123456789")}}` and `alnumN` is
`${{secret(N, "a-zA-Z0-9")}}` spelled out. Alphanumeric passwords are used wherever a value is embedded in a
connection URL, so nothing needs percent-encoding. Images are referenced by tag, because the template generator
rejects digests; `UPSTREAM.md` records the digests.

## Services

### `db`

| Field | Value |
|---|---|
| Source | `ghcr.io/youssefsiam38/wacrm-railway-db:1.0.0` |
| Public domain | none |
| Volume | `/var/lib/postgresql/data` |
| Restart policy | on failure, 10 retries |

| Variable | Value |
|---|---|
| `POSTGRES_PASSWORD` | generated, alnum48 |

### `auth`

| Field | Value |
|---|---|
| Source | `supabase/gotrue:v2.196.0` |
| Public domain | none |
| Volume | none |
| Restart policy | on failure, 10 retries |

| Variable | Value |
|---|---|
| `JWT_SECRET` | generated, hex64 |
| `PORT` | `9999` |
| `GOTRUE_API_HOST` | `::` |
| `GOTRUE_API_PORT` | `9999` |
| `API_EXTERNAL_URL` | `https://${{kong.RAILWAY_PUBLIC_DOMAIN}}` |
| `GOTRUE_DB_DRIVER` | `postgres` |
| `GOTRUE_DB_DATABASE_URL` | `postgres://supabase_auth_admin:${{db.POSTGRES_PASSWORD}}@${{db.RAILWAY_PRIVATE_DOMAIN}}:5432/postgres` |
| `GOTRUE_SITE_URL` | `https://${{app.RAILWAY_PUBLIC_DOMAIN}}` |
| `GOTRUE_URI_ALLOW_LIST` | `https://${{app.RAILWAY_PUBLIC_DOMAIN}}/**` |
| `GOTRUE_DISABLE_SIGNUP` | `false` |
| `GOTRUE_JWT_ADMIN_ROLES` | `service_role` |
| `GOTRUE_JWT_AUD` | `authenticated` |
| `GOTRUE_JWT_DEFAULT_GROUP_NAME` | `authenticated` |
| `GOTRUE_JWT_EXP` | `3600` |
| `GOTRUE_JWT_SECRET` | `${{JWT_SECRET}}` |
| `GOTRUE_EXTERNAL_EMAIL_ENABLED` | `true` |
| `GOTRUE_EXTERNAL_ANONYMOUS_USERS_ENABLED` | `false` |
| `GOTRUE_EXTERNAL_PHONE_ENABLED` | `false` |
| `GOTRUE_MAILER_AUTOCONFIRM` | `true` |
| `GOTRUE_SMTP_HOST` | optional, unset |
| `GOTRUE_SMTP_PORT` | optional, unset |
| `GOTRUE_SMTP_USER` | optional, unset |
| `GOTRUE_SMTP_PASS` | optional, unset |
| `GOTRUE_SMTP_ADMIN_EMAIL` | optional, unset |

### `rest`

| Field | Value |
|---|---|
| Source | `postgrest/postgrest:v14.17` |
| Public domain | none |
| Volume | none |
| Restart policy | on failure, 10 retries |

| Variable | Value |
|---|---|
| `PGRST_DB_URI` | `postgres://authenticator:${{db.POSTGRES_PASSWORD}}@${{db.RAILWAY_PRIVATE_DOMAIN}}:5432/postgres` |
| `PGRST_DB_SCHEMAS` | `public,storage,graphql_public` |
| `PGRST_DB_MAX_ROWS` | `1000` |
| `PGRST_DB_EXTRA_SEARCH_PATH` | `public` |
| `PGRST_DB_ANON_ROLE` | `anon` |
| `PGRST_JWT_SECRET` | `${{auth.JWT_SECRET}}` |
| `PGRST_DB_USE_LEGACY_GUCS` | `false` |
| `PGRST_APP_SETTINGS_JWT_EXP` | `3600` |
| `PGRST_SERVER_HOST` | `*6` |
| `PGRST_SERVER_PORT` | `3000` |

### `realtime`

| Field | Value |
|---|---|
| Source | `supabase/realtime:v2.134.10` |
| Public domain | none |
| Volume | none |
| Restart policy | on failure, 10 retries |

| Variable | Value |
|---|---|
| `PORT` | `4000` |
| `DB_HOST` | `${{db.RAILWAY_PRIVATE_DOMAIN}}` |
| `DB_PORT` | `5432` |
| `DB_USER` | `supabase_admin` |
| `DB_PASSWORD` | `${{db.POSTGRES_PASSWORD}}` |
| `DB_NAME` | `postgres` |
| `DB_AFTER_CONNECT_QUERY` | `SET search_path TO _realtime` |
| `DB_ENC_KEY` | generated, alnum16 |
| `API_JWT_SECRET` | `${{auth.JWT_SECRET}}` |
| `METRICS_JWT_SECRET` | `${{auth.JWT_SECRET}}` |
| `SECRET_KEY_BASE` | generated, alnum64 |
| `ERL_AFLAGS` | `-proto_dist inet_tcp` |
| `DNS_NODES` | `''` |
| `RLIMIT_NOFILE` | `10000` |
| `APP_NAME` | `realtime` |
| `SEED_SELF_HOST` | `true` |
| `SELF_HOST_TENANT_NAME` | `realtime` |
| `RUN_JANITOR` | `true` |
| `DISABLE_HEALTHCHECK_LOGGING` | `true` |

### `storage`

| Field | Value |
|---|---|
| Source | `ghcr.io/youssefsiam38/wacrm-railway-storage:1.0.0` |
| Public domain | none |
| Volume | `/var/lib/storage` |
| Restart policy | on failure, 10 retries |

| Variable | Value |
|---|---|
| `PORT` | `5000` |
| `JWT_SECRET` | `${{auth.JWT_SECRET}}` |
| `DATABASE_URL` | `postgres://supabase_storage_admin:${{db.POSTGRES_PASSWORD}}@${{db.RAILWAY_PRIVATE_DOMAIN}}:5432/postgres` |
| `POSTGREST_URL` | `http://${{rest.RAILWAY_PRIVATE_DOMAIN}}:3000` |
| `STORAGE_PUBLIC_URL` | `https://${{kong.RAILWAY_PUBLIC_DOMAIN}}` |

### `kong`

| Field | Value |
|---|---|
| Source | `ghcr.io/youssefsiam38/wacrm-railway-kong:1.0.0` |
| Public domain | target port 8000 |
| Volume | none |
| Restart policy | on failure, 10 retries |

| Variable | Value |
|---|---|
| `PORT` | `8000` |
| `JWT_SECRET` | `${{auth.JWT_SECRET}}` |
| `AUTH_HOST` | `${{auth.RAILWAY_PRIVATE_DOMAIN}}` |
| `REST_HOST` | `${{rest.RAILWAY_PRIVATE_DOMAIN}}` |
| `REALTIME_HOST` | `${{realtime.RAILWAY_PRIVATE_DOMAIN}}` |
| `STORAGE_HOST` | `${{storage.RAILWAY_PRIVATE_DOMAIN}}` |

### `app`

| Field | Value |
|---|---|
| Source | `ghcr.io/youssefsiam38/wacrm-railway-app:1.0.0` |
| Public domain | target port 3000 |
| Volume | none |
| Healthcheck | `/login`, timeout from `RAILWAY_HEALTHCHECK_TIMEOUT_SEC` |
| Restart policy | on failure, 10 retries |

| Variable | Value |
|---|---|
| `PORT` | `3000` |
| `RAILWAY_HEALTHCHECK_TIMEOUT_SEC` | `900` |
| `NEXT_PUBLIC_SITE_URL` | `https://${{RAILWAY_PUBLIC_DOMAIN}}` |
| `NEXT_PUBLIC_SUPABASE_URL` | `https://${{kong.RAILWAY_PUBLIC_DOMAIN}}` |
| `SUPABASE_INTERNAL_URL` | `http://${{kong.RAILWAY_PRIVATE_DOMAIN}}:8000` |
| `JWT_SECRET` | `${{auth.JWT_SECRET}}` |
| `SUPABASE_DB_URL` | `postgres://postgres:${{db.POSTGRES_PASSWORD}}@${{db.RAILWAY_PRIVATE_DOMAIN}}:5432/postgres` |
| `ENCRYPTION_KEY` | generated, hex64 |
| `AUTOMATION_CRON_SECRET` | generated, hex64 |
| `OWNER_EMAIL` | required input, no default |
| `OWNER_PASSWORD` | generated, alnum24 |
| `OWNER_NAME` | `Owner` |
| `ACCOUNT_NAME` | `My company` |
| `WACRM_SIGNUP_MODE` | `invite-only` |
| `META_APP_SECRET` | optional, unset |
| `META_APP_ID` | optional, unset |

### `scheduler`

| Field | Value |
|---|---|
| Source | `ghcr.io/youssefsiam38/wacrm-railway-scheduler:1.0.0` |
| Public domain | none |
| Volume | none |
| Restart policy | on failure, 10 retries |

| Variable | Value |
|---|---|
| `AUTOMATION_CRON_SECRET` | `${{app.AUTOMATION_CRON_SECRET}}` |
| `WACRM_APP_ORIGIN` | `http://${{app.RAILWAY_PRIVATE_DOMAIN}}:3000` |
| `WACRM_CRON_INTERVAL` | `60` |

## Notes

- **Service names are part of the configuration.** Every cross-service reference uses them, and Realtime picks
  its tenant from the first label of `realtime.railway.internal`.
- The template was generated from a skeleton project that was never deployed: the generator keeps only
  reference-valued variables, so every literal and generator was patched in afterwards with
  `templateChangeSetStage` (`TemplatePatch!`, `merge: true`) and `templateChangeSetApply`.
- **PostgREST needs `PGRST_SERVER_HOST=*6`.** `*` binds IPv4 only, and Kong resolves the AAAA record first.
- **The app's healthcheck is `/login` with a 900-second timeout**, because the first start applies the
  migrations before the server listens.
- `OWNER_EMAIL` has no default, so the deploy form asks for it. Headless:
  `railway deploy -t wacrm-supabase -v "app.OWNER_EMAIL=you@example.com"`.
- `META_APP_SECRET` is optional so the deploy succeeds before a Meta app exists; the app logs that webhooks
  are refused until it is set.
- `PORT` is set explicitly on every service that reads it.
