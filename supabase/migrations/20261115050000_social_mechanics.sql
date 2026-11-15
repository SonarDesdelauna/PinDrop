-- PinDrop — Sync Shot, Cross-Paths ("Sfiorati") and Geo-Capsules.

-- ─────────────────────────────────────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.distance_m(lat1 double precision, lon1 double precision, lat2 double precision, lon2 double precision)
returns double precision
language sql
immutable
set search_path = ''
as $$
    select 2 * 6371008.8 * asin(sqrt(
        power(sin(radians(lat2 - lat1) / 2), 2)
        + cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)
    ));
$$;

grant execute on function public.distance_m(double precision, double precision, double precision, double precision) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- Sync Shot: two friends shoot at the same instant; each publishes a pin linked
-- to the same session, shown together as a split-screen card.
-- ─────────────────────────────────────────────────────────────────────────────

create table public.sync_sessions (
    id            uuid primary key default gen_random_uuid(),
    initiator_id  uuid not null references public.profiles (id) on delete cascade,
    partner_id    uuid not null references public.profiles (id) on delete cascade,
    status        text not null default 'pending' check (status in ('pending', 'ready', 'armed', 'cancelled')),
    fire_at       timestamptz,
    created_at    timestamptz not null default now(),
    check (initiator_id <> partner_id)
);

create index sync_sessions_partner_idx on public.sync_sessions (partner_id, created_at desc);
create index sync_sessions_initiator_idx on public.sync_sessions (initiator_id, created_at desc);

alter table public.sync_sessions enable row level security;

create policy sync_sessions_select on public.sync_sessions
    for select to authenticated
    using ((select auth.uid()) in (initiator_id, partner_id));

alter table public.pins
    add column sync_session_id uuid references public.sync_sessions (id) on delete set null;

create index pins_sync_session_idx on public.pins (sync_session_id) where sync_session_id is not null;

-- A pin can only join a sync session its author takes part in.
create or replace function public.pins_enforce_lifetime()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    new.author_id := auth.uid();
    new.created_at := now();
    new.expires_at := now() + interval '6 hours';
    if new.sync_session_id is not null and not exists (
        select 1 from public.sync_sessions s
        where s.id = new.sync_session_id
          and new.author_id in (s.initiator_id, s.partner_id)
          and s.status = 'armed'
    ) then
        raise exception 'invalid sync session';
    end if;
    return new;
end;
$$;

create or replace function public.sync_invite(partner uuid)
returns public.sync_sessions
language plpgsql
security definer
set search_path = ''
as $$
declare
    me uuid := auth.uid();
    created public.sync_sessions;
begin
    if me is null or partner is null or partner = me then
        raise exception 'invalid partner';
    end if;
    if not public.are_friends(me, partner) then
        raise exception 'not friends';
    end if;
    update public.sync_sessions
        set status = 'cancelled'
        where status in ('pending', 'ready')
          and (initiator_id = me or partner_id = me);
    insert into public.sync_sessions (initiator_id, partner_id)
        values (me, partner)
        returning * into created;
    return created;
end;
$$;

create or replace function public.sync_respond(session uuid, accept boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    update public.sync_sessions
        set status = case when accept then 'ready' else 'cancelled' end
        where id = session
          and partner_id = auth.uid()
          and status = 'pending'
          and created_at > now() - interval '5 minutes';
end;
$$;

-- Starts the shared countdown: both phones shoot at fire_at.
create or replace function public.sync_arm(session uuid)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
    fire timestamptz;
begin
    update public.sync_sessions
        set status = 'armed', fire_at = now() + interval '3600 milliseconds'
        where id = session
          and auth.uid() in (initiator_id, partner_id)
          and status = 'ready'
        returning fire_at into fire;
    if fire is null then
        select s.fire_at into fire from public.sync_sessions s
            where s.id = session and auth.uid() in (s.initiator_id, s.partner_id) and s.status = 'armed';
    end if;
    return fire;
end;
$$;

create or replace function public.sync_cancel(session uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    update public.sync_sessions
        set status = 'cancelled'
        where id = session
          and auth.uid() in (initiator_id, partner_id)
          and status in ('pending', 'ready');
end;
$$;

-- Session state plus the server clock, so both phones agree on the countdown.
create or replace function public.sync_poll(session uuid)
returns table (status text, fire_at timestamptz, server_now timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
    select s.status, s.fire_at, now()
    from public.sync_sessions s
    where s.id = session and auth.uid() in (s.initiator_id, s.partner_id);
$$;

revoke all on function public.sync_invite(uuid) from public, anon;
revoke all on function public.sync_respond(uuid, boolean) from public, anon;
revoke all on function public.sync_arm(uuid) from public, anon;
revoke all on function public.sync_cancel(uuid) from public, anon;
revoke all on function public.sync_poll(uuid) from public, anon;
grant execute on function public.sync_invite(uuid) to authenticated;
grant execute on function public.sync_respond(uuid, boolean) to authenticated;
grant execute on function public.sync_arm(uuid) to authenticated;
grant execute on function public.sync_cancel(uuid) to authenticated;
grant execute on function public.sync_poll(uuid) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- Cross-paths: two friends dropped a pin within 40 m of each other, more than
-- 5 minutes apart, in the last 6 hours. Both pins unlock for both of them.
-- ─────────────────────────────────────────────────────────────────────────────

create table public.cross_paths (
    id             uuid primary key default gen_random_uuid(),
    user_a         uuid not null references public.profiles (id) on delete cascade,
    user_b         uuid not null references public.profiles (id) on delete cascade,
    pin_a          uuid not null references public.pins (id) on delete cascade,
    pin_b          uuid not null references public.pins (id) on delete cascade,
    latitude       double precision not null,
    longitude      double precision not null,
    distance_m     double precision not null,
    delta_seconds  integer not null,
    created_at     timestamptz not null default now(),
    unique (pin_a, pin_b)
);

create index cross_paths_user_a_idx on public.cross_paths (user_a, created_at desc);
create index cross_paths_user_b_idx on public.cross_paths (user_b, created_at desc);

alter table public.cross_paths enable row level security;

create policy cross_paths_select on public.cross_paths
    for select to authenticated
    using ((select auth.uid()) in (user_a, user_b));

create or replace function public.detect_cross_paths_for(new_pin uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    mine public.pins;
begin
    select * into mine from public.pins where id = new_pin;
    if mine.id is null then
        return;
    end if;
    insert into public.cross_paths (user_a, user_b, pin_a, pin_b, latitude, longitude, distance_m, delta_seconds)
    select
        mine.author_id,
        other.author_id,
        mine.id,
        other.id,
        (mine.latitude + other.latitude) / 2,
        (mine.longitude + other.longitude) / 2,
        public.distance_m(mine.latitude, mine.longitude, other.latitude, other.longitude),
        abs(extract(epoch from (mine.created_at - other.created_at)))::integer
    from public.pins other
    where other.author_id <> mine.author_id
      and other.expires_at > now()
      and other.created_at > now() - interval '6 hours'
      and abs(extract(epoch from (mine.created_at - other.created_at))) > 300
      and (other.sync_session_id is null or other.sync_session_id is distinct from mine.sync_session_id)
      and public.are_friends(mine.author_id, other.author_id)
      and public.distance_m(mine.latitude, mine.longitude, other.latitude, other.longitude) < 40
    on conflict (pin_a, pin_b) do nothing;
end;
$$;

revoke all on function public.detect_cross_paths_for(uuid) from public, anon, authenticated;

create or replace function public.pins_detect_cross_paths()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform public.detect_cross_paths_for(new.id);
    return new;
end;
$$;

revoke all on function public.pins_detect_cross_paths() from public, anon, authenticated;

create trigger pins_detect_cross_paths
    after insert on public.pins
    for each row execute function public.pins_detect_cross_paths();

-- Re-checks your live pins (e.g. a friend became your friend after both drops).
create or replace function public.detect_cross_paths()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    pin_id uuid;
begin
    for pin_id in
        select p.id from public.pins p
        where p.author_id = auth.uid() and p.expires_at > now() and p.created_at > now() - interval '6 hours'
    loop
        perform public.detect_cross_paths_for(pin_id);
    end loop;
end;
$$;

revoke all on function public.detect_cross_paths() from public, anon;
grant execute on function public.detect_cross_paths() to authenticated;

-- Photos of a cross-path are readable by both people, even with a locked map.
drop policy if exists pin_objects_select on storage.objects;
create policy pin_objects_select on storage.objects
    for select to authenticated
    using (
        bucket_id = 'pins'
        and (
            (storage.foldername(name))[1] = (select auth.uid())::text
            or (
                exists (select 1 from public.pins p where p.id::text = (storage.foldername(name))[2])
                and (
                    storage.filename(name) = 'blur.jpg'
                    or public.has_active_pin((select auth.uid()))
                    or exists (
                        select 1 from public.cross_paths c
                        where (c.pin_a::text = (storage.foldername(name))[2] or c.pin_b::text = (storage.foldername(name))[2])
                          and (select auth.uid()) in (c.user_a, c.user_b)
                    )
                )
            )
        )
    );

-- ─────────────────────────────────────────────────────────────────────────────
-- Geo-Capsules: a photo + secret message anchored to a spot for 24 hours. Friends
-- see where it is and a hint; it opens only within 20 m (checked by the server).
-- ─────────────────────────────────────────────────────────────────────────────

create table public.geo_capsules (
    id            uuid primary key default gen_random_uuid(),
    author_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
    recipient_id  uuid references public.profiles (id) on delete cascade,
    latitude      double precision not null check (latitude between -90 and 90),
    longitude     double precision not null check (longitude between -180 and 180),
    hint          text not null default '' check (char_length(hint) <= 80),
    image_path    text not null,
    thumb_path    text not null,
    created_at    timestamptz not null default now(),
    expires_at    timestamptz not null default (now() + interval '24 hours'),
    check (image_path like author_id::text || '/' || id::text || '/%'),
    check (thumb_path like author_id::text || '/' || id::text || '/%')
);

create index geo_capsules_author_idx on public.geo_capsules (author_id, expires_at desc);
create index geo_capsules_expires_idx on public.geo_capsules (expires_at);

create table public.capsule_secrets (
    capsule_id  uuid primary key references public.geo_capsules (id) on delete cascade,
    message     text not null default '' check (char_length(message) <= 140)
);

create table public.capsule_opens (
    capsule_id  uuid not null references public.geo_capsules (id) on delete cascade,
    user_id     uuid not null references public.profiles (id) on delete cascade,
    opened_at   timestamptz not null default now(),
    primary key (capsule_id, user_id)
);

create or replace function public.geo_capsules_enforce()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    new.author_id := auth.uid();
    new.created_at := now();
    new.expires_at := now() + interval '24 hours';
    if new.recipient_id is not null and not public.are_friends(new.author_id, new.recipient_id) then
        raise exception 'recipient is not a friend';
    end if;
    return new;
end;
$$;

create trigger geo_capsules_enforce
    before insert on public.geo_capsules
    for each row execute function public.geo_capsules_enforce();

alter table public.geo_capsules enable row level security;
alter table public.capsule_secrets enable row level security;
alter table public.capsule_opens enable row level security;

create or replace function public.can_see_capsule(c public.geo_capsules, uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select c.author_id = uid
        or (c.expires_at > now()
            and public.are_friends(uid, c.author_id)
            and (c.recipient_id is null or c.recipient_id = uid));
$$;

revoke all on function public.can_see_capsule(public.geo_capsules, uuid) from public, anon;
grant execute on function public.can_see_capsule(public.geo_capsules, uuid) to authenticated;

create policy geo_capsules_select on public.geo_capsules
    for select to authenticated
    using (
        author_id = (select auth.uid())
        or (expires_at > now()
            and public.are_friends((select auth.uid()), author_id)
            and (recipient_id is null or recipient_id = (select auth.uid())))
    );
create policy geo_capsules_insert on public.geo_capsules
    for insert to authenticated
    with check (author_id = (select auth.uid()));
create policy geo_capsules_delete on public.geo_capsules
    for delete to authenticated
    using (author_id = (select auth.uid()));

create policy capsule_secrets_select on public.capsule_secrets
    for select to authenticated
    using (
        exists (select 1 from public.geo_capsules c where c.id = capsule_id and c.author_id = (select auth.uid()))
        or exists (select 1 from public.capsule_opens o where o.capsule_id = capsule_secrets.capsule_id and o.user_id = (select auth.uid()))
    );
create policy capsule_secrets_insert on public.capsule_secrets
    for insert to authenticated
    with check (exists (select 1 from public.geo_capsules c where c.id = capsule_id and c.author_id = (select auth.uid())));

create policy capsule_opens_select on public.capsule_opens
    for select to authenticated
    using (
        user_id = (select auth.uid())
        or exists (select 1 from public.geo_capsules c where c.id = capsule_id and c.author_id = (select auth.uid()))
    );

-- Opens a capsule if you are standing within 20 m of it (a little GPS slack).
create or replace function public.open_capsule(capsule uuid, lat double precision, lon double precision)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    me uuid := auth.uid();
    c public.geo_capsules;
begin
    select * into c from public.geo_capsules where id = capsule;
    if c.id is null or me is null or not public.can_see_capsule(c, me) then
        return false;
    end if;
    if c.author_id <> me and public.distance_m(lat, lon, c.latitude, c.longitude) > 25 then
        return false;
    end if;
    insert into public.capsule_opens (capsule_id, user_id) values (c.id, me)
        on conflict do nothing;
    return true;
end;
$$;

revoke all on function public.open_capsule(uuid, double precision, double precision) from public, anon;
grant execute on function public.open_capsule(uuid, double precision, double precision) to authenticated;

-- Storage: capsules/{uid}/{capsuleId}/full.jpg|thumb.jpg — owner, or whoever opened it.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('capsules', 'capsules', false, 5242880, array['image/jpeg'])
on conflict (id) do nothing;

create policy capsule_objects_insert on storage.objects
    for insert to authenticated
    with check (bucket_id = 'capsules' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy capsule_objects_delete on storage.objects
    for delete to authenticated
    using (bucket_id = 'capsules' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy capsule_objects_select on storage.objects
    for select to authenticated
    using (
        bucket_id = 'capsules'
        and (
            (storage.foldername(name))[1] = (select auth.uid())::text
            or exists (
                select 1 from public.capsule_opens o
                where o.capsule_id::text = (storage.foldername(name))[2]
                  and o.user_id = (select auth.uid())
            )
        )
    );
