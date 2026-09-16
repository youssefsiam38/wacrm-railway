#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # single-quoted literals are matched, not expanded
# Static validation: syntax, shellcheck, compose, image pins, key minting, security defaults.
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd); export REPO_ROOT
cd "$REPO_ROOT"
# shellcheck source=tests/lib.sh
. "$REPO_ROOT/tests/lib.sh"

section "syntax"
for f in images/*/*.sh tests/*.sh; do
  if bash -n "$f" 2>/dev/null; then pass "parses: $f"; else fail "syntax error: $f"; fi
done
for f in lib/*.mjs images/*/*.mjs; do
  if node --check "$f" 2>/dev/null; then pass "parses: $f"; else fail "syntax error: $f"; fi
done
if perl -c images/kong/mint-keys.pl >/dev/null 2>&1; then pass "parses: images/kong/mint-keys.pl"; else fail "syntax error: images/kong/mint-keys.pl"; fi

section "shellcheck"
if command -v shellcheck >/dev/null; then
  if shellcheck images/*/*.sh; then pass "shellcheck images"; else fail "shellcheck images"; fi
  if shellcheck -x -s bash tests/*.sh; then pass "shellcheck tests"; else fail "shellcheck tests"; fi
else
  echo "  SKIP  shellcheck not installed"
fi

section "compose"
if docker compose -f compose.yaml config -q; then pass "compose config"; else fail "compose config"; fi
cfg=$(docker compose -f compose.yaml config --format json)
assert_eq "eight services, as on Railway" "8" "$(jq '.services | length' <<<"$cfg")"
assert_eq "only the app and the gateway publish ports" "app kong" \
  "$(jq -r '[.services | to_entries[] | select(.value.ports) | .key] | sort | join(" ")' <<<"$cfg")"
assert_eq "published ports bind to loopback" "127.0.0.1 127.0.0.1" \
  "$(jq -r '[.services[] | .ports[]? | .host_ip] | join(" ")' <<<"$cfg")"
for svc in auth rest realtime; do
  img=$(jq -r --arg s "$svc" '.services[$s].image' <<<"$cfg")
  [[ "$img" == *:*@sha256:* ]] && pass "$svc pinned by tag and digest" || fail "$svc image not pinned: $img"
done
assert_eq "PostgREST listens dual-stack" "*6" "$(jq -r '.services.rest.environment.PGRST_SERVER_HOST' <<<"$cfg")"
assert_eq "the test network has IPv6, like Railway's" "true" "$(jq -r '.networks.default.enable_ipv6' <<<"$cfg")"

section "images are pinned"
for df in images/*/Dockerfile; do
  base=$(grep -E '^ARG [A-Z_]+_IMAGE=' "$df")
  [ -n "$base" ] || { fail "$df has no pinned base image argument"; continue; }
  if grep -vqE '@sha256:[0-9a-f]{64}$' <<<"$base"; then fail "$df base image lacks a digest"; else pass "$df base pinned by digest"; fi
done
app_df=$(cat images/app/Dockerfile)
assert_contains "wacrm pinned to a full commit id" 'ARG WACRM_COMMIT=[0-9a-f]\{40\}$' "$app_df"
assert_contains "the fetched commit is verified" 'test "$(git -C /src rev-parse HEAD)" = "${WACRM_COMMIT}"' "$app_df"
assert_contains "the signup patch runs in the build" 'patch-signup.mjs' "$app_df"
assert_contains "the build fails if no placeholder was inlined" "grep -q 'static/' /opt/wacrm/pristine/.index" "$app_df"
for v in JWT_SECRET POSTGRES_PASSWORD OWNER_PASSWORD ENCRYPTION_KEY META_APP_SECRET AUTOMATION_CRON_SECRET SUPABASE_SERVICE_ROLE_KEY; do
  if grep -qE "^\s+$v=|^ENV $v=|ARG $v" images/*/Dockerfile; then fail "$v is baked into an image"; else pass "no $v in any image"; fi
done

section "the key minters agree"
# Kong's key-auth compares API keys as strings, so every minter must produce byte-identical keys.
secret=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
node_out=$(JWT_SECRET="$secret" node lib/mint-supabase-keys.mjs)
perl_out=$(JWT_SECRET="$secret" perl images/kong/mint-keys.pl)
assert_eq "node and perl minters produce identical keys" "$(sha256sum <<<"$node_out" | cut -c1-16)" "$(sha256sum <<<"$perl_out" | cut -c1-16)"
anon=$(sed -n 's/^ANON_KEY=//p' <<<"$node_out")
b64url_decode() { local s=${1//-/+}; s=${s//_//}; while [ $(( ${#s} % 4 )) -ne 0 ]; do s="$s="; done; base64 -d <<<"$s"; }
assert_eq "anon key carries the anon role" "anon" "$(jq -r .role <<<"$(b64url_decode "$(cut -d. -f2 <<<"$anon")")")"
sig_openssl=$(printf '%s' "$(cut -d. -f1-2 <<<"$anon")" | openssl dgst -sha256 -hmac "$secret" -binary | base64 | tr '+/' '-_' | tr -d '=')
assert_eq "signature verifies independently with openssl" "$sig_openssl" "$(cut -d. -f3 <<<"$anon")"
if JWT_SECRET=short node lib/mint-supabase-keys.mjs >/dev/null 2>&1; then fail "node minter accepted a short secret"; else pass "node minter refuses a short secret"; fi

section "signup is invite-only"
gate=$(cat images/app/gate.sql)
assert_contains "the gate is a BEFORE INSERT trigger on auth.users" 'before insert on auth.users' "$gate"
assert_contains "it admits a pending, unexpired invitation" 'expires_at > now()' "$gate"
assert_contains "it compares invitation tokens by hash, as upstream stores them" "encode(sha256(convert_to(v_token, 'UTF8')), 'hex')" "$gate"
assert_contains "the owner nonce is single-use" "delete from wacrm_railway.settings" "$gate"
assert_contains "invite-only unless opened" "coalesce(v_mode, 'invite-only') = 'open'" "$gate"
assert_contains "nothing admitting is kept in auth.users" 'before update on auth.users' "$gate"
migrate=$(cat images/app/migrate.sh)
assert_contains "each migration runs in its own transaction" '--single-transaction' "$migrate"
assert_contains "a failed migration stops the start" 'nothing from it was kept' "$migrate"
assert_contains "the signup mode defaults to invite-only" 'mode="${WACRM_SIGNUP_MODE:-invite-only}"' "$migrate"
patch=$(cat images/app/patch-signup.mjs)
assert_contains "the signup patch requires exactly one match" 'matches.length !== 1' "$patch"
fill=$(cat images/app/fill-public-env.mjs)
assert_contains "public values are checked against strict shapes" 'SHAPES' "$fill"
assert_contains "a placeholder left over stops the start" 'still carry a placeholder' "$fill"
ep=$(cat images/app/entrypoint.sh)
assert_contains "the app refuses Supabase's example JWT secret" 'your-super-secret-jwt-token-with-at-least-32-characters-long' "$ep"
assert_contains "ENCRYPTION_KEY must be 64 hex" "ENCRYPTION_KEY must be exactly 64 hex characters" "$ep"
assert_contains "the nonce is removed whatever happens" "delete from wacrm_railway.settings where key = 'bootstrap_nonce_sha256'" "$ep"
assert_contains "invite links are pinned to the site's host" 'ALLOWED_INVITE_HOSTS=' "$ep"
assert_contains "the owner bootstrap leaves a claimed instance alone" 'already claimed' "$(cat images/app/bootstrap-owner.mjs)"

section "gateway and scheduler"
kong_df=$(cat images/kong/Dockerfile)
kong_ep=$(cat images/kong/entrypoint.sh)
assert_contains "Kong admin API off" 'KONG_ADMIN_LISTEN=off' "$kong_ep"
assert_contains "Kong access log off (Realtime puts the API key in the URL)" 'KONG_PROXY_ACCESS_LOG=off' "$kong_df"
assert_contains "Kong request debugging off" 'KONG_REQUEST_DEBUG=off' "$kong_df"
assert_contains "Kong refuses an unresolved upstream host" 'had not resolved' "$kong_ep"
sched=$(cat images/scheduler/entrypoint.sh)
assert_contains "the cron secret reaches curl on stdin, not argv" 'curl -K -' "$sched"
assert_contains "the scheduler refuses an origin the shell would interpret" 'may contain only letters' "$sched"
assert_contains "the vault key lives on the data volume" '/var/lib/postgresql/data/pgsodium_root.key' "$(cat images/db/getkey.sh)"

section "log streams"
# Railway colours a log line by the stream it arrived on: routine lines on stderr show as errors.
for f in images/*/entrypoint.sh images/app/migrate.sh; do
  if grep -q '^log()' "$f" && ! grep '^log()' "$f" | grep -q '>&2'; then pass "routine logs go to stdout: $f"; else fail "log() writes to stderr: $f"; fi
  if grep '^fail()' "$f" | grep -q '>&2'; then pass "failures go to stderr: $f"; else fail "fail() does not write to stderr: $f"; fi
done

section "the tests point at the right image"
if grep -qE 'config --images' tests/smoke.sh tests/persistence.sh; then
  fail "a test selects an image by sort order rather than by service name"
else
  pass "images under test are selected by service name"
fi

section "workflows"
for wf in .github/workflows/*.yml; do
  if grep -qE 'uses: .*@[0-9a-f]{40}' "$wf" && ! grep -qE 'uses: [^#]*@v[0-9]+\s*$' "$wf"; then
    pass "actions pinned by SHA in $wf"
  else
    fail "unpinned action in $wf"
  fi
done
for c in db kong storage app scheduler; do
  var="WACRM_RAILWAY_$(tr '[:lower:]' '[:upper:]' <<<"$c")_IMAGE"
  assert_contains "compose lets CI override the $c image" "$var" "$(cat compose.yaml)"
  assert_contains "the publish workflow tests the $c candidate" "$var" "$(cat .github/workflows/publish-image.yml)"
done

section "no tracked secrets"
if git rev-parse --git-dir >/dev/null 2>&1; then
  if git grep -nIE '(BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|github_pat_|xox[baprs]-|sk-[A-Za-z0-9]{32,}|eyJhbGciOi)' -- . ':!tests/static.sh' >/dev/null 2>&1; then
    fail "credential pattern in tracked files"
  else
    pass "no credential patterns in tracked files"
  fi
  if git ls-files --error-unmatch .env >/dev/null 2>&1; then fail ".env is tracked"; else pass ".env not tracked"; fi
else
  echo "  SKIP  not a git checkout"
fi
summary
