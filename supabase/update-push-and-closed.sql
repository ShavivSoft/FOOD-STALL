-- Update for an existing install (adds the reset button function and server-side push keys).
-- Supabase → SQL Editor → New query → paste → Run. Safe to run more than once.

alter table public.settings add column if not exists vapid_public text;

create table if not exists public.push_keys (
  id int primary key default 1 check (id = 1),
  public_key text not null,
  private_key text not null,
  created_at timestamptz not null default now()
);
alter table public.push_keys enable row level security;
revoke all on table public.push_keys from anon, authenticated;

create or replace function public.admin_reset_day(p_day date default null) returns int
language plpgsql security definer set search_path = public as $$
declare d date; n int;
begin
  if not public.is_admin() then raise exception 'not allowed'; end if;
  d := coalesce(p_day, (now() at time zone (select tz from public.settings where id = 1))::date);
  delete from public.orders where day = d;
  get diagnostics n = row_count;
  delete from public.counters where day = d;
  return n;
end $$;
revoke all on function public.admin_reset_day(date) from public, anon;
grant execute on function public.admin_reset_day(date) to authenticated;
