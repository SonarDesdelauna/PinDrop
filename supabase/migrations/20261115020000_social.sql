-- PinDrop — public places, profile views, notifications, time together (best friends), contacts.

-- ─────────────────────────────────────────────────────────────────────────────
-- Public places
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.places add column is_public boolean not null default false;
alter table public.places add column added_from uuid references public.places (id) on delete set null;
create index places_public_idx on public.places (is_public) where is_public;

create policy places_select_public on public.places
    for select to authenticated using (is_public);

drop function public.my_places();
create function public.my_places()
returns table (
    id uuid,
    name text,
    emoji text,
    latitude double precision,
    longitude double precision,
    radius_m integer,
    is_public boolean,
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
        p.id, p.name, p.emoji, p.latitude, p.longitude, p.radius_m, p.is_public, p.created_at,
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

-- Other people's public places around a point, with their owner.
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
security invoker
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

-- ─────────────────────────────────────────────────────────────────────────────
-- Notifications (written only by triggers / security definer functions)
-- ─────────────────────────────────────────────────────────────────────────────
create table public.notifications (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid not null references public.profiles (id) on delete cascade,
    kind        text not null check (kind in ('friend_request', 'friend_accepted', 'ping', 'place_reached', 'best_friend')),
    actor_id    uuid references public.profiles (id) on delete cascade,
    place_id    uuid references public.places (id) on delete cascade,
    payload     jsonb not null default '{}'::jsonb,
    created_at  timestamptz not null default now(),
    read_at     timestamptz
);

create index notifications_user_idx on public.notifications (user_id, created_at desc);
create index notifications_actor_idx on public.notifications (actor_id);
create index notifications_place_idx on public.notifications (place_id);

alter table public.notifications enable row level security;

create policy notifications_select on public.notifications
    for select to authenticated using (user_id = (select auth.uid()));
create policy notifications_update on public.notifications
    for update to authenticated
    using (user_id = (select auth.uid()))
    with check (user_id = (select auth.uid()));
create policy notifications_delete on public.notifications
    for delete to authenticated using (user_id = (select auth.uid()));

create function public.notify_friendship()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if tg_op = 'INSERT' and new.status = 'pending' then
        insert into public.notifications (user_id, kind, actor_id) values (new.addressee_id, 'friend_request', new.requester_id);
    elsif tg_op = 'UPDATE' and old.status = 'pending' and new.status = 'accepted' then
        insert into public.notifications (user_id, kind, actor_id) values (new.requester_id, 'friend_accepted', new.addressee_id);
        delete from public.notifications
         where user_id = new.addressee_id and kind = 'friend_request' and actor_id = new.requester_id;
    end if;
    return new;
end;
$$;

create trigger friendships_notify
    after insert or update on public.friendships
    for each row execute function public.notify_friendship();

create function public.notify_ping()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.notifications (user_id, kind, actor_id, payload)
    values (new.to_id, 'ping', new.from_id, jsonb_build_object('eta_seconds', new.eta_seconds));
    return new;
end;
$$;

create trigger pings_notify
    after insert on public.pings
    for each row execute function public.notify_ping();

-- ─────────────────────────────────────────────────────────────────────────────
-- Place reached: extend record_presence to notify about other people's public places
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.record_presence(lat double precision, lon double precision)
returns integer
language plpgsql
security definer
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

    -- Someone else's public place: suggest adding it (once a day per place).
    insert into public.notifications (user_id, kind, actor_id, place_id)
    select me, 'place_reached', p.owner_id, p.id
    from public.places p
    where p.is_public
      and p.owner_id <> me
      and public.distance_m(p.latitude, p.longitude, lat, lon) <= p.radius_m
      and not exists (select 1 from public.places mine where mine.owner_id = me and mine.added_from = p.id)
      and not exists (
          select 1 from public.notifications n
          where n.user_id = me and n.kind = 'place_reached' and n.place_id = p.id
            and n.created_at > now() - interval '24 hours'
      );

    return touched;
end;
$$;

revoke all on function public.record_presence(double precision, double precision) from public, anon;
grant execute on function public.record_presence(double precision, double precision) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- Profile views
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.profiles add column view_count bigint not null default 0;

create table public.profile_views (
    viewer_id  uuid not null references public.profiles (id) on delete cascade,
    viewed_id  uuid not null references public.profiles (id) on delete cascade,
    viewed_on  date not null default current_date,
    viewed_at  timestamptz not null default now(),
    primary key (viewer_id, viewed_id, viewed_on),
    check (viewer_id <> viewed_id)
);

create index profile_views_viewed_idx on public.profile_views (viewed_id);
alter table public.profile_views enable row level security;
-- No client policies: written and counted only by record_profile_view().

-- Counts at most one view per viewer per day.
create function public.record_profile_view(target uuid)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
    me uuid := auth.uid();
    inserted integer;
    total bigint;
begin
    if me is null then
        raise exception 'not_authenticated';
    end if;
    if target = me then
        select view_count into total from public.profiles where id = me;
        return total;
    end if;
    insert into public.profile_views (viewer_id, viewed_id) values (me, target)
    on conflict do nothing;
    get diagnostics inserted = row_count;
    if inserted > 0 then
        update public.profiles set view_count = view_count + 1 where id = target returning view_count into total;
    else
        select view_count into total from public.profiles where id = target;
    end if;
    return total;
end;
$$;

-- Keep view_count server-controlled: owners cannot edit it through profile updates.
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    new.updated_at := now();
    new.id := old.id;
    new.invite_code := old.invite_code;
    if current_user = 'authenticated' then
        new.view_count := old.view_count;
    end if;
    return new;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Time together → best friends
-- ─────────────────────────────────────────────────────────────────────────────
create table public.live_locations (
    user_id     uuid primary key references public.profiles (id) on delete cascade,
    latitude    double precision not null,
    longitude   double precision not null,
    updated_at  timestamptz not null default now()
);
alter table public.live_locations enable row level security;
-- No client policies: live positions are never readable by other users.

create table public.friend_time (
    user_a            uuid not null references public.profiles (id) on delete cascade,
    user_b            uuid not null references public.profiles (id) on delete cascade,
    seconds           bigint not null default 0,
    last_credited_at  timestamptz,
    best_since        timestamptz,
    primary key (user_a, user_b),
    check (user_a < user_b)
);
create index friend_time_b_idx on public.friend_time (user_b);
alter table public.friend_time enable row level security;
create policy friend_time_select on public.friend_time
    for select to authenticated using ((select auth.uid()) in (user_a, user_b));

-- Called every couple of minutes while the app is open. Credits time spent within 150 m of
-- friends who are also online, and promotes the pair to best friends after 2 hours.
create function public.heartbeat(lat double precision, lon double precision)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
    me uuid := auth.uid();
    friend record;
    a uuid;
    b uuid;
    credit double precision;
    total bigint;
    promoted timestamptz;
    together integer := 0;
begin
    if me is null then
        raise exception 'not_authenticated';
    end if;

    insert into public.live_locations (user_id, latitude, longitude, updated_at)
    values (me, lat, lon, now())
    on conflict (user_id) do update set latitude = excluded.latitude, longitude = excluded.longitude, updated_at = now();

    for friend in
        select l.user_id
        from public.live_locations l
        where l.user_id <> me
          and l.updated_at > now() - interval '5 minutes'
          and public.are_friends(me, l.user_id)
          and public.distance_m(l.latitude, l.longitude, lat, lon) <= 150
    loop
        a := least(me, friend.user_id);
        b := greatest(me, friend.user_id);
        insert into public.friend_time (user_a, user_b) values (a, b) on conflict do nothing;

        select extract(epoch from now() - greatest(coalesce(ft.last_credited_at, now() - interval '5 minutes'), now() - interval '5 minutes'))
          into credit
        from public.friend_time ft where ft.user_a = a and ft.user_b = b;

        update public.friend_time ft
           set seconds = ft.seconds + greatest(0, floor(credit))::bigint,
               last_credited_at = now()
         where ft.user_a = a and ft.user_b = b
        returning ft.seconds, ft.best_since into total, promoted;

        if promoted is null and total >= 7200 then
            update public.friend_time set best_since = now() where user_a = a and user_b = b;
            insert into public.notifications (user_id, kind, actor_id) values (a, 'best_friend', b), (b, 'best_friend', a);
        end if;
        together := together + 1;
    end loop;

    return together;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Contacts matching (hashed: emails and phone numbers never leave the device in clear)
-- ─────────────────────────────────────────────────────────────────────────────
create table public.contact_info (
    user_id     uuid primary key default auth.uid() references public.profiles (id) on delete cascade,
    phone_hash  text check (phone_hash is null or phone_hash ~ '^[0-9a-f]{64}$'),
    updated_at  timestamptz not null default now()
);
create index contact_info_phone_idx on public.contact_info (phone_hash);
alter table public.contact_info enable row level security;
create policy contact_info_select on public.contact_info
    for select to authenticated using (user_id = (select auth.uid()));
create policy contact_info_insert on public.contact_info
    for insert to authenticated with check (user_id = (select auth.uid()));
create policy contact_info_update on public.contact_info
    for update to authenticated
    using (user_id = (select auth.uid()))
    with check (user_id = (select auth.uid()));
create policy contact_info_delete on public.contact_info
    for delete to authenticated using (user_id = (select auth.uid()));

-- Returns PinDrop users whose sha256(lowercased email) or phone hash is in the given lists.
create function public.match_contacts(email_hashes text[], phone_hashes text[])
returns table (matched_hash text, profile_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
    select encode(extensions.digest(lower(u.email), 'sha256'), 'hex'), u.id
    from auth.users u
    join public.profiles p on p.id = u.id
    where u.id <> (select auth.uid())
      and cardinality(email_hashes) <= 3000
      and encode(extensions.digest(lower(u.email), 'sha256'), 'hex') = any(email_hashes)
    union
    select c.phone_hash, c.user_id
    from public.contact_info c
    where c.user_id <> (select auth.uid())
      and cardinality(phone_hashes) <= 3000
      and c.phone_hash = any(phone_hashes);
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Grants
-- ─────────────────────────────────────────────────────────────────────────────
revoke all on function public.public_places_near(double precision, double precision, double precision) from public, anon;
revoke all on function public.my_places() from public, anon;
revoke all on function public.record_profile_view(uuid) from public, anon;
revoke all on function public.heartbeat(double precision, double precision) from public, anon;
revoke all on function public.match_contacts(text[], text[]) from public, anon;
revoke all on function public.notify_friendship() from public, anon, authenticated;
revoke all on function public.notify_ping() from public, anon, authenticated;
grant execute on function public.public_places_near(double precision, double precision, double precision) to authenticated;
grant execute on function public.my_places() to authenticated;
grant execute on function public.record_profile_view(uuid) to authenticated;
grant execute on function public.heartbeat(double precision, double precision) to authenticated;
grant execute on function public.match_contacts(text[], text[]) to authenticated;
