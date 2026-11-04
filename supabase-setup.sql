-- PublicDROP database setup (run ONCE: Supabase Dashboard > SQL Editor > New query > paste > Run)
-- Safe to run again: everything uses IF NOT EXISTS / OR REPLACE.
-- v5: no email confirmation (accounts work instantly), safer sign-up trigger, Google sign-in ready.

-- 0) NO CONFIRMATION E-MAIL: any new e-mail account is marked as confirmed the moment it is created,
--    and every account that was still waiting for confirmation is activated now.
--    (Also switch OFF  Authentication > Sign In / Providers > Email > "Confirm email"  so Supabase never sends the mail.
--     The pd-install.sh installer can do that for you, see its notes.)
create or replace function public.pd_autoconfirm_email()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.email_confirmed_at is null then
    new.email_confirmed_at := now();
  end if;
  return new;
exception when others then
  return new;   -- never block a sign-up because of this helper
end $$;

drop trigger if exists pd_autoconfirm_before_insert on auth.users;
create trigger pd_autoconfirm_before_insert
  before insert on auth.users
  for each row execute function public.pd_autoconfirm_email();

update auth.users set email_confirmed_at = now() where email_confirmed_at is null;

-- 1) My List (favorites)
create table if not exists public.favorites (
  user_id    uuid not null references auth.users(id) on delete cascade,
  media_key  text not null,
  media_data jsonb not null,
  created_at timestamptz not null default now(),
  primary key (user_id, media_key)
);

-- 2) Continue Watching
create table if not exists public.watch_progress (
  user_id       uuid not null references auth.users(id) on delete cascade,
  media_key     text not null,
  progress_data jsonb not null,
  updated_at    timestamptz not null default now(),
  primary key (user_id, media_key)
);

-- 3) Profiles (one row per registered user, filled automatically)
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text,
  full_name  text,
  created_at timestamptz not null default now()
);

-- 4) Each person can only see and change their OWN rows
alter table public.favorites      enable row level security;
alter table public.watch_progress enable row level security;
alter table public.profiles       enable row level security;

drop policy if exists "favorites own rows" on public.favorites;
create policy "favorites own rows" on public.favorites
  for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "progress own rows" on public.watch_progress;
create policy "progress own rows" on public.watch_progress
  for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "profile read own" on public.profiles;
create policy "profile read own" on public.profiles
  for select to authenticated using (auth.uid() = id);

grant select, insert, update, delete on public.favorites      to authenticated;
grant select, insert, update, delete on public.watch_progress to authenticated;
grant select on public.profiles to authenticated;

-- 5) Create a profile automatically whenever someone signs up (e-mail OR Google).
--    It can never make a sign-up fail: if anything goes wrong here the account is still created.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin
    insert into public.profiles (id, email, full_name)
    values (new.id, new.email,
            coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', ''))
    on conflict (id) do nothing;
  exception when others then
    null;
  end;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 6) Back-fill profiles for anyone who already registered
insert into public.profiles (id, email, full_name)
select id, email, coalesce(raw_user_meta_data->>'full_name', raw_user_meta_data->>'name', '')
from auth.users
on conflict (id) do nothing;

-- 7) Watch history (everything a person has watched, shown in My account > Watch history)
create table if not exists public.watch_history (
  user_id      uuid not null references auth.users(id) on delete cascade,
  media_key    text not null,
  history_data jsonb not null,
  watched_at   timestamptz not null default now(),
  primary key (user_id, media_key)
);
alter table public.watch_history enable row level security;
drop policy if exists "history own rows" on public.watch_history;
create policy "history own rows" on public.watch_history
  for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
grant select, insert, update, delete on public.watch_history to authenticated;

-- 8) Profile name/avatar/username are stored in each user's account data (user_metadata), nothing else to set up.
--    Keep the profiles table name in sync when a person changes it (also safe: never blocks a profile update).
create or replace function public.sync_profile_name()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  begin
    update public.profiles
       set full_name = coalesce(new.raw_user_meta_data->>'display_name', new.raw_user_meta_data->>'full_name', full_name),
           email = new.email
     where id = new.id;
  exception when others then
    null;
  end;
  return new;
end $$;
drop trigger if exists on_auth_user_updated on auth.users;
create trigger on_auth_user_updated
  after update of raw_user_meta_data on auth.users
  for each row execute function public.sync_profile_name();
