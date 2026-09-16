// Create wacrm's owner account before the app serves anything.
//
// Signup is invite-only (gate.sql), and an invitation can only be issued from inside an account, so a
// fresh instance needs its first user created some other way. Upstream has no such step: its first
// user is whoever signs up. Here the owner is created through Supabase Auth's admin API with the
// service-role key, over the private network, carrying the one-time nonce the entrypoint registered
// with the gate (WACRM_BOOTSTRAP_NONCE). Upstream's own signup trigger then gives that user an account
// and the `owner` role, exactly as it would for a self-service signup.
//
// Once any user exists the instance is claimed and this exits without touching anything, so a
// redeploy never undoes a password change made in the app. RECOVERY: set a new OWNER_PASSWORD with
// WACRM_RESET_OWNER_PASSWORD=true and redeploy; the log says to remove the switch afterwards.
//
// Secrets come from the environment and are never printed; the e-mail is masked.

const BASE = (process.env.SUPABASE_INTERNAL_URL ?? "").replace(/\/+$/, "");
const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY ?? "";
const EMAIL = (process.env.OWNER_EMAIL ?? "").trim();
const PASSWORD = process.env.OWNER_PASSWORD ?? "";
const NAME = (process.env.OWNER_NAME ?? "").trim() || "Owner";
const ACCOUNT = (process.env.ACCOUNT_NAME ?? "").trim();
const NONCE = process.env.WACRM_BOOTSTRAP_NONCE ?? "";

const log = (m) => process.stdout.write(`[wacrm-bootstrap] ${m}\n`);
const warn = (m) => process.stderr.write(`[wacrm-bootstrap] WARNING: ${m}\n`);
const die = (m) => {
  process.stderr.write(`[wacrm-bootstrap] FATAL: ${m}\n`);
  process.exit(1);
};
const masked = EMAIL.replace(/^(.).*(@.*)$/, "$1***$2");

if (!BASE || !SERVICE) die("SUPABASE_INTERNAL_URL and SUPABASE_SERVICE_ROLE_KEY are required");
if (!EMAIL || !PASSWORD) die("OWNER_EMAIL and OWNER_PASSWORD are required");
if (!/^[0-9a-f]{64}$/.test(NONCE)) die("WACRM_BOOTSTRAP_NONCE is missing; the entrypoint registers it");

async function call(method, path, body, extra = {}) {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, "Content-Type": "application/json", ...extra },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = null;
  }
  if (!res.ok) {
    // Report the status and Supabase's own error code only; a body can echo the request.
    const code = json && (json.code || json.error_code || json.error) ? ` (${json.code || json.error_code || json.error})` : "";
    throw new Error(`${method} ${path.split("?")[0]} -> HTTP ${res.status}${code}`);
  }
  return json;
}

async function findUserByEmail(email) {
  for (let page = 1; page <= 50; page++) {
    const data = await call("GET", `/auth/v1/admin/users?page=${page}&per_page=200`);
    const users = (data && data.users) || [];
    const hit = users.find((u) => (u.email ?? "").toLowerCase() === email.toLowerCase());
    if (hit) return hit;
    if (users.length < 200) return null;
  }
  return null;
}

try {
  const first = await call("GET", "/auth/v1/admin/users?page=1&per_page=1");
  const claimed = ((first && first.users) || []).length > 0;

  if (claimed) {
    if ((process.env.WACRM_RESET_OWNER_PASSWORD ?? "").trim() === "true") {
      const user = await findUserByEmail(EMAIL);
      if (!user) {
        warn("WACRM_RESET_OWNER_PASSWORD is set but no account has OWNER_EMAIL; nothing reset");
      } else {
        await call("PUT", `/auth/v1/admin/users/${user.id}`, { password: PASSWORD });
        warn("owner password reset from OWNER_PASSWORD. Remove WACRM_RESET_OWNER_PASSWORD now, or every redeploy will reset it again.");
      }
    } else {
      log("instance already claimed on an earlier start; leaving accounts alone");
    }
    process.exit(0);
  }

  const user = await call("POST", "/auth/v1/admin/users", {
    email: EMAIL,
    password: PASSWORD,
    email_confirm: true,
    user_metadata: { full_name: NAME, wacrm_railway_bootstrap_nonce: NONCE },
  });
  if (!user || !user.id) die("Supabase Auth did not return the new owner");
  log("owner account created");

  // Upstream's signup trigger swallows its own failures (it logs a warning and returns), which would
  // leave a user who can sign in to nothing. Check that the account and owner profile exist.
  const profiles = await call("GET", `/rest/v1/profiles?user_id=eq.${user.id}&select=account_id,account_role`);
  const profile = Array.isArray(profiles) ? profiles[0] : null;
  if (!profile || profile.account_role !== "owner" || !profile.account_id) {
    die("the owner has no account; upstream's signup trigger did not run. Check the migrations in the log above.");
  }
  if (ACCOUNT) {
    await call("PATCH", `/rest/v1/accounts?id=eq.${profile.account_id}`, { name: ACCOUNT }, { Prefer: "return=minimal" });
  }
  log(`instance claimed for ${masked}`);
} catch (err) {
  die(err.message);
}
