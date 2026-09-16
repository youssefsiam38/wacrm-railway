# Maintenance

## Release process

1. Make the change on a branch. The `test` workflow builds every image and runs the full suite on every
   push and pull request.
2. Run locally:
   ```bash
   docker compose build --pull
   tests/static.sh && tests/smoke.sh && tests/persistence.sh
   ```
3. Tag `vX.Y.Z`. The `publish-image` workflow builds all five images as local candidates, runs the smoke
   and persistence suites against the whole bundle of candidates, and only then retags and pushes those
   exact images to GHCR as `X.Y.Z`, `X.Y` and `latest`.
4. Update the Railway template (id in `RAILWAY_TEMPLATE.md`): the image tag of `app`, `scheduler`,
   `kong`, `db` and `storage`, with `templateChangeSetStage` then `templateChangeSetApply`. Tags only; the
   generator rejects digests. Republish the overview with
   `railway templates update <id> --readme-file marketplace/OVERVIEW.md` if it changed.
5. Deploy the updated template into a scratch project, run
   `tests/railway-smoke.sh https://<app> https://<kong>`, then delete the scratch project.

The five images are versioned together, so the template never mixes wrapper versions.

## Bumping wacrm

Upstream has no release tags; it merges to `main` often. Move to a new commit deliberately.

1. Read the commits and `CHANGELOG.md` between the pinned commit and the candidate.
2. Change `ARG WACRM_COMMIT` (and `WACRM_VERSION` from `package.json`) in `images/app/Dockerfile`.
3. Build. The build fails, by design, if:
   - the signup page no longer has exactly one `data: { full_name: fullName }` block, or no longer reads
     `?invite=` (`patch-signup.mjs`);
   - no built file carries a placeholder (`fill-public-env.mjs --index`).
4. Run the suites. New migrations are applied on the next start of existing deployments; a migration
   that fails stops the start and keeps nothing from that file.
5. Check the list below.

### Breaking-change checklist

- [ ] New `NEXT_PUBLIC_*` variables in `src/`: each needs a placeholder or a fixed build value.
- [ ] New required server variables (`grep -rhoE 'process\.env\.[A-Z0-9_]+' src`): add them to the
      template and `compose.yaml`.
- [ ] `handle_new_user` still creates an account and an `owner` profile for every new user; the owner
      bootstrap checks for exactly that.
- [ ] `account_invitations.token_hash` is still the hex SHA-256 of the token, and invitations still have
      `accepted_at` and `expires_at`; `gate.sql` depends on all three.
- [ ] Signup still goes through Supabase Auth (a new OAuth or magic-link path is gated too, but its
      metadata will not carry `invite_token` unless it is sent).
- [ ] `/api/automations/cron` and `/api/flows/cron` still take `x-cron-secret`; add any new cron route to
      the scheduler.
- [ ] No migration file was edited in place after release (the migrator warns but does not re-run it).

## Bumping the Supabase stack

Keep it in step with the DeskcommCRM template, which shares the `db`, `kong` and `storage` wrappers. Take
versions from `supabase/supabase/docker` at one commit, re-copy `volumes/db/*.sql`, diff
`volumes/api/kong.yml`, and record the commit in `UPSTREAM.md`.

## What to watch

| Source | Why |
|---|---|
| https://github.com/ArnasDon/wacrm/commits/main | New migrations, variables, signup or invitation changes. |
| wacrm `supabase/ci/verify-schema.sql` | Runs at every start; a stricter check can stop a start that used to pass. |
| https://github.com/supabase/supabase/blob/master/docker/CHANGELOG.md | Self-hosting changes, especially keys and the gateway. |
| https://developers.facebook.com/docs/whatsapp/cloud-api/changelog | Graph API versions wacrm calls. |

## Rolling back

Republish the template with the previous image tags. **The database does not roll back**: migrations a
newer image applied stay applied. Restore the `db` volume from a backup taken before the upgrade if the
older app cannot run on the newer schema.

## Backups

Railway volume backups cover `db` and `storage`. The `db` volume holds the Vault root key file next to the
cluster; restore them together.

## If this repository is abandoned

Everything here is small: two Dockerfiles for wacrm and its scheduler, three Supabase wrappers, a handful
of scripts and the tests. Fork it, change the image `source` labels and GHCR paths, and publish your own
template.
