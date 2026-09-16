#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # single-quoted literals are matched, not expanded
# Persistence: data written before the containers are destroyed is there after they are recreated,
# and nothing the first boot does is repeated over it.
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd); export REPO_ROOT
# shellcheck source=tests/lib.sh
. "$REPO_ROOT/tests/lib.sh"
umask 077

JWT='local-test-only-jwt-secret-000000000000000000000000000000'
OWNER_EMAIL='owner@example.com'
mint_keys "$JWT"
printf '%s' 'local-test-only-owner-password' > "$TEST_TMP/initial-pw"
printf '%s' "changed-in-the-app-$(date +%s)" > "$TEST_TMP/changed-pw"
SVC=$(service_key)

section "stack up"
compose up -d --no-build >/dev/null
wait_for_code "$APP_URL/login" 200 "$TEST_TIMEOUT" && pass "serving" || die "the app never became ready"

section "write state"
sign_in "$OWNER_EMAIL" "$TEST_TMP/initial-pw" "$TEST_TMP/token" && pass "owner signs in with the generated password" \
  || die "owner could not sign in with the initial password; run tests/smoke.sh first for a fresh stack"
code=$(http_code -X PUT "$GATEWAY_URL/auth/v1/user" -H "apikey: $(anon_key)" -H "Authorization: Bearer $(cat "$TEST_TMP/token")" \
  -H 'Content-Type: application/json' --data "$(jq -nc --rawfile p "$TEST_TMP/changed-pw" '{password:$p}')")
assert_eq "owner changes their password, as they would in the app" "200" "$code"
me=$(rest_as "$TEST_TMP/token" '/rest/v1/profiles?select=account_id,user_id')
ACCOUNT_ID=$(jq -r '.[0].account_id' <<<"$me"); USER_ID=$(jq -r '.[0].user_id' <<<"$me")
code=$(http_code -X POST "$GATEWAY_URL/rest/v1/contacts" -H "apikey: $(anon_key)" -H "Authorization: Bearer $(cat "$TEST_TMP/token")" \
  -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg a "$ACCOUNT_ID" --arg u "$USER_ID" '{account_id:$a, user_id:$u, name:"Persistence Probe", phone:"+15550100100"}')")
assert_eq "a contact is created under row-level security" "201" "$code"
head -c 3072 /dev/urandom | base64 > "$TEST_TMP/object.bin"  # text/plain: the bucket only takes the media types WhatsApp sends
want=$(sha256sum < "$TEST_TMP/object.bin" | cut -d' ' -f1)
assert_eq "a file is stored in the chat-media bucket" "200" "$(http_code -X POST "$GATEWAY_URL/storage/v1/object/chat-media/persistence/probe.bin" \
  -H "apikey: $SVC" -H "Authorization: Bearer $SVC" -H 'Content-Type: text/plain' --data-binary "@$TEST_TMP/object.bin")"
probe="vault-probe-$(date +%s)"
psql_admin "select vault.create_secret('$probe', '$probe')" >/dev/null
assert_eq "a secret is stored in Supabase Vault" "1" "$(psql_admin "select count(*) from vault.decrypted_secrets where decrypted_secret = '$probe'")"

section "destroy and recreate every container (volumes kept)"
compose down >/dev/null
compose up -d --no-build >/dev/null
wait_for_code "$APP_URL/login" 200 "$TEST_TIMEOUT" && pass "serving again" || die "the app did not come back"
logs=$(compose logs --no-color --no-log-prefix app)
assert_contains "no migration runs again" "migrations: 0 applied" "$logs"
assert_contains "the owner bootstrap does not run again" "instance already claimed on an earlier start" "$logs"
assert_not_contains "no new owner" "owner account created" "$logs"

section "state survived"
sign_in "$OWNER_EMAIL" "$TEST_TMP/changed-pw" "$TEST_TMP/token2" && pass "the changed password still works" || fail "the changed password was lost"
sign_in "$OWNER_EMAIL" "$TEST_TMP/initial-pw" "$TEST_TMP/nothing" && fail "a redeploy reset the owner's password" || pass "a redeploy did not reset the owner's password"
assert_eq "the contact is still there" "Persistence Probe" "$(rest_as "$TEST_TMP/token2" '/rest/v1/contacts?select=name&phone=eq.%2B15550100100' | jq -r '.[0].name')"
got=$(curl -s --max-time 30 "$GATEWAY_URL/storage/v1/object/chat-media/persistence/probe.bin" -H "apikey: $SVC" -H "Authorization: Bearer $SVC" | sha256sum | cut -d' ' -f1)
assert_eq "the stored file is intact" "$want" "$got"
assert_eq "Vault still decrypts with the key kept on the data volume" "1" "$(psql_admin "select count(*) from vault.decrypted_secrets where decrypted_secret = '$probe'")"
assert_eq "the signup gate is still in place" "t" "$(psql_admin "select exists(select 1 from pg_trigger where tgname = 'wacrm_railway_gate_new_user')")"
assert_eq "still one account" "1" "$(psql_admin 'select count(*) from public.accounts')"

section "operator password recovery"
printf '%s' "recovered-by-operator-$(date +%s)" > "$TEST_TMP/recovered-pw"
cat > "$TEST_TMP/reset.override.yaml" <<YAML
services:
  app:
    environment:
      OWNER_PASSWORD: $(cat "$TEST_TMP/recovered-pw")
      WACRM_RESET_OWNER_PASSWORD: "true"
YAML
docker compose -f "$REPO_ROOT/compose.yaml" -f "$TEST_TMP/reset.override.yaml" up -d --no-build app >/dev/null
wait_for_log app "owner password reset from OWNER_PASSWORD" 1 300 && pass "the reset is applied and the log says to remove the switch" || fail "no reset logged"
wait_for_log app "starting wacrm" 1 300 || true
wait_for_code "$APP_URL/login" 200 300 || true
sign_in "$OWNER_EMAIL" "$TEST_TMP/recovered-pw" "$TEST_TMP/token3" && pass "the owner signs in with the recovered password" || fail "recovered password refused"
sign_in "$OWNER_EMAIL" "$TEST_TMP/changed-pw" "$TEST_TMP/nothing" && fail "the old password still works" || pass "the old password no longer works"
compose up -d --no-build app >/dev/null
wait_for_log app "leaving accounts alone" 1 300 && pass "without the switch, accounts are left alone again" || fail "the switch did not turn off"
summary
