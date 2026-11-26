-- Burger Bytes — update 4: 💾 Save (keeps the day's orders for future reference) + admin-only Reset.
-- Supabase → SQL Editor → New query → paste ALL of this → Run. Safe to run more than once.

create table if not exists public.order_archive (
  order_id uuid primary key,                       -- one saved copy per order (saving again just updates it)
  day date not null,                               -- the business day the order belongs to
  saved_at timestamptz not null default now(),     -- when it was last saved
  data jsonb not null                              -- the full order, exactly as it was
);
create index if not exists order_archive_day_idx on public.order_archive (day);
alter table public.order_archive enable row level security;
drop policy if exists archive_admin_read on public.order_archive;
create policy archive_admin_read on public.order_archive for select using (public.is_admin()); -- only the admin can see it
revoke all on table public.order_archive from anon;
revoke insert, update, delete on table public.order_archive from authenticated;

-- 💾 Save: copy (or refresh) every order of the day into the archive. Nothing is deleted.
create or replace function public.admin_save_day(p_day date default null) returns int
language plpgsql security definer set search_path = public as $$
declare d date; n int;
begin
  if not public.is_admin() then raise exception 'Only the admin can save'; end if;
  d := coalesce(p_day, (now() at time zone (select tz from public.settings where id = 1))::date);
  insert into public.order_archive (order_id, day, saved_at, data)
    select o.id, o.day, now(), to_jsonb(o) from public.orders o where o.day = d
    on conflict (order_id) do update set data = excluded.data, saved_at = excluded.saved_at;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.admin_save_day(date) from public, anon;
grant execute on function public.admin_save_day(date) to authenticated;

-- Reset (admin only): clears the day's orders from every screen and restarts tokens at #1.
-- Saved copies in order_archive are NOT touched.
create or replace function public.admin_reset_day(p_day date default null) returns int
language plpgsql security definer set search_path = public as $$
declare d date; n int;
begin
  if not public.is_admin() then raise exception 'Only the admin can reset the day'; end if;
  d := coalesce(p_day, (now() at time zone (select tz from public.settings where id = 1))::date);
  delete from public.orders where day = d;
  get diagnostics n = row_count;
  delete from public.counters where day = d;
  return n;
end $$;
revoke all on function public.admin_reset_day(date) from public, anon;
grant execute on function public.admin_reset_day(date) to authenticated;
