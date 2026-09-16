#!/bin/sh
# wacrm-railway scheduler: calls wacrm's two cron endpoints on a fixed interval.
#
# wacrm schedules nothing itself. Automation "Wait" steps and flows only advance when something calls
# GET /api/automations/cron and GET /api/flows/cron with the shared secret in `x-cron-secret`;
# upstream leaves that to Vercel Cron or an external pinger. This is that pinger, on the private
# network.
#
# The secret is handed to curl on stdin (`-K -`), not on its command line, where any process in the
# container could read it. Failures are logged when they start and when they end, not every minute.
set -eu
log()  { printf '[wacrm-scheduler] %s\n' "$*"; }
fail() { printf '[wacrm-scheduler] FATAL: %s\n' "$*" >&2; exit 1; }
warn() { printf '[wacrm-scheduler] WARNING: %s\n' "$*" >&2; }

[ -n "${AUTOMATION_CRON_SECRET:-}" ] || fail "missing required variable: AUTOMATION_CRON_SECRET"
[ "${#AUTOMATION_CRON_SECRET}" -ge 32 ] || fail "AUTOMATION_CRON_SECRET must be at least 32 characters"
if printf '%s' "$AUTOMATION_CRON_SECRET" | grep -q '[^A-Za-z0-9._-]'; then
  fail "AUTOMATION_CRON_SECRET may contain only letters, digits and . _ -"
fi
: "${WACRM_APP_ORIGIN:=http://app:3000}"
case "$WACRM_APP_ORIGIN" in
  http://:*|https://:*|http://|https://)
    fail "WACRM_APP_ORIGIN has no host name. On Railway this is a reference to the app's private domain that had not resolved when this deployment started; redeploy once the app has deployed." ;;
  http://*|https://*) ;;
  *) fail "WACRM_APP_ORIGIN must start with http:// or https://" ;;
esac
if printf '%s' "$WACRM_APP_ORIGIN" | grep -q '[^]A-Za-z0-9.:/[-]'; then
  fail "WACRM_APP_ORIGIN may contain only letters, digits and . : / [ ] -"
fi
WACRM_APP_ORIGIN="${WACRM_APP_ORIGIN%/}"
: "${WACRM_CRON_INTERVAL:=60}"
case "$WACRM_CRON_INTERVAL" in ''|*[!0-9]*) fail "WACRM_CRON_INTERVAL must be a number of seconds" ;; esac
[ "$WACRM_CRON_INTERVAL" -ge 15 ] || fail "WACRM_CRON_INTERVAL must be at least 15 seconds"

trap 'log "stopping"; exit 0' TERM INT

ping_path() {
  printf 'header = "x-cron-secret: %s"\n' "$AUTOMATION_CRON_SECRET" \
    | curl -K - -s -o /dev/null -w '%{http_code}' -m 55 "$WACRM_APP_ORIGIN$1" 2>/dev/null || true
}

log "calling /api/automations/cron and /api/flows/cron on ${WACRM_APP_ORIGIN} every ${WACRM_CRON_INTERVAL}s; waiting for the app to answer"
# Per endpoint: waiting (never answered yet, the app is still starting), ok, or failing. An unreachable
# app is normal while it starts, so it is only reported once the app has answered at least once.
# shellcheck disable=SC2034  # read through eval in the loop below
state_automations=waiting
# shellcheck disable=SC2034  # read through eval in the loop below
state_flows=waiting
while :; do
  for job in automations flows; do
    code=$(ping_path "/api/$job/cron")
    eval "prev=\$state_$job"
    # shellcheck disable=SC2154  # prev is assigned by the eval above
    case "$code" in
      2??)
        [ "$prev" = ok ] || log "/api/$job/cron is answering"
        eval "state_$job=ok" ;;
      000|'')
        if [ "$prev" = ok ]; then
          warn "/api/$job/cron is not reachable; the app may be restarting"
          eval "state_$job=failing"
        fi ;;
      *)
        [ "$prev" = failing ] || warn "/api/$job/cron answered $code (401: the secret differs from the app's; 503: the app has no AUTOMATION_CRON_SECRET)"
        eval "state_$job=failing" ;;
    esac
  done
  sleep "$WACRM_CRON_INTERVAL" &
  wait $!
done
