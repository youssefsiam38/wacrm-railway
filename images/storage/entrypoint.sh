#!/bin/sh
# wacrm-railway storage entrypoint: mint the API keys, then run Supabase Storage unchanged.
set -eu
log()  { printf '[wacrm-storage] %s\n' "$*"; }
fail() { printf '[wacrm-storage] FATAL: %s\n' "$*" >&2; exit 1; }

[ -n "${JWT_SECRET:-}" ] || fail "missing required variable: JWT_SECRET"
[ -n "${DATABASE_URL:-}" ] || fail "missing required variable: DATABASE_URL"
[ -n "${POSTGREST_URL:-}" ] || fail "missing required variable: POSTGREST_URL"
for name in DATABASE_URL POSTGREST_URL; do
  eval "v=\${$name}"
  # shellcheck disable=SC2154  # v is assigned by the eval above
  case "$v" in
    *://|*://:*|*:///*|*@:*|*@/*) fail "$name has no host name. On Railway this is a reference to another service's domain that had not resolved when this deployment started; redeploy once that service has deployed." ;;
  esac
done

keys=$(node /usr/local/lib/wacrm/mint-supabase-keys.mjs) || fail "could not mint the Supabase API keys"
ANON_KEY=$(printf '%s\n' "$keys" | sed -n 's/^ANON_KEY=//p')
SERVICE_KEY=$(printf '%s\n' "$keys" | sed -n 's/^SERVICE_ROLE_KEY=//p')
AUTH_JWT_SECRET="$JWT_SECRET"
unset keys
export ANON_KEY SERVICE_KEY AUTH_JWT_SECRET

# The volume is mounted root-owned; the stock image already runs as root, so this only ensures the
# directory exists before the first upload.
mkdir -p "$FILE_STORAGE_BACKEND_PATH"

log "storage backend: file at ${FILE_STORAGE_BACKEND_PATH}, listening on [${SERVER_HOST}]:${PORT}"
exec docker-entrypoint.sh "$@"
