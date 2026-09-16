#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # single-quoted literals are matched, not expanded
# Local smoke test of the whole bundle on fresh volumes.
# Run `docker compose build` first (CI does), or set the WACRM_RAILWAY_*_IMAGE overrides.
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd); export REPO_ROOT
# shellcheck source=tests/lib.sh
. "$REPO_ROOT/tests/lib.sh"
mkdir -p "$REPO_ROOT/test-output"; METRICS="$REPO_ROOT/test-output/metrics.txt"
umask 077

JWT='local-test-only-jwt-secret-000000000000000000000000000000'
CRON='local-test-only-cron-secret-00000000000000000000'
OWNER_EMAIL='owner@example.com'
printf '%s' 'local-test-only-owner-password' > "$TEST_TMP/owner-pw"
printf '%s' 'someone-else-password-1' > "$TEST_TMP/other-pw"
mint_keys "$JWT"
MIGRATIONS=$(docker run --rm --entrypoint sh "$(service_image app)" -c 'ls /opt/wacrm/migrations/*.sql | wc -l' | tr -d '[:space:]')
SECRETS=(
  "$JWT" "$CRON" 'localtestonlypostgrespassword' 'local-test-only-owner-password' 'local-test-only-meta-app-secret'
  '00000000000000000000000000000000000000000000000000000000000000a1' "$(anon_key | tail -c 40)" "$(service_key | tail -c 40)"
)

section "fresh stack (empty volumes)"
compose down -v --remove-orphans >/dev/null 2>&1 || true
t0=$(date +%s); compose up -d --no-build
wait_for_code "$APP_URL/login" 200 "$TEST_TIMEOUT" && pass "the app serves its sign-in page" \
  || { compose logs --no-color --tail 60 app db auth storage kong; die "the app never became ready"; }
cold=$(( $(date +%s) - t0 )); echo "cold_start_seconds=$cold" | tee "$METRICS"

section "first boot"
logs=$(compose logs --no-color --no-log-prefix app)
assert_contains "waited for Supabase Auth" "the gateway and Supabase Auth is ready" "$logs"
assert_contains "waited for Supabase Storage before migrating" "Supabase Storage is ready" "$logs"
assert_contains "applied every upstream migration ($MIGRATIONS)" "migrations: $MIGRATIONS applied, 0 already in place" "$logs"
assert_contains "signup is invite-only" "signup: invite-only" "$logs"
assert_contains "created the owner" "owner account created" "$logs"
assert_contains "the owner's address is masked in the log" "instance claimed for o\*\*\*@example.com" "$logs"
assert_contains "wrote the public values into the build" "public values written into [0-9]* built files" "$logs"
assert_contains "listens dual-stack" "starting wacrm on \[::\]:3000" "$logs"
all=$(compose logs --no-color 2>&1)
for s in "${SECRETS[@]}"; do assert_not_contains "no secret in any service log (probe len ${#s})" "$s" "$all"; done
assert_not_contains "Kong does not print its request-debug token" "token for request debugging" "$all"
assert_eq "migrations are recorded" "$MIGRATIONS" "$(psql_admin 'select count(*) from wacrm_railway.applied_migrations')"
assert_contains "upstream's own schema check passes" "schema verified by upstream's check" "$logs"
assert_eq "the storage buckets exist" "avatars chat-media flow-media" "$(psql_admin "select string_agg(id, ' ' order by id) from storage.buckets")"

section "the build carries this deployment's values"
page=$(curl -s --max-time 30 "$APP_URL/login" || true)
assert_not_contains "no placeholder in the sign-in page" "wacrm-railway-" "$page"
chunks=$(compose exec -T app sh -c 'cat /app/.next/static/chunks/*.js')
assert_not_contains "no placeholder in any browser chunk" "wacrm-railway-" "$chunks"
assert_contains "the browser chunks carry the gateway URL" "$GATEWAY_URL" "$chunks"
assert_contains "and the anon key" "$(anon_key)" "$chunks"
assert_contains "the signup page sends the invitation token" "invite_token" "$chunks"
assert_not_contains "the service-role key is in no browser chunk" "$(service_key)" "$chunks"

section "the owner"
sign_in "$OWNER_EMAIL" "$TEST_TMP/owner-pw" "$TEST_TMP/owner-token" && pass "owner signs in through the gateway" || die "owner sign-in failed"
printf '%s' 'wrong-password-entirely' > "$TEST_TMP/wrong-pw"
sign_in "$OWNER_EMAIL" "$TEST_TMP/wrong-pw" "$TEST_TMP/nothing" && fail "wrong password accepted" || pass "wrong password refused"
profile=$(rest_as "$TEST_TMP/owner-token" '/rest/v1/profiles?select=account_role,account_id')
assert_eq "the owner owns an account" "owner" "$(jq -r '.[0].account_role' <<<"$profile")"
ACCOUNT_ID=$(jq -r '.[0].account_id' <<<"$profile")
assert_eq "named from ACCOUNT_NAME" "Local Test Company" "$(rest_as "$TEST_TMP/owner-token" '/rest/v1/accounts?select=name' | jq -r '.[0].name')"
assert_eq "the owner's stored metadata holds no bootstrap nonce" "0" \
  "$(psql_admin "select count(*) from auth.users where raw_user_meta_data ? 'wacrm_railway_bootstrap_nonce'")"
assert_eq "and the nonce is gone from the gate" "0" "$(psql_admin "select count(*) from wacrm_railway.settings where key = 'bootstrap_nonce_sha256'")"

section "nobody gets an account without an invitation"
users_before=$(psql_admin 'select count(*) from auth.users')
assert_eq "a stranger's signup is refused" "500" "$(sign_up stranger@example.com "$TEST_TMP/other-pw")"
assert_eq "a signup with a made-up invitation token is refused" "500" "$(sign_up guesser@example.com "$TEST_TMP/other-pw" not-a-real-token)"
assert_eq "a signup that forges the owner's bootstrap nonce is refused" "500" \
  "$(code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$GATEWAY_URL/auth/v1/signup" -H "apikey: $(anon_key)" -H 'Content-Type: application/json' \
      --data "$(jq -nc --rawfile p "$TEST_TMP/other-pw" '{email:"forger@example.com", password:$p, data:{wacrm_railway_bootstrap_nonce:"0000000000000000000000000000000000000000000000000000000000000000"}}')" || true); echo "$code")"
assert_eq "no user was created by any of them" "$users_before" "$(psql_admin 'select count(*) from auth.users')"
assert_eq "and no extra account" "1" "$(psql_admin 'select count(*) from public.accounts')"

section "an invited teammate joins the owner's account"
TOKEN="invite-$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
HASH=$(printf '%s' "$TOKEN" | sha256sum | cut -d' ' -f1)
code=$(http_code -X POST "$GATEWAY_URL/rest/v1/account_invitations" -H "apikey: $(anon_key)" -H "Authorization: Bearer $(cat "$TEST_TMP/owner-token")" \
  -H 'Content-Type: application/json' --data "$(jq -nc --arg a "$ACCOUNT_ID" --arg h "$HASH" '{account_id:$a, token_hash:$h, role:"agent", expires_at:"2099-01-01T00:00:00Z"}')")
assert_eq "the owner creates an invitation" "201" "$code"
printf '%s' 'invited-teammate-password-1' > "$TEST_TMP/invitee-pw"
assert_eq "the invitee's signup is admitted" "200" "$(sign_up invitee@example.com "$TEST_TMP/invitee-pw" "$TOKEN")"
cp "$TEST_TMP/signup-token" "$TEST_TMP/invitee-token"
redeem=$(rest_as "$TEST_TMP/invitee-token" '/rest/v1/rpc/redeem_invitation' -X POST -H 'Content-Type: application/json' --data "$(jq -nc --arg h "$HASH" '{p_token_hash:$h}')")
assert_eq "redeeming it (upstream code) moves them into the owner's account" "\"$ACCOUNT_ID\"" "$redeem"
assert_eq "as an agent" "agent" "$(rest_as "$TEST_TMP/invitee-token" "/rest/v1/profiles?select=account_role&user_id=eq.$(token_sub "$TEST_TMP/invitee-token")" | jq -r '.[0].account_role')"
assert_eq "the used token admits nobody else" "500" "$(sign_up second@example.com "$TEST_TMP/other-pw" "$TOKEN")"
assert_eq "no invitation token is stored in auth.users" "0" "$(psql_admin "select count(*) from auth.users where raw_user_meta_data ? 'invite_token'")"

section "the gateway and the app's own API"
assert_eq "no API key, no entry" "401" "$(http_code "$GATEWAY_URL/rest/v1/profiles")"
assert_eq "the anon key alone reads no profiles" "[]" "$(rest_as anon '/rest/v1/profiles?select=user_id' | jq -c .)"
assert_eq "the REST schema listing is service-role only" "403" "$(http_code "$GATEWAY_URL/rest/v1/" -H "apikey: $(anon_key)")"
assert_eq "Realtime accepts a websocket" "101" "$(http_code --max-time 5 -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "$GATEWAY_URL/realtime/v1/websocket?apikey=$(anon_key)&vsn=1.0.0")"
assert_eq "Realtime's tenant API is blocked" "403" "$(http_code "$GATEWAY_URL/realtime/v1/api/tenants" -H "apikey: $(service_key)")"
assert_eq "the public API refuses a request without a key" "401" "$(http_code "$APP_URL/api/v1/contacts")"
assert_eq "account settings refuse a visitor" "401" "$(http_code "$APP_URL/api/account")"
assert_eq "the dashboard sends a visitor to sign in" "307" "$(http_code "$APP_URL/dashboard")"
assert_eq "an unsigned WhatsApp webhook is refused" "401" "$(http_code -X POST "$APP_URL/api/whatsapp/webhook" -H 'Content-Type: application/json' --data '{}')"

section "the scheduler"
assert_eq "an authorised automations cron call runs" "200" "$(http_code -H "x-cron-secret: $CRON" "$APP_URL/api/automations/cron")"
assert_eq "an authorised flows cron call runs" "200" "$(http_code -H "x-cron-secret: $CRON" "$APP_URL/api/flows/cron")"
assert_eq "an unauthorised one does not" "401" "$(http_code "$APP_URL/api/automations/cron")"
wait_for_log scheduler "flows/cron is answering" 1 300 && pass "the scheduler reaches both endpoints" || fail "scheduler never reached the app"
assert_not_contains "and reports no failures" "WARNING" "$(compose logs --no-color --no-log-prefix scheduler)"
assert_not_contains "the secret is not on curl's command line" "x-cron-secret" "$(compose exec -T scheduler ps -o args 2>/dev/null || true)"

section "restart"
compose restart app >/dev/null
wait_for_log app "starting wacrm" 2 600 && pass "the app came back" || die "the app did not restart"
logs=$(compose logs --no-color --no-log-prefix app)
assert_contains "no migration runs twice" "migrations: 0 applied, $MIGRATIONS already in place" "$logs"
assert_contains "the owner bootstrap is idempotent" "instance already claimed on an earlier start" "$logs"
wait_for_code "$APP_URL/login" 200 300 && pass "serving again" || fail "not serving after restart"
assert_not_contains "still no placeholder after a second fill" "wacrm-railway-" "$(compose exec -T app sh -c 'cat /app/.next/static/chunks/*.js')"

section "graceful shutdown (SIGTERM)"
t1=$(date +%s); compose stop -t 30 app >/dev/null; dur=$(( $(date +%s)-t1 ))
code=$(docker inspect --format '{{.State.ExitCode}}' "$(compose ps -a -q app)")
[ "$dur" -lt 30 ] && pass "the app stopped in ${dur}s without SIGKILL" || fail "the app took ${dur}s to stop"
case "$code" in 0|143) pass "exit status after SIGTERM is $code" ;; *) fail "unexpected exit status $code" ;; esac
compose start app >/dev/null
t2=$(date +%s); compose stop -t 30 scheduler >/dev/null; dur=$(( $(date +%s)-t2 ))
[ "$dur" -lt 10 ] && pass "the scheduler stopped in ${dur}s" || fail "the scheduler took ${dur}s to stop"
compose start scheduler >/dev/null

section "fail-fast validation"
app_img=$(service_image app); kong_img=$(service_image kong); db_img=$(service_image db); sched_img=$(service_image scheduler)
app_env() { compose config --format json | jq -r '.services.app.environment | to_entries[] | "\(.key)=\(.value)"'; }
run_expect() {
  # run_expect LABEL PATTERN IMAGE [docker run args...]
  local label=$1 pat=$2 img=$3; shift 3
  local out rc=0 name="wacrm-failfast-$$-$RANDOM"
  out=$(timeout -k 5 60 docker run --rm --name "$name" "$@" "$img" 2>&1) || rc=$?
  docker rm -f "$name" >/dev/null 2>&1 || true
  if [ "$rc" -ne 0 ] && grep -q -- "$pat" <<<"$out"; then pass "$label"; else fail "$label (exit $rc)"; fi
}
run_expect "app refuses to start without an owner password" "missing required variable: OWNER_PASSWORD" "$app_img" \
  --env-file <(app_env | grep -v '^OWNER_PASSWORD=')
run_expect "app refuses a short ENCRYPTION_KEY" "ENCRYPTION_KEY must be exactly 64 hex" "$app_img" \
  --env-file <(app_env | sed 's/^ENCRYPTION_KEY=.*/ENCRYPTION_KEY=abcd/')
run_expect "app refuses Supabase's example JWT secret" "public .env.example" "$app_img" \
  --env-file <(app_env | sed 's/^JWT_SECRET=.*/JWT_SECRET=your-super-secret-jwt-token-with-at-least-32-characters-long/')
run_expect "app names an unresolved gateway reference" "SUPABASE_INTERNAL_URL has no host name" "$app_img" \
  --env-file <(app_env | sed 's|^SUPABASE_INTERNAL_URL=.*|SUPABASE_INTERNAL_URL=http://:8000|')
run_expect "Kong names an unresolved upstream reference" "AUTH_HOST is empty" "$kong_img" -e JWT_SECRET="$JWT" -e AUTH_HOST=
run_expect "the database refuses a short password" "at least 32 characters" "$db_img" -e POSTGRES_PASSWORD=short
run_expect "the scheduler refuses a short secret" "at least 32 characters" "$sched_img" -e AUTOMATION_CRON_SECRET=short
run_expect "the scheduler names an unresolved app reference" "WACRM_APP_ORIGIN has no host name" "$sched_img" \
  -e AUTOMATION_CRON_SECRET="$CRON" -e WACRM_APP_ORIGIN=http://:3000
run_expect "the scheduler refuses an origin the shell would interpret" "may contain only" "$sched_img" \
  -e AUTOMATION_CRON_SECRET="$CRON" -e 'WACRM_APP_ORIGIN=http://app:3000/$(id)'
summary
