-- PinDrop: live location shared with friends (also in the background when the user allows
-- "Always"), and each user's location permission so friends can be reminded to switch it.

alter table public.live_locations
    add column if not exists permission text not null default 'when_in_use'
        check (permission in ('always', 'when_in_use', 'denied'));

-- Friends can see each other's last position.
create policy live_locations_select_friends on public.live_locations
    for select to authenticated
    using (user_id = (select auth.uid()) or public.are_friends((select auth.uid()), user_id));

-- Location permission, readable by friends even when no position was ever shared.
create table public.location_permissions (
    user_id     uuid primary key references public.profiles (id) on delete cascade,
    permission  text not null check (permission in ('always', 'when_in_use', 'denied')),
    updated_at  timestamptz not null default now()
);
alter table public.location_permissions enable row level security;
create policy location_permissions_select_friends on public.location_permissions
    for select to authenticated
    using (user_id = (select auth.uid()) or public.are_friends((select auth.uid()), user_id));

-- Stores the current position (foreground or background) and the permission.
create function public.report_location(lat double precision, lon double precision, perm text)
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
    end if;
    insert into public.location_permissions (user_id, permission, updated_at)
    values (me, p, now())
    on conflict (user_id) do update set permission = excluded.permission, updated_at = now();
end;
$$;

revoke all on function public.report_location(double precision, double precision, text) from public, anon;
grant execute on function public.report_location(double precision, double precision, text) to authenticated;
