# Marketplace audit

Checked 2026-09-16 against Railway's template search.

## Gap

| Existing template | Deploys | Why it does not cover this |
|---|---|---|
| "WaCRM" | 1 | Points Railway at upstream's repository with no variables and no Supabase. Upstream's build needs a Supabase URL and anon key as build arguments and its runtime needs a service-role key, `ENCRYPTION_KEY` and `META_APP_SECRET`; none are provided, and the migrations are never applied. It cannot produce a working CRM. |
| Evolution API | 5,046 | A WhatsApp API gateway, not a CRM. |
| WAHA | 418 | A WhatsApp Web automation API, not a CRM, and unofficial. |
| Twenty CRM | 665 | A general CRM with no WhatsApp inbox. |
| DeskcommCRM (ours) | new | A WhatsApp sales CRM on WAHA (unofficial WhatsApp Web). wacrm uses Meta's official WhatsApp Business Platform, which businesses that cannot risk a ban need. |

## Why wacrm

- MIT licensed.
- 2.3k stars and 6.0k forks: more forks than stars, because upstream presents it as a template to fork
  and host. People are deploying it.
- 15 issues and 54 pull requests in the last 30 days; commits land every few days.
- On the official WhatsApp Business Platform, so it suits businesses that need Meta's terms rather than a
  WhatsApp Web bridge.
- Next.js and Supabase, close to the DeskcommCRM bundle already built and tested here.

## Why it needs a template rather than a raw repo deploy

1. **Supabase.** Six services with init scripts, bind mounts and API keys derived from one secret.
2. **Build-time values.** The Supabase URL and anon key are compiled into the app. A template has neither
   until it is deployed.
3. **Migrations.** 42 ordered files, meant to be pushed from the operator's machine with the Supabase CLI.
4. **Open signup.** Every visitor who signs up gets a CRM account of their own on the instance, with no
   setting to close it.
5. **Cron.** Automations and flows need an external scheduler with a shared secret.

## Cost

Eight services. The six Supabase services dominate; the app is a Next.js standalone server and the
scheduler is a shell loop.

## Category

Railway has no CRM category. The most-deployed neighbours sit in three: Evolution API in **Bots**,
Twenty CRM in **Automation**, Chatwoot in **Other**. wacrm is published under **Automation**, next to
Twenty: its broadcasts, no-code automations and flows are what distinguish it from a plain inbox.
