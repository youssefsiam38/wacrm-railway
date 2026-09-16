-- Invite-only signup for wacrm, enforced by the database.
--
-- In wacrm every new auth user gets an account of their own: upstream's handle_new_user trigger
-- creates an `accounts` row and makes the user its owner. On a public deployment that means any
-- visitor who finds /signup gets a working CRM tenant on the deployer's instance, and upstream has
-- no setting that closes it. Closing it in the app would not be enough either: the browser talks to
-- Supabase Auth directly, so a signup can be posted to the gateway without the app ever seeing it.
--
-- So the rule lives where every path to a new user converges, a BEFORE INSERT trigger on auth.users.
-- A new user is admitted when:
--
--   1. its user_metadata carries the one-time bootstrap nonce. The app's entrypoint generates 32
--      random bytes at start-up, stores only their SHA-256 here, and hands the nonce to the owner
--      bootstrap, which creates the owner through the Auth admin API over the private network. The
--      nonce never leaves the container and is consumed by the insert it admits. (app_metadata,
--      which browsers cannot set, would be the natural marker, but Supabase Auth writes it after the
--      insert, so a BEFORE INSERT trigger never sees it.)
--   2. its user_metadata carries an invitation token that matches a pending, unexpired invitation.
--      The signup page sends it (patched at build time; see patch-signup.mjs).
--   3. signup has been opened deliberately: WACRM_SIGNUP_MODE=open, recorded below at every start.
--
-- Anything else is refused. Supabase Auth then answers the signup with an error, and no account,
-- profile or tenant is created. Redeeming the invitation afterwards is unchanged upstream code.
--
-- The file is idempotent; the app applies it on every start, after the upstream migrations.

create schema if not exists wacrm_railway;
revoke all on schema wacrm_railway from public;

create table if not exists wacrm_railway.settings (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);

create or replace function wacrm_railway.gate_new_user()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_mode text;
  v_token text;
  v_nonce text;
begin
  v_nonce := nullif(new.raw_user_meta_data ->> 'wacrm_railway_bootstrap_nonce', '');
  if v_nonce is not null then
    new.raw_user_meta_data := new.raw_user_meta_data - 'wacrm_railway_bootstrap_nonce';
    delete from wacrm_railway.settings
    where key = 'bootstrap_nonce_sha256'
      and value = encode(sha256(convert_to(v_nonce, 'UTF8')), 'hex');
    if found then
      return new;
    end if;
  end if;

  v_token := nullif(new.raw_user_meta_data ->> 'invite_token', '');
  if v_token is not null then
    new.raw_user_meta_data := new.raw_user_meta_data - 'invite_token';
    if exists (
      select 1
      from public.account_invitations
      where token_hash = encode(sha256(convert_to(v_token, 'UTF8')), 'hex')
        and accepted_at is null
        and expires_at > now()
    ) then
      return new;
    end if;
  end if;

  select value into v_mode from wacrm_railway.settings where key = 'signup_mode';
  if coalesce(v_mode, 'invite-only') = 'open' then
    return new;
  end if;

  raise exception 'Sign-up on this wacrm instance is by invitation only. Ask an administrator for an invite link.'
    using errcode = '42501';
end;
$$;

revoke all on function wacrm_railway.gate_new_user() from public;

drop trigger if exists wacrm_railway_gate_new_user on auth.users;
create trigger wacrm_railway_gate_new_user
  before insert on auth.users
  for each row execute function wacrm_railway.gate_new_user();

-- Neither the nonce nor an invitation token is kept in auth.users. Removing them in the insert
-- trigger is not enough on its own: Supabase Auth writes the user's metadata again right after the
-- insert, from its in-memory copy, so they are also removed on every update. Upstream stores
-- invitation tokens only as hashes, and this keeps it that way.
create or replace function wacrm_railway.strip_gate_metadata()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog
as $$
begin
  if new.raw_user_meta_data ? 'invite_token' or new.raw_user_meta_data ? 'wacrm_railway_bootstrap_nonce' then
    new.raw_user_meta_data := new.raw_user_meta_data - 'invite_token' - 'wacrm_railway_bootstrap_nonce';
  end if;
  return new;
end;
$$;

revoke all on function wacrm_railway.strip_gate_metadata() from public;

drop trigger if exists wacrm_railway_strip_gate_metadata on auth.users;
create trigger wacrm_railway_strip_gate_metadata
  before update on auth.users
  for each row execute function wacrm_railway.strip_gate_metadata();
