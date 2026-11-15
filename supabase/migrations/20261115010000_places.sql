-- PinDrop — saved places and visit counting (private to their owner).

create table public.places (
    id          uuid primary key default gen_random_uuid(),
    owner_id    uuid not null default auth.uid() references public.profiles (id) on delete cascade,
    name        text not null check (char_length(name) between 1 and 40),
    emoji       text not null default '📍' check (char_length(emoji) between 1 and 8),
    latitude    double precision not null check (latitude between -90 and 90),
    longitude   double precision not null check (longitude between -180 and 180),
    radius_m    integer not null default 100 check (radius_m between 25 and 1000),
    created_at  timestamptz not null default now()
);

create index places_owner_idx on public.places (owner_id);

create table public.place_visits (
    id            uuid primary key default gen_random_uuid(),
    place_id      uuid not null references public.places (id) on delete cascade,
    owner_id      uuid not null default auth.uid() references public.profiles (id) on delete cascade,
    arrived_at    timestamptz not null default now(),
    last_seen_at  timestamptz not null default now()
);

create index place_visits_place_idx on public.place_visits (place_id, last_seen_at desc);
create index place_visits_owner_idx on public.place_visits (owner_id);

alter table public.places enable row level security;
alter table public.place_visits enable row level security;

create policy places_select on public.places
    for select to authenticated using (owner_id = (select auth.uid()));
create policy places_insert on public.places
    for insert to authenticated with check (owner_id = (select auth.uid()));
create policy places_update on public.places
    for update to authenticated
    using (owner_id = (select auth.uid()))
    with check (owner_id = (select auth.uid()));
create policy places_delete on public.places
    for delete to authenticated using (owner_id = (select auth.uid()));

create policy place_visits_select on public.place_visits
    for select to authenticated using (owner_id = (select auth.uid()));
create policy place_visits_insert on public.place_visits
    for insert to authenticated
    with check (
        owner_id = (select auth.uid())
        and exists (select 1 from public.places p where p.id = place_id and p.owner_id = (select auth.uid()))
    );
create policy place_visits_update on public.place_visits
    for update to authenticated
    using (owner_id = (select auth.uid()))
    with check (owner_id = (select auth.uid()));
create policy place_visits_delete on public.place_visits
    for delete to authenticated using (owner_id = (select auth.uid()));

-- Great-circle distance in meters.
create or replace function public.distance_m(lat1 double precision, lon1 double precision, lat2 double precision, lon2 double precision)
returns double precision
language sql
immutable
set search_path = ''
as $$
    select 6371000 * 2 * asin(sqrt(
        power(sin(radians(lat2 - lat1) / 2), 2)
        + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)
    ));
$$;

-- Records that the signed-in user is at (lat, lon): extends the ongoing visit of every saved
-- place in range, or starts a new visit if the last one ended more than 2 hours ago.
-- Runs with the caller's rights, so RLS applies.
create or replace function public.record_presence(lat double precision, lon double precision)
returns integer
language plpgsql
security invoker
set search_path = ''
as $$
declare
    me uuid := auth.uid();
    place record;
    ongoing uuid;
    touched integer := 0;
begin
    if me is null then
        raise exception 'not_authenticated';
    end if;
    for place in
        select p.id from public.places p
        where p.owner_id = me
          and public.distance_m(p.latitude, p.longitude, lat, lon) <= p.radius_m
    loop
        select v.id into ongoing
        from public.place_visits v
        where v.place_id = place.id and v.last_seen_at > now() - interval '2 hours'
        order by v.last_seen_at desc
        limit 1;
        if ongoing is null then
            insert into public.place_visits (place_id, owner_id) values (place.id, me);
        else
            update public.place_visits set last_seen_at = now() where id = ongoing;
        end if;
        touched := touched + 1;
    end loop;
    return touched;
end;
$$;

-- The signed-in user's places with visit statistics.
create or replace function public.my_places()
returns table (
    id uuid,
    name text,
    emoji text,
    latitude double precision,
    longitude double precision,
    radius_m integer,
    created_at timestamptz,
    visit_count bigint,
    last_visit_at timestamptz,
    current_arrived_at timestamptz
)
language sql
stable
security invoker
set search_path = ''
as $$
    select
        p.id, p.name, p.emoji, p.latitude, p.longitude, p.radius_m, p.created_at,
        count(v.id) as visit_count,
        max(v.last_seen_at) as last_visit_at,
        (select v2.arrived_at from public.place_visits v2
          where v2.place_id = p.id and v2.last_seen_at > now() - interval '2 hours'
          order by v2.last_seen_at desc limit 1) as current_arrived_at
    from public.places p
    left join public.place_visits v on v.place_id = p.id
    where p.owner_id = (select auth.uid())
    group by p.id
    order by count(v.id) desc, p.created_at desc;
$$;

revoke all on function public.record_presence(double precision, double precision) from public, anon;
revoke all on function public.my_places() from public, anon;
grant execute on function public.record_presence(double precision, double precision) to authenticated;
grant execute on function public.my_places() to authenticated;
