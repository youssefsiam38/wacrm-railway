# Upstream provenance

Everything the bundle runs, where it comes from, and what this repository changes. Digests are
multi-architecture index digests as resolved on 2026-09-16. The Railway template references tags,
because Railway's template generator rejects digest references; the Dockerfiles pin tag and digest.

## wacrm

| | |
|---|---|
| Project | https://github.com/ArnasDon/wacrm |
| Licence | MIT (`licenses/WACRM-LICENSE`) |
| Commit pinned | `80c3f9a1aecdaf21b98311f230fdaaaec7d85f7d` (2026-09-13), `package.json` version 0.8.0 |
| Published image | none; upstream's Dockerfile is built by each deployer |
| Stack | Next.js 16 standalone, Supabase (Postgres, Auth, PostgREST, Realtime, Storage) |

Upstream has no release tags, so the image is built from an exact commit, fetched by id so that git
verifies the content.

What `images/app/Dockerfile` changes relative to upstream's own Dockerfile:

- **Build-time values.** `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY` and
  `NEXT_PUBLIC_SITE_URL` are built as placeholders and written with real values at start-up
  (`fill-public-env.mjs`). `NEXT_PUBLIC_APP_LOCALE` is fixed to `en`.
- **One source patch** (`patch-signup.mjs`): the signup page's `supabase.auth.signUp` call also sends
  the invitation token it already holds, as `options.data.invite_token`. The build fails unless the
  patch matches exactly once.
- **Added at runtime:** `postgresql17-client`, upstream's `supabase/migrations` and
  `supabase/ci/verify-schema.sql`, and this repository's `migrate.sh`, `gate.sql`,
  `bootstrap-owner.mjs`, `fill-public-env.mjs`, the key minter and the entrypoint.
- The server listens on `::` instead of `0.0.0.0`.

| Base | Image | Digest |
|---|---|---|
| Node.js | `node:20-alpine` (Alpine 3.23, Node 20.20.2) | `sha256:fb4cd12c85ee03686f6af5362a0b0d56d50c58a04632e6c0fb8363f609372293` |
| Scheduler | `alpine:3.23` | `sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40` |

## Supabase self-hosting stack

| | |
|---|---|
| Source | https://github.com/supabase/supabase/tree/master/docker, commit `e693f206f5050b0004a86e12e533bb75ba2a9c76` |
| Licence | Apache-2.0 (`licenses/SUPABASE-LICENSE`) |
| Copied files | `volumes/db/{realtime,_supabase,webhooks,roles,jwt}.sql` into `images/db/init/`; `volumes/api/kong.yml`, trimmed, into `images/kong/kong.yml` |

The `db`, `kong` and `storage` wrappers are shared with the DeskcommCRM Railway template
(https://github.com/youssefsiam38/deskcommcrm-railway), where they were built and tested first.

| Component | Image | Digest | Licence | Wrapped |
|---|---|---|---|---|
| Postgres | `supabase/postgres:17.6.1.136` | `sha256:f371b5f3f2ac0a05703f33d6e6134515fb2498cab708fb948a0aeb7481467c00` | PostgreSQL | `db` |
| Auth | `supabase/gotrue:v2.196.0` | `sha256:c0c25187a6b835e65a6f6e6c6b39d090e832d40e6de5186f2c038e0411944232` | MIT | no |
| PostgREST | `postgrest/postgrest:v14.17` | `sha256:c9dc201e555f5d8e37e7f39cdd4df0229774996e213bfd7de8d10ac609030f2c` | MIT | no |
| Realtime | `supabase/realtime:v2.134.10` | `sha256:cbcc6a7986fc28b6dcffa798b077d5fb9c69cd25500371ab49147a86d7edbb03` | Apache-2.0 | no |
| Storage | `supabase/storage-api:v1.74.0` | `sha256:f1546fac6d1c7e345428ac904bfaa7be7cecd50a1f549fe1cf38c628a7b15c85` | Apache-2.0 | `storage` |
| Kong | `kong/kong:3.9.3` | `sha256:9a2ae6699a2ce0d60592eb176555d3594a22782c20cc6557a61ff3a7e8b559a3` | Apache-2.0 | `kong` |

What those wrappers change: `db` bakes in the init scripts and keeps the pgsodium/Vault root key on the
data volume; `kong` bakes in its config, mints the API keys, listens dual-stack and turns off its admin
API, access log and request debugging; `storage` mints the API keys and uses the file backend on its
volume.

## Published images

`ghcr.io/youssefsiam38/wacrm-railway-{db,kong,storage,app,scheduler}`, amd64, built and tested together
by `.github/workflows/publish-image.yml`. Each ships this repository's licence set at
`/usr/share/licenses/wacrm-railway/`.
