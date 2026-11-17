-- PinDrop: the Relay (Staffetta). You drop a relay photo and pass the baton to a friend, who has
-- 24 hours to drop the next leg somewhere else and pass it on. The map draws the line from leg to
-- leg. If the time runs out the chain breaks, and everyone sees who dropped it.
-- Visible to the people in the relay and to their friends.

create table public.relays (
    id          uuid primary key default gen_random_uuid(),
    created_by  uuid not null references public.profiles (id) on delete cascade,
    title       text not null check (char_length(title) between 1 and 40),
    emoji       text not null default '🏃' check (char_length(emoji) <= 8),
    status      text not null default 'active' check (status in ('active', 'broken', 'finished')),
    holder_id   uuid references public.profiles (id) on delete set null,
    passed_by   uuid references public.profiles (id) on delete set null,
    deadline    timestamptz,
    reminded    boolean not null default false,
    broken_by   uuid references public.profiles (id) on delete set null,
    ended_at    timestamptz,
    created_at  timestamptz not null default now()
);
create index relays_holder_idx on public.relays (holder_id) where status = 'active';
create index relays_deadline_idx on public.relays (deadline) where status = 'active';
create index relays_created_by_idx on public.relays (created_by);

create table public.relay_legs (
    id          uuid primary key default gen_random_uuid(),
    relay_id    uuid not null references public.relays (id) on delete cascade,
    seq         integer not null,
    runner_id   uuid not null references public.profiles (id) on delete cascade,
    latitude    double precision not null check (latitude between -90 and 90),
    longitude   double precision not null check (longitude between -180 and 180),
    place_name  text check (place_name is null or char_length(place_name) <= 120),
    caption     text not null default '' check (char_length(caption) <= 40),
    image_path  text not null check (char_length(image_path) <= 300),
    thumb_path  text not null check (char_length(thumb_path) <= 300),
    created_at  timestamptz not null default now(),
    unique (relay_id, seq)
);
create index relay_legs_runner_idx on public.relay_legs (runner_id);

alter table public.relays enable row level security;
alter table public.relay_legs enable row level security;

-- Everyone who ran a leg, plus whoever holds the baton now.
create function public.relay_participants(target uuid)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
    select l.runner_id from public.relay_legs l where l.relay_id = target
    union
    select r.holder_id from public.relays r where r.id = target and r.holder_id is not null;
$$;
revoke all on function public.relay_participants(uuid) from public, anon, authenticated;

create function public.can_see_relay(target uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select (select auth.uid()) is not null and exists (
        select 1 from public.relay_participants(target) p
        where p = (select auth.uid()) or public.are_friends((select auth.uid()), p)
    );
$$;
revoke all on function public.can_see_relay(uuid) from public, anon;
grant execute on function public.can_see_relay(uuid) to authenticated;

create policy relays_select on public.relays
    for select to authenticated using (public.can_see_relay(id));
create policy relay_legs_select on public.relay_legs
    for select to authenticated using (public.can_see_relay(relay_id));

-- Photos: relays/{uid}/{relay}/{leg}.jpg (+ _thumb.jpg). Readable by whoever can see the relay.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('relays', 'relays', false, 10485760, array['image/jpeg'])
on conflict (id) do nothing;

create policy relay_objects_insert on storage.objects
    for insert to authenticated
    with check (bucket_id = 'relays' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy relay_objects_delete on storage.objects
    for delete to authenticated
    using (bucket_id = 'relays' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy relay_objects_select on storage.objects
    for select to authenticated
    using (
        bucket_id = 'relays'
        and (
            (storage.foldername(name))[1] = (select auth.uid())::text
            or ((storage.foldername(name))[2] ~ '^[0-9a-f-]{36}$' and public.can_see_relay(((storage.foldername(name))[2])::uuid))
        )
    );

-- Breaks the relays whose time ran out and reminds holders 3 hours before the end.
create function public.expire_relays()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    relay record;
begin
    for relay in
        select r.id, r.holder_id, left(r.emoji || ' ' || r.title, 60) as label
        from public.relays r
        where r.status = 'active' and r.deadline < now()
        for update skip locked
    loop
        update public.relays
           set status = 'broken', broken_by = relay.holder_id, ended_at = now()
         where id = relay.id;
        insert into public.push_events (user_id, kind, actor_id, ref_id, detail)
        select p, 'relay_broken', relay.holder_id, relay.id, relay.label
        from public.relay_participants(relay.id) p;
    end loop;

    for relay in
        select r.id, r.holder_id, r.passed_by, left(r.emoji || ' ' || r.title, 60) as label
        from public.relays r
        where r.status = 'active' and not r.reminded and r.deadline < now() + interval '3 hours'
        for update skip locked
    loop
        update public.relays set reminded = true where id = relay.id;
        insert into public.push_events (user_id, kind, actor_id, ref_id, detail)
        values (relay.holder_id, 'relay_reminder', relay.passed_by, relay.id, relay.label);
    end loop;
end;
$$;
revoke all on function public.expire_relays() from public, anon, authenticated;

-- Starts a relay with its first leg and passes the baton to a friend.
-- The photos are uploaded first to relays/{me}/{relay_id}/{leg_id}.jpg.
create function public.start_relay(
    relay_id uuid, leg_id uuid, title text, emoji text,
    lat double precision, lon double precision, place_name text, caption text,
    image_path text, thumb_path text, pass_to uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    me uuid := auth.uid();
    prefix text;
    label text;
begin
    if me is null then
        raise exception 'not_authenticated';
    end if;
    if pass_to is null or pass_to = me or not public.are_friends(me, pass_to) then
        raise exception 'relay_not_friend';
    end if;
    prefix := me::text || '/' || relay_id::text || '/';
    if left(image_path, char_length(prefix)) <> prefix or left(thumb_path, char_length(prefix)) <> prefix then
        raise exception 'relay_bad_path';
    end if;

    insert into public.relays (id, created_by, title, emoji, holder_id, passed_by, deadline)
    values (relay_id, me, left(coalesce(nullif(trim(title), ''), 'Staffetta'), 40), left(coalesce(nullif(emoji, ''), '🏃'), 8),
            pass_to, me, now() + interval '24 hours');
    insert into public.relay_legs (id, relay_id, seq, runner_id, latitude, longitude, place_name, caption, image_path, thumb_path)
    values (leg_id, relay_id, 1, me, lat, lon, left(place_name, 120), left(coalesce(caption, ''), 40), image_path, thumb_path);

    select left(r.emoji || ' ' || r.title, 60) into label from public.relays r where r.id = relay_id;
    insert into public.push_events (user_id, kind, actor_id, ref_id, detail)
    values (pass_to, 'relay_baton', me, relay_id, label);
    return relay_id;
end;
$$;
revoke all on function public.start_relay(uuid, uuid, text, text, double precision, double precision, text, text, text, text, uuid) from public, anon;
grant execute on function public.start_relay(uuid, uuid, text, text, double precision, double precision, text, text, text, text, uuid) to authenticated;

-- Runs your leg (you must hold the baton, in time, at least 300 m from the last leg) and passes
-- it to a friend who is not in the relay yet, or finishes the relay when pass_to is null.
create function public.run_relay_leg(
    target uuid, leg_id uuid,
    lat double precision, lon double precision, place_name text, caption text,
    image_path text, thumb_path text, pass_to uuid
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    me uuid := auth.uid();
    relay record;
    last_leg record;
    next_seq integer;
    prefix text;
    label text;
begin
    if me is null then
        raise exception 'not_authenticated';
    end if;
    perform public.expire_relays();

    select r.* into relay from public.relays r where r.id = target for update;
    if relay.id is null then
        raise exception 'relay_not_found';
    end if;
    if relay.status <> 'active' then
        raise exception 'relay_over';
    end if;
    if relay.holder_id is distinct from me then
        raise exception 'relay_not_holder';
    end if;
    prefix := me::text || '/' || target::text || '/';
    if left(image_path, char_length(prefix)) <> prefix or left(thumb_path, char_length(prefix)) <> prefix then
        raise exception 'relay_bad_path';
    end if;

    select l.* into last_leg from public.relay_legs l where l.relay_id = target order by l.seq desc limit 1;
    if last_leg.id is not null and public.distance_m(last_leg.latitude, last_leg.longitude, lat, lon) < 300 then
        raise exception 'relay_too_close';
    end if;
    if pass_to is not null then
        if pass_to = me or not public.are_friends(me, pass_to) then
            raise exception 'relay_not_friend';
        end if;
        if exists (select 1 from public.relay_legs l where l.relay_id = target and l.runner_id = pass_to) then
            raise exception 'relay_already_ran';
        end if;
    end if;

    next_seq := coalesce(last_leg.seq, 0) + 1;
    insert into public.relay_legs (id, relay_id, seq, runner_id, latitude, longitude, place_name, caption, image_path, thumb_path)
    values (leg_id, target, next_seq, me, lat, lon, left(place_name, 120), left(coalesce(caption, ''), 40), image_path, thumb_path);
    label := left(relay.emoji || ' ' || relay.title, 60);

    if pass_to is null then
        update public.relays
           set status = 'finished', holder_id = null, deadline = null, ended_at = now()
         where id = target;
        insert into public.push_events (user_id, kind, actor_id, ref_id, sub, detail)
        select p, 'relay_finished', me, target, next_seq::text, label
        from public.relay_participants(target) p
        where p <> me;
    else
        update public.relays
           set holder_id = pass_to, passed_by = me, deadline = now() + interval '24 hours', reminded = false
         where id = target;
        insert into public.push_events (user_id, kind, actor_id, ref_id, detail)
        values (pass_to, 'relay_baton', me, target, label);
        insert into public.push_events (user_id, kind, actor_id, ref_id, sub, detail)
        select p, 'relay_leg', me, target, left(place_name, 120), label
        from public.relay_participants(target) p
        where p <> me and p <> pass_to;
    end if;
    return next_seq;
end;
$$;
revoke all on function public.run_relay_leg(uuid, uuid, double precision, double precision, text, text, text, text, uuid) from public, anon;
grant execute on function public.run_relay_leg(uuid, uuid, double precision, double precision, text, text, text, text, uuid) to authenticated;

-- The relays you can see (active ones, and the ones that ended in the last 7 days), with legs
-- and the people involved, as JSON.
create function public.my_relays()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    me uuid := auth.uid();
    result jsonb;
begin
    if me is null then
        raise exception 'not_authenticated';
    end if;
    perform public.expire_relays();

    with visible as (
        select r.*
        from public.relays r
        where (r.status = 'active' or r.ended_at > now() - interval '7 days')
          and exists (
              select 1 from public.relay_participants(r.id) p
              where p = me or public.are_friends(me, p)
          )
        order by (r.status = 'active') desc, r.created_at desc
        limit 50
    )
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', v.id,
        'title', v.title,
        'emoji', v.emoji,
        'status', v.status,
        'created_by', v.created_by,
        'created_at', v.created_at,
        'deadline', v.deadline,
        'ended_at', v.ended_at,
        'holder', (select to_jsonb(h) from (select p.id, p.username, p.display_name, p.avatar_color, p.avatar_path from public.profiles p where p.id = v.holder_id) h),
        'passed_by', v.passed_by,
        'broken_by', (select to_jsonb(b) from (select p.id, p.username, p.display_name, p.avatar_color, p.avatar_path from public.profiles p where p.id = v.broken_by) b),
        'legs', (
            select coalesce(jsonb_agg(jsonb_build_object(
                'id', l.id,
                'seq', l.seq,
                'latitude', l.latitude,
                'longitude', l.longitude,
                'place_name', l.place_name,
                'caption', l.caption,
                'image_path', l.image_path,
                'thumb_path', l.thumb_path,
                'created_at', l.created_at,
                'runner', jsonb_build_object('id', p.id, 'username', p.username, 'display_name', p.display_name, 'avatar_color', p.avatar_color, 'avatar_path', p.avatar_path)
            ) order by l.seq), '[]'::jsonb)
            from public.relay_legs l
            join public.profiles p on p.id = l.runner_id
            where l.relay_id = v.id
        )
    ) order by (v.status = 'active') desc, v.created_at desc), '[]'::jsonb)
    into result
    from visible v;
    return result;
end;
$$;
revoke all on function public.my_relays() from public, anon;
grant execute on function public.my_relays() to authenticated;
