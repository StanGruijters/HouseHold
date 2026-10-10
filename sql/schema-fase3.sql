-- ============================================================
--  HouseHold — fase 3: takenlijst per gezinslid
--  Uitvoeren in Supabase: SQL Editor > New query > plakken > Run
--  Je kunt dit bestand veilig nog een keer uitvoeren.
-- ============================================================

-- 1. De tabel met taken ---------------------------------------
create table if not exists public.tasks (
  id           uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  member_id    uuid references public.household_members(id) on delete set null,  -- leeg = Iedereen
  titel        text not null check (char_length(titel) between 1 and 200),
  deadline     date,
  checked      boolean not null default false,
  checked_at   timestamptz,
  checked_by   uuid references auth.users(id) on delete set null,
  created_by   uuid references auth.users(id) on delete set null,
  created_at   timestamptz not null default now()
);

create index if not exists tasks_household_idx on public.tasks (household_id);
create index if not exists tasks_member_idx    on public.tasks (member_id);


-- 2. Hulpfunctie: welke rol heb ik in dit huishouden? ---------
--    Geeft 'beheerder' of 'lid' terug, of niets als je geen actief lid bent.
create or replace function public.taak_mijn_rol(p_household_id uuid)
returns text
language sql stable security definer set search_path = public
as $$
  select rol from household_members
  where household_id = p_household_id
    and user_id = auth.uid()
    and status = 'actief'
  limit 1
$$;


-- 3. Lezen mag via RLS, schrijven alleen via de functies hieronder
alter table public.tasks enable row level security;

drop policy if exists "taken lezen" on public.tasks;
create policy "taken lezen" on public.tasks
  for select to authenticated
  using (public.taak_mijn_rol(household_id) is not null);

grant select on public.tasks to authenticated;
revoke insert, update, delete on public.tasks from anon, authenticated;


-- 4. Taak toevoegen -------------------------------------------
create or replace function public.voeg_taak_toe(
  p_household_id uuid,
  p_titel        text,
  p_member_id    uuid default null,
  p_deadline     date default null
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_id    uuid;
  v_titel text := btrim(coalesce(p_titel, ''));
begin
  if public.taak_mijn_rol(p_household_id) is null then
    raise exception 'Je bent geen actief lid van dit huishouden';
  end if;
  if v_titel = '' then
    raise exception 'Vul in wat er moet gebeuren';
  end if;
  if char_length(v_titel) > 200 then
    raise exception 'Die taak is te lang (maximaal 200 tekens)';
  end if;
  if p_member_id is not null and not exists (
       select 1 from household_members
       where id = p_member_id and household_id = p_household_id and status = 'actief') then
    raise exception 'Dit gezinslid hoort niet bij dit huishouden';
  end if;

  insert into tasks (household_id, member_id, titel, deadline, created_by)
  values (p_household_id, p_member_id, v_titel, p_deadline, auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;


-- 5. Afvinken of terugzetten (ieder actief lid mag dit) --------
create or replace function public.wissel_taak(p_taak_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_hid uuid;
begin
  select household_id into v_hid from tasks where id = p_taak_id;
  if v_hid is null then
    raise exception 'Deze taak bestaat niet meer';
  end if;
  if public.taak_mijn_rol(v_hid) is null then
    raise exception 'Je bent geen actief lid van dit huishouden';
  end if;

  update tasks set
    checked    = not checked,
    checked_at = case when checked then null else now() end,
    checked_by = case when checked then null else auth.uid() end
  where id = p_taak_id;
end;
$$;


-- 6. Verwijderen: alleen wie de taak maakte, of een beheerder --
create or replace function public.verwijder_taak(p_taak_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_hid   uuid;
  v_maker uuid;
  v_rol   text;
begin
  select household_id, created_by into v_hid, v_maker from tasks where id = p_taak_id;
  if v_hid is null then
    raise exception 'Deze taak bestaat niet meer';
  end if;

  v_rol := public.taak_mijn_rol(v_hid);
  if v_rol is null then
    raise exception 'Je bent geen actief lid van dit huishouden';
  end if;
  if v_rol <> 'beheerder' and v_maker is distinct from auth.uid() then
    raise exception 'Alleen wie de taak aanmaakte of een beheerder kan hem verwijderen';
  end if;

  delete from tasks where id = p_taak_id;
end;
$$;


-- 7. Gedane taken van één persoon (of van Iedereen) wissen -----
create or replace function public.wis_gedane_taken(
  p_household_id uuid,
  p_member_id    uuid default null
)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  v_aantal integer;
begin
  if public.taak_mijn_rol(p_household_id) is null then
    raise exception 'Je bent geen actief lid van dit huishouden';
  end if;

  delete from tasks
  where household_id = p_household_id
    and checked
    and member_id is not distinct from p_member_id;

  get diagnostics v_aantal = row_count;
  return v_aantal;
end;
$$;


-- 8. Rechten op de functies ------------------------------------
revoke all on function public.taak_mijn_rol(uuid)                    from public, anon;
revoke all on function public.voeg_taak_toe(uuid, text, uuid, date)  from public, anon;
revoke all on function public.wissel_taak(uuid)                      from public, anon;
revoke all on function public.verwijder_taak(uuid)                   from public, anon;
revoke all on function public.wis_gedane_taken(uuid, uuid)           from public, anon;

grant execute on function public.taak_mijn_rol(uuid)                   to authenticated;
grant execute on function public.voeg_taak_toe(uuid, text, uuid, date) to authenticated;
grant execute on function public.wissel_taak(uuid)                     to authenticated;
grant execute on function public.verwijder_taak(uuid)                  to authenticated;
grant execute on function public.wis_gedane_taken(uuid, uuid)          to authenticated;


-- 9. Realtime aanzetten, zodat iedereen wijzigingen meteen ziet -
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'tasks'
  ) then
    alter publication supabase_realtime add table public.tasks;
  end if;
end $$;
