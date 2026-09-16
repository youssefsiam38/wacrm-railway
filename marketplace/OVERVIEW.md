# Deploy and Host wacrm on Railway

wacrm is an open-source CRM for WhatsApp, built on Meta's official WhatsApp Business Platform. A team
works one shared inbox with assignment and notes, keeps contacts and custom fields, moves deals through
Kanban pipelines, sends approved-template broadcasts, and builds no-code automations and flows. An
optional AI assistant drafts or sends replies with your own OpenAI or Anthropic key. This is a
community-maintained template; it is not affiliated with the wacrm project.

## About Hosting wacrm

wacrm is a Next.js app on Supabase. Upstream expects a Supabase Cloud project, migrations pushed from your
own machine with the Supabase CLI, and an image built with your Supabase URL and key compiled in. This
template runs everything on Railway instead, in one project: a self-hosted Supabase (Postgres, Auth,
PostgREST, Realtime, Storage and the Kong gateway), wacrm itself, and a small scheduler, eight services
in all, with nothing to sign up for first.

The first start does upstream's manual steps for you. It waits for Supabase's own services, applies all of
wacrm's migrations in order, each in its own transaction, runs upstream's schema check, creates your owner
account from the e-mail you enter, writes this deployment's Supabase URL and key into the built app, and
only then starts serving.

It also closes something upstream leaves open. In wacrm, anyone who finds the signup page gets a working
CRM account of their own on your instance. Here signup is by invitation only, enforced in the database
under Supabase Auth, so invited teammates join your account and nobody else gets in.

## Why Deploy wacrm on Railway?

Railway is a singular platform to deploy your infrastructure stack. Railway will host your
infrastructure so you don't have to deal with configuration, while allowing you to vertically and
horizontally scale it.

By deploying wacrm on Railway, you are one step closer to supporting a complete full-stack application
with minimal burden. Host your servers, databases, AI agents, and more on Railway.

Concretely, this template generates every secret in the format wacrm needs, derives Supabase's API keys
from one of them, wires all eight services over Railway's private network with dual-stack listeners,
attaches volumes to the database and file storage, and runs the cron calls that automation wait steps and
flows depend on.

## Common Use Cases

- Run a sales or support team's shared WhatsApp inbox on the official Business Platform, with assignment,
  notes and statuses.
- Track leads from first message to closed deal in pipelines linked to conversations.
- Send template broadcasts with per-recipient variables and delivery tracking.
- Automate follow-ups with triggers, waits, branches and webhooks, and draft replies with AI.

## Dependencies for wacrm Hosting

- A Meta for Developers app with WhatsApp enabled: a phone number ID, a WhatsApp Business Account ID and
  an access token, entered in the app, plus the app secret as `META_APP_SECRET`.
- Optional: an OpenAI or Anthropic key, added per account in the app, for the AI assistant.
- Optional: SMTP settings on the `auth` service, for password-reset e-mails.
- Nothing else. No Supabase account.

### Deployment Dependencies

- wacrm: https://github.com/ArnasDon/wacrm (MIT)
- Supabase self-hosting stack: https://github.com/supabase/supabase/tree/master/docker (Apache-2.0)
- WhatsApp Cloud API: https://developers.facebook.com/docs/whatsapp/cloud-api
- Template repository, images and tests: https://github.com/youssefsiam38/wacrm-railway

### Implementation Details

The app image is built from a pinned upstream commit with placeholder values that the start-up replaces,
and with one source change: the signup page also sends the invitation token it already holds, so the
database can admit invited teammates. Three thin wrappers adapt Supabase to Railway: init scripts baked in
where Supabase's compose file would mount them, API keys minted from the shared JWT secret with
byte-identical output in Node and Perl, and the Vault key kept on the database volume. Every service
refuses to start on missing, short or published example secrets, or on a reference to another service
that has not resolved. The bundle is tested as a whole in CI, on fresh and reused volumes, before any
image is pushed.

The deploy form asks for one value, `OWNER_EMAIL`. After deploying, copy `OWNER_PASSWORD` from the app
service's variables and sign in on the app's domain. Set `META_APP_SECRET` once you have created your Meta
app, and point its webhook at `https://<app-domain>/api/whatsapp/webhook`.
