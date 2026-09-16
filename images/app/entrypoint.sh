#!/bin/sh
# wacrm-railway app entrypoint.
#
#   1. validate variables (names only; values are never printed)
#   2. mint the Supabase API keys from JWT_SECRET
#   3. wait for the database, Supabase Auth and Supabase Storage, then apply the migrations and the
#      invite-only signup gate
#   4. create the owner account
#   5. write the public values into the built app, and only then start the web server
set -u
log()  { printf '[wacrm-app] %s\n' "$*"; }
fail() { printf '[wacrm-app] FATAL: %s\n' "$*" >&2; exit 1; }

require() {
  for name in "$@"; do
    eval "v=\${$name:-}"
    # shellcheck disable=SC2154  # v is assigned by the eval above
    [ -n "$v" ] || fail "missing required variable: $name"
  done
}

require JWT_SECRET SUPABASE_DB_URL SUPABASE_INTERNAL_URL NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_SITE_URL \
        ENCRYPTION_KEY OWNER_EMAIL OWNER_PASSWORD
[ "${#JWT_SECRET}" -ge 32 ] || fail "JWT_SECRET must be at least 32 characters"
case "$JWT_SECRET" in
  your-super-secret-jwt-token-with-at-least-32-characters-long)
    fail "JWT_SECRET is the value from Supabase's public .env.example. Anyone can sign a service_role token with it." ;;
esac
# AES-256-GCM key for stored WhatsApp and AI provider tokens: exactly 32 bytes as hex.
printf '%s' "$ENCRYPTION_KEY" | grep -Eqx '[0-9a-fA-F]{64}' || fail "ENCRYPTION_KEY must be exactly 64 hex characters"
[ "$ENCRYPTION_KEY" != "your-64-char-hex-key-here" ] || fail "ENCRYPTION_KEY is upstream's example value"
[ "${#OWNER_PASSWORD}" -ge 12 ] || fail "OWNER_PASSWORD must be at least 12 characters"
case "$OWNER_EMAIL" in *@*.*) ;; *) fail "OWNER_EMAIL must be an e-mail address; it is what the owner signs in with" ;; esac

# A Railway reference such as ${{kong.RAILWAY_PRIVATE_DOMAIN}} is empty until that service has a
# deployment, which leaves `http://:8000`. Say so, rather than retry an address that cannot exist.
for name in NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_SITE_URL SUPABASE_INTERNAL_URL SUPABASE_DB_URL; do
  eval "v=\${$name}"
  # shellcheck disable=SC2154  # v is assigned by the eval above
  case "$v" in
    *://|*://:*|*:///*|*@:*|*@/*)
      fail "$name has no host name. On Railway this is a reference to another service's domain that had not resolved when this deployment started; redeploy once that service has deployed." ;;
  esac
done

if [ -n "${AUTOMATION_CRON_SECRET:-}" ] && [ "${#AUTOMATION_CRON_SECRET}" -lt 32 ]; then
  fail "AUTOMATION_CRON_SECRET must be at least 32 characters"
fi
[ -n "${META_APP_SECRET:-}" ] || log "META_APP_SECRET is not set yet: the app runs, but WhatsApp webhooks are refused until it is"

: "${PORT:=3000}"
case "$PORT" in ''|*[!0-9]*) fail "PORT must be a number, got \"$PORT\"" ;; esac
# Railway's private network is IPv6; the scheduler reaches the app over it.
HOSTNAME="::"
# Invitation links are built from the request's Host header unless this allow-list is set. Default it
# to the site's own host, so a forged Host header cannot mint invite links to another domain.
if [ -z "${ALLOWED_INVITE_HOSTS:-}" ]; then
  ALLOWED_INVITE_HOSTS=$(printf '%s' "$NEXT_PUBLIC_SITE_URL" | sed -E 's#^https?://##; s#[:/].*$##')
fi
export PORT HOSTNAME ALLOWED_INVITE_HOSTS

keys=$(node /opt/wacrm/mint-supabase-keys.mjs) || fail "could not mint the Supabase API keys"
NEXT_PUBLIC_SUPABASE_ANON_KEY=$(printf '%s\n' "$keys" | sed -n 's/^ANON_KEY=//p')
SUPABASE_SERVICE_ROLE_KEY=$(printf '%s\n' "$keys" | sed -n 's/^SERVICE_ROLE_KEY=//p')
unset keys
export NEXT_PUBLIC_SUPABASE_ANON_KEY SUPABASE_SERVICE_ROLE_KEY

: "${WACRM_READY_TIMEOUT:=600}"
deadline=$(( $(date +%s) + WACRM_READY_TIMEOUT ))
wait_for() {
  what=$1; shift
  until "$@" >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || fail "$what did not become ready within ${WACRM_READY_TIMEOUT}s"
    sleep 3
  done
  log "$what is ready"
}
api_ok() {
  # $1 = path, $2 = name of the variable holding the key; succeeds on HTTP 200
  WACRM_PROBE_PATH="$1" WACRM_PROBE_KEY="$2" node -e '
    const k = process.env[process.env.WACRM_PROBE_KEY];
    fetch(process.env.SUPABASE_INTERNAL_URL.replace(/\/+$/,"") + process.env.WACRM_PROBE_PATH, {
      headers: { apikey: k, Authorization: "Bearer " + k } })
      .then(r => process.exit(r.status === 200 ? 0 : 1)).catch(() => process.exit(1))'
}

# Supabase's own services create the auth and storage schemas on first start, and wacrm's migrations
# add a trigger to auth.users and buckets to storage.buckets, so they run only once both answer.
wait_for "the database" psql "$SUPABASE_DB_URL" -tAc "select 1"
wait_for "the gateway and Supabase Auth" api_ok /auth/v1/health NEXT_PUBLIC_SUPABASE_ANON_KEY
wait_for "Supabase Storage" api_ok /storage/v1/bucket SUPABASE_SERVICE_ROLE_KEY
/opt/wacrm/migrate.sh || exit 1
wait_for "the REST API with the new schema" api_ok "/rest/v1/profiles?select=user_id&limit=1" SUPABASE_SERVICE_ROLE_KEY

# The signup gate admits the owner by a one-time nonce: 32 random bytes, only their hash stored in the
# database, the nonce itself passed to the bootstrap in its environment and consumed by the insert.
# It is removed again whatever happens, so no admitting value outlives this start.
WACRM_BOOTSTRAP_NONCE=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
printf '%s' "$WACRM_BOOTSTRAP_NONCE" | grep -Eqx '[0-9a-f]{64}' || fail "could not generate the bootstrap nonce"
nonce_sha=$(printf '%s' "$WACRM_BOOTSTRAP_NONCE" | sha256sum | cut -d' ' -f1)
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -qc "
  insert into wacrm_railway.settings (key, value) values ('bootstrap_nonce_sha256', '$nonce_sha')
  on conflict (key) do update set value = excluded.value, updated_at = now();" >/dev/null 2>&1 \
  || fail "could not register the bootstrap nonce"
export WACRM_BOOTSTRAP_NONCE
node /opt/wacrm/bootstrap-owner.mjs; status=$?
unset WACRM_BOOTSTRAP_NONCE
psql "$SUPABASE_DB_URL" -qc "delete from wacrm_railway.settings where key = 'bootstrap_nonce_sha256';" >/dev/null 2>&1 || true
[ "$status" -eq 0 ] || fail "could not create the owner account; refusing to serve an instance nobody can sign in to"
node /opt/wacrm/fill-public-env.mjs || exit 1

log "cron endpoints: $( [ -n "${AUTOMATION_CRON_SECRET:-}" ] && echo enabled || echo 'disabled (AUTOMATION_CRON_SECRET unset)' )"
log "starting wacrm on [${HOSTNAME}]:${PORT}"
exec node server.js
