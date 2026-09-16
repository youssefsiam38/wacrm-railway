# Architecture

## Service graph

```
                        browser                                  Meta (WhatsApp Cloud API)
                ┌──────────┴────────────┐                                  │
         https (app domain)      https (gateway domain)             webhooks to the app domain
                │                       │                                  │
              app ◀──────────────────── │ ─────────────────────────────────┘
               │ ▲                    kong ──┬──▶ auth ──────┐
               │ │ cron                      ├──▶ rest ──────┤
               │ │                           ├──▶ realtime ──┤
               │ scheduler                   └──▶ storage ───┼──▶ db
               │                                             │
               ├──── server-side Supabase calls ──▶ kong     │
               └──── migrations (psql) ──────────────────────┘
```

Two services are public: `app`, and `kong`, because wacrm's browser code talks to Supabase directly for
sign-in, data under row-level security, Realtime and file uploads. Everything else is reachable only on
Railway's private network at `<service>.railway.internal`.

## Wrappers and the build

| Service | Image | Why |
|---|---|---|
| `db` | wrapper | Supabase's init scripts baked in (no bind mounts on Railway); the Vault root key moved onto the data volume. |
| `kong` | wrapper | Its config is baked in, and the API keys it checks are minted from `JWT_SECRET`. |
| `storage` | wrapper | Needs the same minted keys. |
| `app` | built here | Upstream publishes no image. |
| `scheduler` | built here | Upstream schedules nothing. |
| `auth`, `rest`, `realtime` | upstream | Unchanged. |

The `db`, `kong` and `storage` wrappers are the same as in the DeskcommCRM Railway template, where
they were first built and tested.

## Build-time values

Next.js inlines every `NEXT_PUBLIC_*` variable into the server and browser bundles when the app is
built. Upstream's Dockerfile therefore takes the Supabase URL and anon key as build arguments, and each
deployer builds their own image. A template cannot do that: the gateway's domain does not exist until
the template is deployed, and the anon key is signed with a secret generated at the same moment.

So the image is built once, in CI, with placeholder values:

| Variable | Placeholder |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | `https://wacrm-railway-supabase-url.invalid` |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | `wacrm-railway-placeholder-supabase-anon-key` |
| `NEXT_PUBLIC_SITE_URL` | `https://wacrm-railway-site-url.invalid` |

The build records every output file that contains one and keeps a pristine copy of each
(`/opt/wacrm/pristine`). On every start, `fill-public-env.mjs` rewrites those files from their pristine
copies with the deployment's real values. The values must match strict shapes (a bare origin, a
three-part JWT), so nothing can break out of the JavaScript string it lands in, and the start fails if
any placeholder is left anywhere, for example in a form the build escaped.

`NEXT_PUBLIC_APP_LOCALE` cannot be handled this way: the bundler resolves `messages/<locale>.json` at
build time and prerenders pages with that catalogue. The image is built in English.

One consequence: browsers cache the built JavaScript by file name. If the gateway domain ever changes,
users need a hard reload once to pick up the new value.

## Start-up

Railway starts every service at once, so each waits for what it needs.

1. `db` initialises the cluster and runs Supabase's init scripts.
2. `auth` and `storage` run their own migrations, creating the `auth` and `storage` schemas.
3. `app` waits for the database, then for Auth and Storage to answer through the gateway, because
   wacrm's migrations add a trigger to `auth.users` and buckets to `storage.buckets`.
4. `app` applies the migrations and the signup gate, runs upstream's schema check, waits for PostgREST
   to see the schema, creates the owner, writes the public values, and starts the server.
5. `scheduler` starts calling the cron endpoints; until the app answers it waits quietly.

## Migrations

Upstream keeps ordered migrations in `supabase/migrations` and expects `supabase db push` from the
operator's machine. Its CI replays every file in filename order against an empty database, so that
order is reproduced by `migrate.sh`:

- Each file not yet recorded in `wacrm_railway.applied_migrations` runs in its own transaction with
  `ON_ERROR_STOP`, and is recorded in the same transaction. A failure keeps nothing from that file and
  stops the start.
- A recorded file is never run again. If its content changed after it was applied, a warning is logged.
- `supabase/ci/verify-schema.sql`, upstream's own check that the migrations built the schema rather than
  silently doing nothing, runs after them.
- Everything runs as `postgres`, as `supabase db push` does. An advisory lock serialises the files.

## The signup gate

In wacrm every new auth user gets an account of their own. Upstream's `handle_new_user` trigger creates
an `accounts` row and makes the user its owner. On a public deployment that gives any visitor a working
CRM tenant, and closing `/signup` in the app would not help: the browser talks to Supabase Auth directly.

`gate.sql` puts the rule where every path to a new user converges, a `BEFORE INSERT` trigger on
`auth.users`. A new user is admitted when:

1. their metadata carries the **one-time bootstrap nonce**. The entrypoint generates 32 random bytes,
   stores only their SHA-256 in `wacrm_railway.settings`, and passes the nonce to the owner bootstrap,
   which creates the owner through Auth's admin API. The insert consumes the hash; the entrypoint also
   deletes it afterwards whatever happened. `app_metadata` would be the natural marker, since browsers
   cannot set it, but Supabase Auth writes it after the insert.
2. their metadata carries an **invitation token** matching a pending, unexpired invitation, compared by
   SHA-256 as upstream stores it. The signup page already holds the token (from `/signup?invite=`); a
   one-line build-time patch (`patch-signup.mjs`) makes it send the token too. The build fails if the
   patch stops applying.
3. `WACRM_SIGNUP_MODE=open` has been set deliberately.

A second trigger, `BEFORE UPDATE`, removes both keys from stored metadata, because Supabase Auth
rewrites the metadata from its in-memory copy right after the insert. Redeeming the invitation, which
moves the new user into the inviter's account, is unchanged upstream code.

## The owner

`bootstrap-owner.mjs` runs only while no user exists. It creates the owner (e-mail confirmed), checks
that upstream's trigger gave them an account with the `owner` role (that trigger swallows its own errors),
and names the account. Once any user exists it exits without touching anything, so a redeploy never undoes
a password change; recovery is an explicit switch, `WACRM_RESET_OWNER_PASSWORD`.

## Scheduler

wacrm's automation Wait steps and flows advance only when `GET /api/automations/cron` and
`GET /api/flows/cron` are called with `x-cron-secret`. Upstream suggests Vercel Cron or an external pinger.
The `scheduler` service is that pinger: Alpine, curl and a loop, calling both every 60 seconds over the
private network. The secret is passed to curl on stdin, so it never appears in a process list. Failures
are logged when they start and when they stop, not every minute.

## Networking

Railway's private DNS answers with IPv6 (and IPv4 in newer environments), and clients like Kong prefer
IPv6, so every listener is dual-stack: the app with `HOSTNAME=::`, Kong on both families, GoTrue on `::`,
PostgREST with `PGRST_SERVER_HOST=*6` (`*` binds IPv4 only), Storage on `::`. The local test network has
IPv6 enabled so a listener that only answers on IPv4 fails the tests, not a deploy.

## Logs

Routine lines go to stdout and failures to stderr, because Railway colours a line by its stream. Kong's
access log is off (Realtime's websocket URL carries the API key) and so is its request-debug feature.
