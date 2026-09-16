#!/bin/sh
# Apply wacrm's database migrations to the bundled Supabase, then the invite-only signup gate.
#
# Upstream keeps ordered migrations in supabase/migrations and expects the operator to run
# `supabase db push` from their own machine. Its CI replays every file, in filename order, against
# an empty database, so that order is what is reproduced here:
#
#   - each file not yet recorded in wacrm_railway.applied_migrations runs in its own transaction,
#     with ON_ERROR_STOP, and is recorded in the same transaction. A failure leaves nothing half
#     applied and stops the start, because an app running on a partial schema can run without the
#     row-level security later migrations add.
#   - a file that was applied before is never run again. If its content has changed since, that is
#     logged as a warning: upstream edited a migration after release.
#
# Migrations run as the `postgres` role, as `supabase db push` does, so objects are owned by the role
# upstream expects. A Postgres advisory lock keeps two starting replicas from applying the same file.
set -u
log()  { printf '[wacrm-migrate] %s\n' "$*"; }
fail() { printf '[wacrm-migrate] FATAL: %s\n' "$*" >&2; exit 1; }

DB="${SUPABASE_DB_URL:?SUPABASE_DB_URL is required}"
DIR="${WACRM_MIGRATIONS_DIR:-/opt/wacrm/migrations}"
GATE="${WACRM_GATE_SQL:-/opt/wacrm/gate.sql}"
LOCK=4151234

ls "$DIR"/*.sql >/dev/null 2>&1 || fail "no migrations found in $DIR"

psql "$DB" -v ON_ERROR_STOP=1 -qc "
  create schema if not exists wacrm_railway;
  revoke all on schema wacrm_railway from public;
  create table if not exists wacrm_railway.applied_migrations (
    name text primary key,
    sha256 text not null,
    applied_at timestamptz not null default now()
  );" >/dev/null 2>&1 || fail "could not create the migration record"

applied=0
skipped=0
for file in "$DIR"/*.sql; do
  name=$(basename "$file")
  case "$name" in *[!A-Za-z0-9._-]*) fail "unexpected migration file name: $name" ;; esac
  sum=$(sha256sum "$file" | cut -d' ' -f1)
  recorded=$(psql "$DB" -tAc "select sha256 from wacrm_railway.applied_migrations where name = '$name'" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$recorded" ]; then
    [ "$recorded" = "$sum" ] || log "WARNING: $name changed after it was applied; it is not run again"
    skipped=$((skipped + 1))
    continue
  fi
  out=$(
    {
      printf 'select pg_advisory_xact_lock(%s);\n' "$LOCK"
      printf '\\i %s\n' "$file"
      printf "insert into wacrm_railway.applied_migrations (name, sha256) values ('%s', '%s');\n" "$name" "$sum"
    } | psql "$DB" -v ON_ERROR_STOP=1 --single-transaction -q 2>&1
  ) || { printf '%s\n' "$out" | grep -E 'ERROR|FATAL' | head -5 >&2; fail "migration $name failed; nothing from it was kept"; }
  applied=$((applied + 1))
done
log "migrations: $applied applied, $skipped already in place"

# Upstream's CI asserts the outcome, not just the absence of errors: every DDL statement is guarded
# with IF NOT EXISTS, which turns a mistake into a silent no-op. Run the same check here.
VERIFY="${WACRM_VERIFY_SQL:-/opt/wacrm/verify-schema.sql}"
if [ -r "$VERIFY" ]; then
  out=$(psql "$DB" -v ON_ERROR_STOP=1 -q -f "$VERIFY" 2>&1) \
    || { printf '%s\n' "$out" | grep -E 'ERROR|EXCEPTION' | head -3 >&2; fail "upstream's schema check failed"; }
  log "schema verified by upstream's check"
fi

mode="${WACRM_SIGNUP_MODE:-invite-only}"
case "$mode" in invite-only|open) ;; *) fail "WACRM_SIGNUP_MODE must be invite-only or open, got \"$mode\"" ;; esac
psql "$DB" -v ON_ERROR_STOP=1 -q -f "$GATE" >/dev/null 2>&1 || fail "could not install the signup gate"
psql "$DB" -v ON_ERROR_STOP=1 -qc "
  insert into wacrm_railway.settings (key, value) values ('signup_mode', '$mode')
  on conflict (key) do update set value = excluded.value, updated_at = now();" >/dev/null 2>&1 \
  || fail "could not record the signup mode"
log "signup: $mode"

# PostgREST caches the schema; ask it to reload so new tables are reachable at once.
psql "$DB" -qc "notify pgrst, 'reload schema';" >/dev/null 2>&1 || true
