-- Burger Stall — Supabase setup.
-- Paste this whole file into Supabase → SQL Editor → Run. Safe to run again.
-- Then add your admin email at the bottom (see STEP 2).


-- ---------- tables ----------
create table if not exists public.settings (
  id int primary key default 1 check (id = 1),
  stall_name   text    not null default 'Burger Bytes',
  cheese_name  text    not null default 'Chicken Burger with Cheese',
  cheese_price numeric not null default 120,
  plain_name   text    not null default 'Chicken Burger (No Cheese)',
  plain_price  numeric not null default 100,
  is_open      boolean not null default true,
  tz           text    not null default 'Asia/Kolkata'
);
insert into public.settings (id) values (1) on conflict do nothing;
alter table public.settings add column if not exists vapid_public text; -- filled in by the notify-ready function

-- push key pair, created by the notify-ready function on first use; nobody but the server can read it
create table if not exists public.push_keys (
  id int primary key default 1 check (id = 1),
  public_key text not null,
  private_key text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.admins (email text primary key);

create table if not exists public.counters (day date primary key, last int not null);

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  key text not null unique default replace(gen_random_uuid()::text, '-', ''), -- secret link for the customer
  token int  not null,
  day   date not null,
  cheese int not null check (cheese between 0 and 20),
  plain  int not null check (plain between 0 and 20),
  total_items  int     not null,
  cheese_price numeric not null,
  plain_price  numeric not null,
  total        numeric not null,
  payment text not null default 'NOT_PAID' check (payment in ('NOT_PAID','PAID')),
  status  text not null default 'NEW' check (status in ('NEW','PREPARING','READY','DELIVERED')),
  created_at timestamptz not null default now(),
  paid_at timestamptz, preparing_at timestamptz, ready_at timestamptz, delivered_at timestamptz,
  unique (day, token)
);
create index if not exists orders_day_idx on public.orders (day);

create table if not exists public.push_subs (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  endpoint text not null,
  keys jsonb not null,
  created_at timestamptz not null default now(),
  unique (order_id, endpoint)
);

-- ---------- security ----------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where email = lower(coalesce(auth.jwt() ->> 'email', '')))
$$;

alter table public.settings  enable row level security;
alter table public.admins    enable row level security;
alter table public.counters  enable row level security;
alter table public.orders    enable row level security;
alter table public.push_subs enable row level security;
alter table public.push_keys enable row level security; -- no policies: server only
revoke all on table public.push_keys from anon, authenticated;

drop policy if exists settings_read  on public.settings;
drop policy if exists settings_admin on public.settings;
drop policy if exists orders_admin_read   on public.orders;
drop policy if exists orders_admin_update on public.orders;
drop policy if exists push_admin_read on public.push_subs;
create policy settings_read  on public.settings for select using (true);
create policy settings_admin on public.settings for update using (public.is_admin()) with check (public.is_admin());
create policy orders_admin_read   on public.orders for select using (public.is_admin());
create policy orders_admin_update on public.orders for update using (public.is_admin()) with check (public.is_admin());
create policy push_admin_read on public.push_subs for select using (public.is_admin());
-- customers never touch tables directly; they only use the functions below.

-- ---------- customer functions ----------
create or replace function public.order_json(o public.orders) returns json
language sql stable as $$
  select json_build_object(
    'key', o.key, 'token', o.token, 'day', o.day,
    'cheese', o.cheese, 'plain', o.plain, 'totalItems', o.total_items,
    'cheesePrice', o.cheese_price, 'plainPrice', o.plain_price, 'total', o.total,
    'payment', o.payment, 'status', o.status, 'createdAt', o.created_at, 'readyAt', o.ready_at)
$$;

create or replace function public.place_order(p_cheese int, p_plain int) returns json
language plpgsql security definer set search_path = public as $$
declare s public.settings; d date; t int; o public.orders; recent int;
begin
  select * into s from public.settings where id = 1;
  if not s.is_open then raise exception 'The stall is not taking orders right now.'; end if;
  p_cheese := greatest(0, least(20, coalesce(p_cheese, 0)));
  p_plain  := greatest(0, least(20, coalesce(p_plain, 0)));
  if p_cheese + p_plain = 0 then raise exception 'Add at least one item.'; end if;
  -- basic flood guard: max 60 orders per minute across the stall
  select count(*) into recent from public.orders where created_at > now() - interval '1 minute';
  if recent >= 60 then raise exception 'Too many orders right now, please try again in a minute.'; end if;

  d := (now() at time zone s.tz)::date;  -- tokens restart at #1 every day
  insert into public.counters (day, last) values (d, 1)
    on conflict (day) do update set last = public.counters.last + 1   -- row lock: never duplicates
    returning last into t;
  insert into public.orders (token, day, cheese, plain, total_items, cheese_price, plain_price, total)
    values (t, d, p_cheese, p_plain, p_cheese + p_plain, s.cheese_price, s.plain_price,
            p_cheese * s.cheese_price + p_plain * s.plain_price)
    returning * into o;
  return public.order_json(o);
end $$;

create or replace function public.get_order(p_key text) returns json
language sql stable security definer set search_path = public as $$
  select public.order_json(o) from public.orders o where o.key = p_key
$$;

create or replace function public.save_push(p_key text, p_endpoint text, p_keys jsonb) returns boolean
language plpgsql security definer set search_path = public as $$
declare oid uuid;
begin
  select id into oid from public.orders where key = p_key;
  if oid is null or p_endpoint is null or p_keys is null then return false; end if;
  insert into public.push_subs (order_id, endpoint, keys) values (oid, p_endpoint, p_keys)
    on conflict (order_id, endpoint) do update set keys = excluded.keys;
  return true;
end $$;

-- ---------- admin functions ----------
create or replace function public.admin_history() returns table (day date, orders bigint, revenue numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  return query
    select o.day, count(*), coalesce(sum(o.total) filter (where o.payment = 'PAID'), 0)
    from public.orders o group by o.day order by o.day desc limit 365;
end $$;

create or replace function public.admin_reset_day(p_day date default null) returns int
language plpgsql security definer set search_path = public as $$
declare d date; n int;
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  d := coalesce(p_day, (now() at time zone (select tz from public.settings where id = 1))::date);
  delete from public.orders where day = d;          -- push subscriptions go with them
  get diagnostics n = row_count;
  delete from public.counters where day = d;        -- next order that day is token #1 again
  return n;
end $$;

revoke all on function public.order_json(public.orders) from public, anon, authenticated;
grant execute on function public.place_order(int, int)       to anon, authenticated;
grant execute on function public.get_order(text)             to anon, authenticated;
grant execute on function public.save_push(text, text, jsonb) to anon, authenticated;
grant execute on function public.is_admin()                  to anon, authenticated;
grant execute on function public.admin_history()             to authenticated;
revoke all on function public.admin_reset_day(date) from public, anon;
grant execute on function public.admin_reset_day(date)       to authenticated;

-- ---------- live updates for the admin dashboard ----------
do $$ begin
  begin alter publication supabase_realtime add table public.orders;    exception when others then null; end;
  begin alter publication supabase_realtime add table public.push_subs; exception when others then null; end;
end $$;

-- =====================================================================
-- STEP 2 — make yourself the token manager:
--   1. Authentication → Users → Add user → Create new user
--      (your email + a password, tick "Auto Confirm User").
--   2. Put that same email below and run just this line:
--
-- insert into public.admins (email) values (lower('you@example.com')) on conflict do nothing;
--
--   3. Authentication → Sign In / Providers → turn OFF "Allow new users to sign up".
-- =====================================================================
