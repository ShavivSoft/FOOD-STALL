-- Burger Bytes — update 3: counter / kitchen / delivery screens.
-- Adds Diet Coke, parcel charges, cash/UPI, cancelled orders and staff PIN logins.
-- Supabase → SQL Editor → New query → paste ALL of this → Run. Safe to run more than once.

-- ---------- settings ----------
alter table public.settings add column if not exists coke_name     text    not null default 'Diet Coke';
alter table public.settings add column if not exists coke_price    numeric not null default 40;
alter table public.settings add column if not exists parcel_charge numeric not null default 10;
alter table public.settings add column if not exists parcel_mode   text    not null default 'order'; -- 'order' = once per order, 'burger' = per burger
update public.settings set stall_name = 'Burger Bytes' where id = 1 and stall_name = 'Chicken Burger Stall';
do $$ begin
  alter table public.settings add constraint settings_parcel_mode_check check (parcel_mode in ('order', 'burger'));
exception when duplicate_object then null; end $$;

-- ---------- orders ----------
alter table public.orders add column if not exists coke          int     not null default 0;
alter table public.orders add column if not exists coke_price    numeric not null default 0;
alter table public.orders add column if not exists parcel        boolean not null default false;
alter table public.orders add column if not exists parcel_amount numeric not null default 0;
alter table public.orders add column if not exists pay_method    text;            -- CASH / UPI (null = not paid yet)
alter table public.orders add column if not exists cancelled_at  timestamptz;
alter table public.orders drop constraint if exists orders_status_check;
alter table public.orders add constraint orders_status_check check (status in ('NEW','PREPARING','READY','DELIVERED','CANCELLED'));
alter table public.orders drop constraint if exists orders_cheese_check;
alter table public.orders drop constraint if exists orders_plain_check;
do $$ begin
  alter table public.orders add constraint orders_qty_check check (cheese between 0 and 50 and plain between 0 and 50 and coke between 0 and 50);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.orders add constraint orders_pay_method_check check (pay_method is null or pay_method in ('CASH','UPI'));
exception when duplicate_object then null; end $$;

-- customers no longer order from their phones: orders are taken at the counter
revoke execute on function public.place_order(int, int) from public, anon, authenticated;
revoke execute on function public.save_push(text, text, jsonb) from public, anon, authenticated;

-- ---------- staff PINs (set from the admin dashboard) ----------
create table if not exists public.staff_pins (
  role text primary key check (role in ('intake', 'kitchen', 'delivery')),
  salt text not null,
  pin_hash text not null,
  fails int not null default 0,
  locked_until timestamptz,
  last_seen timestamptz
);
alter table public.staff_pins enable row level security;  -- no policies: only the functions below touch it
revoke all on table public.staff_pins from anon, authenticated;

-- checks a PIN; 8 wrong tries locks that screen for 5 minutes. Never raises, so the fail count is kept.
create or replace function public._staff_ok(p_role text, p_pin text) returns boolean
language plpgsql security definer set search_path = public as $$
declare r public.staff_pins;
begin
  select * into r from public.staff_pins where role = p_role for update;
  if not found then return false; end if;
  if r.locked_until is not null and r.locked_until > now() then return false; end if;
  if r.pin_hash = encode(sha256(convert_to(r.salt || coalesce(p_pin, ''), 'UTF8')), 'hex') then
    update public.staff_pins set fails = 0, locked_until = null, last_seen = now() where role = p_role;
    return true;
  end if;
  update public.staff_pins set fails = fails + 1,
    locked_until = case when fails + 1 >= 8 then now() + interval '5 minutes' else null end
    where role = p_role;
  return false;
end $$;
revoke all on function public._staff_ok(text, text) from public, anon, authenticated;

create or replace function public._today() returns date
language sql stable security definer set search_path = public as $$
  select (now() at time zone (select tz from public.settings where id = 1))::date
$$;

create or replace function public._order_row(o public.orders) returns json
language sql stable as $$
  select json_build_object('id', o.id, 'token', o.token, 'day', o.day,
    'cheese', o.cheese, 'plain', o.plain, 'coke', o.coke, 'parcel', o.parcel, 'parcelAmount', o.parcel_amount,
    'total', o.total, 'payment', o.payment, 'payMethod', o.pay_method, 'status', o.status,
    'createdAt', o.created_at, 'paidAt', o.paid_at, 'preparingAt', o.preparing_at, 'readyAt', o.ready_at,
    'deliveredAt', o.delivered_at, 'cancelledAt', o.cancelled_at)
$$;
revoke all on function public._order_row(public.orders) from public, anon, authenticated;

create or replace function public._public_settings() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('stallName', s.stall_name, 'isOpen', s.is_open,
    'cheeseName', s.cheese_name, 'cheesePrice', s.cheese_price,
    'plainName', s.plain_name, 'plainPrice', s.plain_price,
    'cokeName', s.coke_name, 'cokePrice', s.coke_price,
    'parcelCharge', s.parcel_charge, 'parcelMode', s.parcel_mode)
  from public.settings s where s.id = 1
$$;

-- log in a staff screen
create or replace function public.staff_login(p_role text, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
begin
  if public._staff_ok(p_role, p_pin) then return json_build_object('ok', true, 'settings', public._public_settings()); end if;
  if exists (select 1 from public.staff_pins where role = p_role and locked_until > now()) then
    return json_build_object('ok', false, 'error', 'Too many wrong PINs. Try again in 5 minutes.');
  end if;
  if not exists (select 1 from public.staff_pins where role = p_role) then
    return json_build_object('ok', false, 'error', 'No PIN set for this screen yet. Ask the admin to set it in Settings.');
  end if;
  return json_build_object('ok', false, 'error', 'Wrong PIN');
end $$;

-- everything a staff screen needs, polled every ~2 seconds
create or replace function public.staff_board(p_role text, p_pin text) returns json
language plpgsql security definer set search_path = public as $$
declare d date := public._today();
begin
  if not public._staff_ok(p_role, p_pin) then return json_build_object('ok', false, 'error', 'Wrong PIN'); end if;
  return json_build_object('ok', true, 'today', d, 'now', now(), 'settings', public._public_settings(),
    'orders', coalesce((select json_agg(public._order_row(o) order by o.token) from public.orders o where o.day = d), '[]'::json));
end $$;

-- counter places an order
create or replace function public.intake_place(p_pin text, p_cheese int, p_plain int, p_coke int, p_parcel boolean, p_method text)
returns json language plpgsql security definer set search_path = public as $$
declare s public.settings; d date; t int; o public.orders; burgers int; parcel_amt numeric; m text;
begin
  if not public._staff_ok('intake', p_pin) then return json_build_object('ok', false, 'error', 'Wrong PIN'); end if;
  select * into s from public.settings where id = 1;
  if not s.is_open then return json_build_object('ok', false, 'error', 'The stall is CLOSED. Ask the admin to open it.'); end if;
  p_cheese := greatest(0, least(50, coalesce(p_cheese, 0)));
  p_plain  := greatest(0, least(50, coalesce(p_plain, 0)));
  p_coke   := greatest(0, least(50, coalesce(p_coke, 0)));
  if p_cheese + p_plain + p_coke = 0 then return json_build_object('ok', false, 'error', 'Add at least one item.'); end if;
  m := case when upper(coalesce(p_method, '')) in ('CASH', 'UPI') then upper(p_method) else null end;
  burgers := p_cheese + p_plain;
  parcel_amt := case when coalesce(p_parcel, false) then
                  case when s.parcel_mode = 'burger' then burgers * s.parcel_charge else s.parcel_charge end
                else 0 end;
  d := public._today();
  insert into public.counters (day, last) values (d, 1)
    on conflict (day) do update set last = public.counters.last + 1
    returning last into t;
  insert into public.orders (token, day, cheese, plain, coke, total_items, cheese_price, plain_price, coke_price,
                             parcel, parcel_amount, total, payment, pay_method, paid_at)
    values (t, d, p_cheese, p_plain, p_coke, p_cheese + p_plain + p_coke, s.cheese_price, s.plain_price, s.coke_price,
            coalesce(p_parcel, false), parcel_amt,
            p_cheese * s.cheese_price + p_plain * s.plain_price + p_coke * s.coke_price + parcel_amt,
            case when m is null then 'NOT_PAID' else 'PAID' end, m, case when m is null then null else now() end)
    returning * into o;
  return json_build_object('ok', true, 'order', public._order_row(o));
end $$;

-- staff buttons; each screen may only do its own steps
create or replace function public.staff_act(p_role text, p_pin text, p_id uuid, p_action text) returns json
language plpgsql security definer set search_path = public as $$
declare o public.orders;
begin
  if not public._staff_ok(p_role, p_pin) then return json_build_object('ok', false, 'error', 'Wrong PIN'); end if;
  select * into o from public.orders where id = p_id for update;
  if not found then return json_build_object('ok', false, 'error', 'Order not found'); end if;
  if o.status = 'CANCELLED' then return json_build_object('ok', false, 'error', 'This order was cancelled'); end if;

  if p_role = 'intake' and p_action in ('paid_cash', 'paid_upi') then
    update public.orders set payment = 'PAID', pay_method = case when p_action = 'paid_cash' then 'CASH' else 'UPI' end, paid_at = now() where id = p_id;
  elsif p_role = 'intake' and p_action = 'unpaid' then
    update public.orders set payment = 'NOT_PAID', pay_method = null, paid_at = null where id = p_id;
  elsif p_role = 'intake' and p_action = 'cancel' then
    if o.status not in ('NEW', 'PREPARING') then return json_build_object('ok', false, 'error', 'Too late to cancel — the kitchen already finished it'); end if;
    update public.orders set status = 'CANCELLED', cancelled_at = now() where id = p_id;
  elsif p_role = 'kitchen' and p_action = 'preparing' and o.status = 'NEW' then
    update public.orders set status = 'PREPARING', preparing_at = now() where id = p_id;
  elsif p_role = 'kitchen' and p_action = 'ready' and o.status in ('NEW', 'PREPARING') then
    update public.orders set status = 'READY', ready_at = now(), preparing_at = coalesce(preparing_at, now()) where id = p_id;
  elsif p_role = 'kitchen' and p_action = 'unready' and o.status = 'READY' then
    update public.orders set status = 'PREPARING', ready_at = null where id = p_id;
  elsif p_role = 'delivery' and p_action = 'delivered' and o.status = 'READY' then
    update public.orders set status = 'DELIVERED', delivered_at = now() where id = p_id;
  elsif p_role = 'delivery' and p_action = 'undeliver' and o.status = 'DELIVERED' then
    update public.orders set status = 'READY', delivered_at = null where id = p_id;
  else
    return json_build_object('ok', false, 'error', 'That step is not allowed right now');
  end if;
  select * into o from public.orders where id = p_id;
  return json_build_object('ok', true, 'order', public._order_row(o));
end $$;

-- ---------- admin helpers ----------
create or replace function public.admin_set_pin(p_role text, p_pin text) returns boolean
language plpgsql security definer set search_path = public as $$
declare salt text := md5(random()::text || clock_timestamp()::text);
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  if p_role not in ('intake', 'kitchen', 'delivery') then raise exception 'bad role'; end if;
  if p_pin !~ '^[0-9]{4,8}$' then raise exception 'PIN must be 4 to 8 digits'; end if;
  insert into public.staff_pins (role, salt, pin_hash) values (p_role, salt, encode(sha256(convert_to(salt || p_pin, 'UTF8')), 'hex'))
    on conflict (role) do update set salt = excluded.salt, pin_hash = excluded.pin_hash, fails = 0, locked_until = null;
  return true;
end $$;

create or replace function public.admin_staff_status() returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  return json_build_object('now', now(), 'staff', coalesce((select json_agg(json_build_object(
    'role', role, 'lastSeen', last_seen, 'locked', coalesce(locked_until > now(), false))) from public.staff_pins), '[]'::json));
end $$;

grant execute on function public.staff_login(text, text)                                   to anon, authenticated;
grant execute on function public.staff_board(text, text)                                   to anon, authenticated;
grant execute on function public.intake_place(text, int, int, int, boolean, text)          to anon, authenticated;
grant execute on function public.staff_act(text, text, uuid, text)                         to anon, authenticated;
revoke all on function public.admin_set_pin(text, text) from public, anon;
revoke all on function public.admin_staff_status() from public, anon;
grant execute on function public.admin_set_pin(text, text)  to authenticated;
grant execute on function public.admin_staff_status()       to authenticated;
