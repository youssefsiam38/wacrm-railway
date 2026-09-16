#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # single-quoted literals are matched, not expanded
# Public smoke test against a deployed bundle.
#   tests/railway-smoke.sh https://app-domain https://gateway-domain
# Optional:
#   OWNER_EMAIL=... OWNER_PASSWORD_FILE=/path   sign in as the owner (the file holds the password)
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd); export REPO_ROOT
APP_URL=${1:?usage: railway-smoke.sh https://app-domain https://gateway-domain}; APP_URL=${APP_URL%/}
GATEWAY_URL=${2:?usage: railway-smoke.sh https://app-domain https://gateway-domain}; GATEWAY_URL=${GATEWAY_URL%/}
export APP_URL GATEWAY_URL
# shellcheck source=tests/lib.sh
. "$REPO_ROOT/tests/lib.sh"
umask 077
host=${APP_URL#https://}

section "TLS and routing"
# Railway's edge serves 404 for a few seconds while a deployment takes over.
wait_for_code "$APP_URL/login" 200 600 || true
assert_eq "sign-in page over https" "200" "$(http_code "$APP_URL/login")"
assert_contains "valid certificate" "SSL certificate verify ok" "$(curl -sv -o /dev/null "$APP_URL/login" 2>&1 || true)"
assert_contains "http -> https" "https://$host" "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 20 "http://$host/login")"
assert_eq "the dashboard sends a visitor to sign in" "307" "$(http_code "$APP_URL/dashboard")"

section "the build carries this deployment's values"
page=$(curl -s --max-time 30 "$APP_URL/login" || true)
assert_not_contains "no placeholder in the sign-in page" "wacrm-railway-" "$page"
anon=""; found_gateway=0
for js in $(grep -oE '/_next/static/[^"]+\.js' <<<"$page" | sort -u | head -60); do
  body=$(curl -s --max-time 20 "$APP_URL$js" || true)
  if grep -q 'wacrm-railway-' <<<"$body"; then fail "a placeholder survived in $js"; fi
  grep -q "$GATEWAY_URL" <<<"$body" && found_gateway=1
  [ -n "$anon" ] || anon=$(grep -oE 'eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' <<<"$body" | head -1 || true)
done
[ "$found_gateway" = 1 ] && pass "the browser bundle points at this gateway" || fail "no browser chunk carries the gateway URL"
[ -n "$anon" ] && pass "found the public anon key the browser uses" || fail "could not find the anon key in the browser bundle"
printf 'ANON_KEY=%s\n' "$anon" > "$TEST_TMP/keys"

section "the gateway"
assert_eq "no API key, no entry" "401" "$(http_code "$GATEWAY_URL/rest/v1/profiles")"
assert_eq "the anon key alone reads no profiles" "[]" "$(rest_as anon '/rest/v1/profiles?select=user_id' | jq -c . 2>/dev/null)"
assert_eq "the REST schema listing is service-role only" "403" "$(http_code "$GATEWAY_URL/rest/v1/" -H "apikey: $anon")"
assert_eq "Realtime's tenant API is blocked" "403" "$(http_code "$GATEWAY_URL/realtime/v1/api/tenants" -H "apikey: $anon")"
assert_eq "Realtime accepts a websocket over TLS" "101" "$(http_code --http1.1 --max-time 10 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "$GATEWAY_URL/realtime/v1/websocket?apikey=$anon&vsn=1.0.0")"
assert_eq "Supabase Auth answers" "200" "$(http_code "$GATEWAY_URL/auth/v1/health" -H "apikey: $anon")"

section "signup is by invitation only"
# A refused signup leaves nothing behind, so this probe is safe to run against a live instance.
head -c 18 /dev/urandom | base64 | tr -d '/+=\n' > "$TEST_TMP/probe-pw"
assert_eq "an uninvited signup is refused" "500" "$(sign_up "probe-$(date +%s)@example.com" "$TEST_TMP/probe-pw")"
assert_eq "so is one with a made-up invitation token" "500" "$(sign_up "probe-token-$(date +%s)@example.com" "$TEST_TMP/probe-pw" made-up-token)"

section "the app's own API"
assert_eq "the public API refuses a request without a key" "401" "$(http_code "$APP_URL/api/v1/contacts")"
assert_eq "account settings refuse a visitor" "401" "$(http_code "$APP_URL/api/account")"
assert_eq "cron refuses a caller without the secret" "401" "$(http_code "$APP_URL/api/automations/cron")"
assert_eq "an unsigned WhatsApp webhook is refused" "401" "$(http_code -X POST "$APP_URL/api/whatsapp/webhook" -H 'Content-Type: application/json' --data '{}')"

if [ -n "${OWNER_EMAIL:-}" ] && [ -n "${OWNER_PASSWORD_FILE:-}" ]; then
  section "signed in as the owner"
  sign_in "$OWNER_EMAIL" "$OWNER_PASSWORD_FILE" "$TEST_TMP/owner-token" && pass "owner signs in" || fail "owner sign-in failed"
  [ -s "$TEST_TMP/owner-token" ] && assert_eq "the owner owns an account" "owner" \
    "$(rest_as "$TEST_TMP/owner-token" '/rest/v1/profiles?select=account_role' | jq -r '.[0].account_role')"
fi
summary
