-- Burger Bytes — update 5: ➕ Extra cheese add-on (₹5 each, price changeable in Admin → Settings).
-- Supabase → SQL Editor → New query → paste ALL of this → Run. Safe to run more than once.

alter table public.settings add column if not exists extra_cheese_price numeric not null default 5;
alter table public.orders   add column if not exists extra_cheese       int     not null default 0;
alter table public.orders   add column if not exists extra_cheese_price numeric not null default 0;
do $$ begin
  alter table public.orders add constraint orders_extra_cheese_check check (extra_cheese between 0 and 50);
exception when duplicate_object then null; end $$;

create or replace function public._order_row(o public.orders) returns json
language sql stable as $$
  select json_build_object('id', o.id, 'token', o.token, 'day', o.day,
    'cheese', o.cheese, 'plain', o.plain, 'coke', o.coke, 'extra', o.extra_cheese,
    'parcel', o.parcel, 'parcelAmount', o.parcel_amount,
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
    'extraPrice', s.extra_cheese_price,
    'parcelCharge', s.parcel_charge, 'parcelMode', s.parcel_mode)
  from public.settings s where s.id = 1
$$;

-- counter places an order (new version with extra cheese; the old 6-argument version stays for screens not yet updated)
create or replace function public.intake_place(p_pin text, p_cheese int, p_plain int, p_coke int, p_extra int, p_parcel boolean, p_method text)
returns json language plpgsql security definer set search_path = public as $$
declare s public.settings; d date; t int; o public.orders; burgers int; parcel_amt numeric; m text;
begin
  if not public._staff_ok('intake', p_pin) then return json_build_object('ok', false, 'error', 'Wrong PIN'); end if;
  select * into s from public.settings where id = 1;
  if not s.is_open then return json_build_object('ok', false, 'error', 'The stall is CLOSED. Ask the admin to open it.'); end if;
  p_cheese := greatest(0, least(50, coalesce(p_cheese, 0)));
  p_plain  := greatest(0, least(50, coalesce(p_plain, 0)));
  p_coke   := greatest(0, least(50, coalesce(p_coke, 0)));
  burgers := p_cheese + p_plain;
  p_extra  := greatest(0, least(burgers, coalesce(p_extra, 0)));   -- extra cheese only goes on burgers
  if burgers + p_coke = 0 then return json_build_object('ok', false, 'error', 'Add at least one item.'); end if;
  m := case when upper(coalesce(p_method, '')) in ('CASH', 'UPI') then upper(p_method) else null end;
  parcel_amt := case when coalesce(p_parcel, false) then
                  case when s.parcel_mode = 'burger' then burgers * s.parcel_charge else s.parcel_charge end
                else 0 end;
  d := public._today();
  insert into public.counters (day, last) values (d, 1)
    on conflict (day) do update set last = public.counters.last + 1
    returning last into t;
  insert into public.orders (token, day, cheese, plain, coke, extra_cheese, total_items, cheese_price, plain_price, coke_price, extra_cheese_price,
                             parcel, parcel_amount, total, payment, pay_method, paid_at)
    values (t, d, p_cheese, p_plain, p_coke, p_extra, burgers + p_coke, s.cheese_price, s.plain_price, s.coke_price, s.extra_cheese_price,
            coalesce(p_parcel, false), parcel_amt,
            p_cheese * s.cheese_price + p_plain * s.plain_price + p_coke * s.coke_price + p_extra * s.extra_cheese_price + parcel_amt,
            case when m is null then 'NOT_PAID' else 'PAID' end, m, case when m is null then null else now() end)
    returning * into o;
  return json_build_object('ok', true, 'order', public._order_row(o));
end $$;
grant execute on function public.intake_place(text, int, int, int, int, boolean, text) to anon, authenticated;
