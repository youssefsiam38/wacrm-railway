// Build-time patch to wacrm's signup page: also send the invitation token, when the page has one,
// as user metadata (`invite_token`). The page already holds the token; upstream only uses it for
// the post-verification redirect. With it in the metadata, the database gate (gate.sql) can admit
// an invited person and refuse everyone else.
//
// Exactly one match or the build fails: a silent no-op here would ship a template in which invited
// teammates cannot sign up.
import { readFileSync, writeFileSync } from "node:fs";

const file = process.argv[2];
const src = readFileSync(file, "utf8");
const pattern = /data:\s*\{\s*full_name:\s*fullName,\s*\}/g;
const matches = src.match(pattern) ?? [];
if (matches.length !== 1) {
  process.stderr.write(`patch-signup: expected exactly one signUp metadata block in ${file}, found ${matches.length}\n`);
  process.exit(1);
}
if (!/const inviteToken = searchParams\.get\("invite"\);/.test(src)) {
  process.stderr.write(`patch-signup: ${file} no longer reads the invite token from ?invite=\n`);
  process.exit(1);
}
const patched = src.replace(
  pattern,
  "data: {\n          full_name: fullName,\n          ...(inviteToken ? { invite_token: inviteToken } : {}),\n        }",
);
writeFileSync(file, patched);
process.stdout.write("patch-signup: signup sends invite_token with the user metadata\n");
