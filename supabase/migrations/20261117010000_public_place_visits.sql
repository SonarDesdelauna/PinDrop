-- PinDrop: visits of public places by everyone (not only by the owner), and a leaderboard
-- of who has been there the most, with friends flagged.

create table public.public_place_visits (
    id            uuid primary key default gen_random_uuid(),
    place_id      uuid not null references public.places (id) on delete cascade,
    user_id       uuid not null references public.profiles (id) on delete cascade,
    arrived_at    timestamptz not null default now(),
    last_seen_at  timestamptz not null default now()
);
create index public_place_visits_place_idx on public.public_place_visits (place_id, user_id, last_seen_at desc);
create index public_place_visits_user_idx on public.public_place_visits (user_id);
alter table public.public_place_visits enable row level security;
-- No client policies: written by record_public_visits(), read through public_place_visitors().

-- Extends the ongoing visit (or starts a new one after 2 hours away) of every public place
-- around (lat, lon) for `who`.
create function public.record_public_visits(who uuid, lat double precision, lon double precision)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    place record;
    ongoing uuid;
    touched integer := 0;
begin
    if who is null or lat is null or lon is null then
        return 0;
    end if;
    for place in
        select p.id from public.places p
        where p.is_public
          and p.latitude between lat - 0.02 and lat + 0.02
          and public.distance_m(p.latitude, p.longitude, lat, lon) <= p.radius_m
    loop
        select v.id into ongoing
        from public.public_place_visits v
        where v.place_id = place.id and v.user_id = who and v.last_seen_at > now() - interval '2 hours'
        order by v.last_seen_at desc
        limit 1;
        if ongoing is null then
            insert into public.public_place_visits (place_id, user_id) values (place.id, who);
        else
            update public.public_place_visits set last_seen_at = now() where id = ongoing;
        end if;
        touched := touched + 1;
    end loop;
    return touched;
end;
$$;
revoke all on function public.record_public_visits(uuid, double precision, double precision) from public, anon, authenticated;

-- Everyone who has been at a public place, most visits first.
create function public.public_place_visitors(place uuid)
returns table (
    user_id uuid,
    display_name text,
    username text,
    avatar_color text,
    avatar_path text,
    visit_count bigint,
    last_visit_at timestamptz,
    is_friend boolean,
    is_me boolean
)
language sql
stable
security definer
set search_path = ''
as $$
    select u.id, u.display_name, u.username, u.avatar_color, u.avatar_path,
           count(v.id) as visit_count,
           max(v.last_seen_at) as last_visit_at,
           public.are_friends((select auth.uid()), u.id) as is_friend,
           u.id = (select auth.uid()) as is_me
    from public.public_place_visits v
    join public.places p on p.id = v.place_id and p.is_public
    join public.profiles u on u.id = v.user_id
    where v.place_id = place
      and (select auth.uid()) is not null
    group by u.id
    order by count(v.id) desc, max(v.last_seen_at) desc
    limit 300;
$$;
revoke all on function public.public_place_visitors(uuid) from public, anon;
grant execute on function public.public_place_visitors(uuid) to authenticated;

-- Past visits: owners at their own public places, and people at their copies of a public place.
insert into public.public_place_visits (place_id, user_id, arrived_at, last_seen_at)
select p.id, v.owner_id, v.arrived_at, v.last_seen_at
from public.place_visits v
join public.places p on p.id = v.place_id
where p.is_public;

insert into public.public_place_visits (place_id, user_id, arrived_at, last_seen_at)
select src.id, v.owner_id, v.arrived_at, v.last_seen_at
from public.place_visits v
join public.places c on c.id = v.place_id
join public.places src on src.id = c.added_from and src.is_public;

-- Record public visits wherever the position is reported (foreground, background, saved places).
create or replace function public.report_location(lat double precision, lon double precision, perm text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    me uuid := (select auth.uid());
    p text := case when perm in ('always', 'when_in_use', 'denied') then perm else 'when_in_use' end;
begin
    if me is null then
        raise exception 'not authenticated';
    end if;
    if lat is not null and lon is not null and lat between -90 and 90 and lon between -180 and 180 then
        insert into public.live_locations (user_id, latitude, longitude, updated_at, permission)
        values (me, lat, lon, now(), p)
        on conflict (user_id) do update
            set latitude = excluded.latitude,
                longitude = excluded.longitude,
                updated_at = now(),
                permission = excluded.permission;
        perform public.record_public_visits(me, lat, lon);
    end if;
    insert into public.location_permissions (user_id, permission, updated_at)
    values (me, p, now())
    on conflict (user_id) do update set permission = excluded.permission, updated_at = now();
end;
$$;
revoke all on function public.report_location(double precision, double precision, text) from public, anon;
grant execute on function public.report_location(double precision, double precision, text) to authenticated;
