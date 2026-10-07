-- Lediga rum – Supabase-uppsättning. Klistra in allt i SQL Editor och tryck Run.
-- >>> BYT PIN-KODEN på raden "insert into private.settings" nedan innan du kör! <<<

-- 1. Tabell för städade rum
create table if not exists public.cleaned_rooms (
    id         uuid primary key default gen_random_uuid(),
    date       date not null,
    period     text not null check (period in ('fm', 'em')),   -- fm = före 12:00, em = efter
    room       text not null check (char_length(room) between 1 and 60),
    time       text not null,                                   -- 'HH:MM' svensk tid
    created_at timestamptz not null default now(),
    unique (date, period, room)
);

-- 2. Hemlig PIN i ett schema som API:et inte exponerar
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create table if not exists private.settings (key text primary key, value text not null);
revoke all on private.settings from public, anon, authenticated;
insert into private.settings (key, value) values ('pin', 'BYT-MIG')      -- <<< BYT PIN HÄR
on conflict (key) do update set value = excluded.value;

-- 3. Alla får läsa, ingen får skriva direkt (skrivning sker bara via funktionerna nedan)
alter table public.cleaned_rooms enable row level security;
drop policy if exists "alla kan läsa" on public.cleaned_rooms;
create policy "alla kan läsa" on public.cleaned_rooms for select to anon, authenticated using (true);
revoke all on public.cleaned_rooms from anon, authenticated;
grant select on public.cleaned_rooms to anon, authenticated;

-- 4. Markera rum som städat (kräver PIN). Datum, halvdag och klockslag sätts av servern.
create or replace function public.mark_cleaned(p_room text, p_pin text)
returns public.cleaned_rooms
language plpgsql security definer set search_path = '' as $$
declare
    s   timestamp := now() at time zone 'Europe/Stockholm';
    per text := case when extract(hour from (now() at time zone 'Europe/Stockholm')) < 12 then 'fm' else 'em' end;
    r   public.cleaned_rooms;
begin
    if p_pin is distinct from (select value from private.settings where key = 'pin') then
        raise exception 'fel pin' using errcode = '28000';
    end if;
    delete from public.cleaned_rooms where date < (s::date - 90);
    insert into public.cleaned_rooms (date, period, room, time)
    values (s::date, per, trim(p_room), to_char(s, 'HH24:MI'))
    on conflict (date, period, room) do update set room = excluded.room
    returning * into r;
    return r;
end $$;

-- 5. Ta bort en markering (kräver PIN)
create or replace function public.unmark_cleaned(p_id uuid, p_pin text)
returns void
language plpgsql security definer set search_path = '' as $$
begin
    if p_pin is distinct from (select value from private.settings where key = 'pin') then
        raise exception 'fel pin' using errcode = '28000';
    end if;
    delete from public.cleaned_rooms where id = p_id;
end $$;

revoke all on function public.mark_cleaned(text, text) from public;
revoke all on function public.unmark_cleaned(uuid, text) from public;
grant execute on function public.mark_cleaned(text, text) to anon, authenticated;
grant execute on function public.unmark_cleaned(uuid, text) to anon, authenticated;

-- 6. Live-uppdateringar
do $$ begin
    alter publication supabase_realtime add table public.cleaned_rooms;
exception when duplicate_object then null;
end $$;
