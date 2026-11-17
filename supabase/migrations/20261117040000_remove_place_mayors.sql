-- PinDrop: the Mayor of the place is dropped. Back to the previous visit recording and
-- public places list.

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
        else
            update public.public_place_visits set last_seen_at = now() where id = ongoing;
        end if;
        touched := touched + 1;
    end loop;
    return touched;
end;
$$;
revoke all on function public.record_public_visits(uuid, double precision, double precision) from public, anon, authenticated;

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
    owner_avatar_path text
)
language sql
stable
set search_path = ''
as $$
    select p.id, p.owner_id, p.name, p.emoji, p.latitude, p.longitude, p.radius_m,
           o.display_name, o.username, o.avatar_color, o.avatar_path
    from public.places p
    join public.profiles o on o.id = p.owner_id
    where p.is_public
      and p.owner_id <> (select auth.uid())
      and public.distance_m(p.latitude, p.longitude, lat, lon) <= least(radius_km, 200) * 1000
    order by public.distance_m(p.latitude, p.longitude, lat, lon)
    limit 200;
$$;
revoke all on function public.public_places_near(double precision, double precision, double precision) from public, anon;
grant execute on function public.public_places_near(double precision, double precision, double precision) to authenticated;

drop function public.mayorships_of(uuid);
drop function public.update_mayor(uuid);
drop table public.place_mayors;
delete from public.push_events where kind in ('mayor_won', 'mayor_lost');
