-- PinDrop: the Mayor of a public place. Whoever has been there the most times (at least 2
-- visits) wears the crown. A mayor keeps it until someone has strictly more visits; both get
-- a notification when the crown changes hands.

create table public.place_mayors (
    place_id    uuid primary key references public.places (id) on delete cascade,
    user_id     uuid not null references public.profiles (id) on delete cascade,
    visits      integer not null default 0,
    since       timestamptz not null default now()
);
create index place_mayors_user_idx on public.place_mayors (user_id);
alter table public.place_mayors enable row level security;
-- Mayors are public, like the places they rule.
create policy place_mayors_select on public.place_mayors
    for select to authenticated using (true);

-- Recomputes the mayor of one place after a new visit.
create function public.update_mayor(target uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    top_user uuid;
    top_count integer;
    current_user_id uuid;
    current_count integer;
    label text;
begin
    select v.user_id, count(*) into top_user, top_count
    from public.public_place_visits v
    where v.place_id = target
    group by v.user_id
    order by count(*) desc, min(v.arrived_at)
    limit 1;
    if top_user is null or top_count < 2 then
        return;
    end if;

    select left(p.emoji || ' ' || p.name, 120) into label from public.places p where p.id = target;
    select m.user_id into current_user_id from public.place_mayors m where m.place_id = target;

    if current_user_id is null then
        insert into public.place_mayors (place_id, user_id, visits) values (target, top_user, top_count);
        insert into public.push_events (user_id, kind, ref_id, detail)
        values (top_user, 'mayor_won', target, label);
        return;
    end if;

    if current_user_id = top_user then
        update public.place_mayors set visits = top_count where place_id = target;
        return;
    end if;

    select count(*) into current_count
    from public.public_place_visits v
    where v.place_id = target and v.user_id = current_user_id;

    if top_count > current_count then
        update public.place_mayors
           set user_id = top_user, visits = top_count, since = now()
         where place_id = target;
        insert into public.push_events (user_id, kind, actor_id, ref_id, detail)
        values (top_user, 'mayor_won', current_user_id, target, label),
               (current_user_id, 'mayor_lost', top_user, target, label);
    else
        update public.place_mayors set visits = current_count where place_id = target;
    end if;
end;
$$;
revoke all on function public.update_mayor(uuid) from public, anon, authenticated;

-- Same as before, plus the mayor check whenever a new visit starts.
create or replace function public.record_public_visits(who uuid, lat double precision, lon double precision)
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
            begin
                perform public.update_mayor(place.id);
            exception when others then
                null;
            end;
        else
            update public.public_place_visits set last_seen_at = now() where id = ongoing;
        end if;
        touched := touched + 1;
    end loop;
    return touched;
end;
$$;
revoke all on function public.record_public_visits(uuid, double precision, double precision) from public, anon, authenticated;

-- Public places around a point, now with their mayor.
drop function public.public_places_near(double precision, double precision, double precision);
create function public.public_places_near(lat double precision, lon double precision, radius_km double precision default 30)
returns table (
    id uuid,
    owner_id uuid,
    name text,
    emoji text,
    latitude double precision,
    longitude double precision,
    radius_m integer,
    owner_display_name text,
    owner_username text,
    owner_avatar_color text,
    owner_avatar_path text,
    mayor_id uuid,
    mayor_display_name text,
    mayor_username text,
    mayor_avatar_color text,
    mayor_avatar_path text,
    mayor_visits integer,
    mayor_since timestamptz
)
language sql
stable
set search_path = ''
as $$
    select p.id, p.owner_id, p.name, p.emoji, p.latitude, p.longitude, p.radius_m,
           o.display_name, o.username, o.avatar_color, o.avatar_path,
           m.user_id, mu.display_name, mu.username, mu.avatar_color, mu.avatar_path, m.visits, m.since
    from public.places p
    join public.profiles o on o.id = p.owner_id
    left join public.place_mayors m on m.place_id = p.id
    left join public.profiles mu on mu.id = m.user_id
    where p.is_public
      and p.owner_id <> (select auth.uid())
      and public.distance_m(p.latitude, p.longitude, lat, lon) <= least(radius_km, 200) * 1000
    order by public.distance_m(p.latitude, p.longitude, lat, lon)
    limit 200;
$$;
revoke all on function public.public_places_near(double precision, double precision, double precision) from public, anon;
grant execute on function public.public_places_near(double precision, double precision, double precision) to authenticated;

-- The public places a user is mayor of (shown on profiles and on your own places).
create function public.mayorships_of(who uuid)
returns table (
    place_id uuid,
    name text,
    emoji text,
    visits integer,
    since timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
    select p.id, p.name, p.emoji, m.visits, m.since
    from public.place_mayors m
    join public.places p on p.id = m.place_id and p.is_public
    where m.user_id = who
      and (select auth.uid()) is not null
    order by m.visits desc, m.since;
$$;
revoke all on function public.mayorships_of(uuid) from public, anon;
grant execute on function public.mayorships_of(uuid) to authenticated;

-- Crown the current leaders (no notifications for the past).
insert into public.place_mayors (place_id, user_id, visits, since)
select distinct on (v.place_id) v.place_id, v.user_id, count(*)::integer, now()
from public.public_place_visits v
join public.places p on p.id = v.place_id and p.is_public
group by v.place_id, v.user_id
having count(*) >= 2
order by v.place_id, count(*) desc, min(v.arrived_at);
