# Third-party notices

Licences for code copied into this repository are vendored in `licenses/` and shipped inside every
wrapper image at `/usr/share/licenses/wacrm-railway/`.

## Copied or built into the images

| What | From | Licence | Notice |
|---|---|---|---|
| wacrm, built from source with a one-line patch | ArnasDon/wacrm | MIT | `licenses/WACRM-LICENSE` |
| wacrm's database migrations and schema check | ArnasDon/wacrm `supabase/` | MIT | `licenses/WACRM-LICENSE` |
| Five database init scripts | supabase/supabase `docker/volumes/db` | Apache-2.0 | `licenses/SUPABASE-LICENSE` |
| Kong declarative config, trimmed | supabase/supabase `docker/volumes/api/kong.yml` | Apache-2.0 | `licenses/SUPABASE-LICENSE` |

The built app bundles wacrm's npm dependencies (Next.js, React, Supabase client libraries and others,
under their own licences, mostly MIT). They are installed from upstream's lockfile with `npm ci` and are
not modified.

## Base images

| Image | Base | Licence |
|---|---|---|
| `app` | `node:20-alpine` | Node.js: MIT; Alpine packages under their own licences. Adds `postgresql17-client` (PostgreSQL licence). |
| `scheduler` | `alpine:3.23` | Adds `curl` (curl licence). |
| `db` | `supabase/postgres` 17.6.1.136 | PostgreSQL licence; bundled extensions carry their own |
| `kong` | `kong/kong` 3.9.3 | Apache-2.0 |
| `storage` | `supabase/storage-api` v1.74.0 | Apache-2.0 |

## Images the template runs unmodified

| Service | Image | Licence |
|---|---|---|
| `auth` | `supabase/gotrue` v2.196.0 | MIT |
| `rest` | `postgrest/postgrest` v14.17 | MIT |
| `realtime` | `supabase/realtime` v2.134.10 | Apache-2.0 |

## Licence obligations

Every licence above is permissive. MIT and Apache-2.0 require the notice to accompany the software;
`licenses/` is copied into each image for anyone who pulls one without reading this repository.

## Services and trademarks

"wacrm", "Supabase", "Kong", "WhatsApp" and "Meta" belong to their respective owners. None of them is
affiliated with or endorses this template. Using the WhatsApp Business Platform is subject to Meta's
terms, which are not a software licence and are not satisfied by anything in this repository.

The template icon in `assets/` was drawn for this repository and is MIT licensed with it.
