-- PinDrop — initial schema: profiles, friendships, pins, reactions, pings, storage.
-- Privacy & reciprocity are enforced server-side with Row Level Security.

-- ─────────────────────────────────────────────────────────────────────────────
-- Profiles
-- ─────────────────────────────────────────────────────────────────────────────
create table public.profiles (
    id            uuid primary key references auth.users (id) on delete cascade,
    username      text not null unique check (username ~ '^[a-z0-9._]{3,24}$'),
    display_name  text not null check (char_length(display_name) between 1 and 40),
    bio           text not null default '' check (char_length(bio) <= 160),
    status_emoji  text not null default '' check (char_length(status_emoji) <= 8),
    avatar_color  text not null default '#7C3AED' check (avatar_color ~ '^#[0-9A-Fa-f]{6}$'),
    avatar_path   text,
    invite_code   text not null unique default ('PD-' || upper(substr(md5(gen_random_uuid()::text), 1, 6))),
    is_setup      boolean not null default false,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now()
);

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    new.updated_at := now();
    new.id := old.id;
    new.invite_code := old.invite_code;
    return new;
end;
$$;

create trigger profiles_touch_updated_at
    before update on public.profiles
    for each row execute function public.touch_updated_at();

-- Creates a profile for every new auth user (email sign-up).
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    base text;
begin
    base := regexp_replace(lower(coalesce(split_part(new.email, '@', 1), 'user')), '[^a-z0-9._]', '', 'g');
    if char_length(base) < 3 then
        base := 'user';
    end if;
    insert into public.profiles (id, username, display_name)
    values (
        new.id,
        left(base, 15) || '_' || substr(replace(new.id::text, '-', ''), 1, 6),
        left(coalesce(nullif(new.raw_user_meta_data ->> 'display_name', ''), split_part(new.email, '@', 1), 'PinDrop'), 40)
    );
    return new;
end;
$$;

create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_user();

-- ─────────────────────────────────────────────────────────────────────────────
-- Friendships
-- ─────────────────────────────────────────────────────────────────────────────
create table public.friendships (
    id            uuid primary key default gen_random_uuid(),
    requester_id  uuid not null references public.profiles (id) on delete cascade,
    addressee_id  uuid not null references public.profiles (id) on delete cascade,
    status        text not null default 'pending' check (status in ('pending', 'accepted')),
    created_at    timestamptz not null default now(),
    responded_at  timestamptz,
    check (requester_id <> addressee_id)
);

create unique index friendships_pair_unique
    on public.friendships (least(requester_id, addressee_id), greatest(requester_id, addressee_id));
create index friendships_addressee_idx on public.friendships (addressee_id);
create index friendships_requester_idx on public.friendships (requester_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- Pins (6-hour lifetime, enforced by trigger)
-- ─────────────────────────────────────────────────────────────────────────────
create table public.pins (
    id          uuid primary key default gen_random_uuid(),
    author_id   uuid not null default auth.uid() references public.profiles (id) on delete cascade,
    latitude    double precision not null check (latitude between -90 and 90),
    longitude   double precision not null check (longitude between -180 and 180),
    place_name  text check (place_name is null or char_length(place_name) <= 120),
    caption     text not null default '' check (char_length(caption) <= 40),
    image_path  text not null,
    thumb_path  text not null,
    blur_path   text not null,
    created_at  timestamptz not null default now(),
    expires_at  timestamptz not null default (now() + interval '6 hours'),
    check (image_path like author_id::text || '/' || id::text || '/%'),
    check (thumb_path like author_id::text || '/' || id::text || '/%'),
    check (blur_path like author_id::text || '/' || id::text || '/%')
);

create index pins_author_expires_idx on public.pins (author_id, expires_at desc);
create index pins_expires_idx on public.pins (expires_at);

create or replace function public.pins_enforce_lifetime()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    new.author_id := auth.uid();
    new.created_at := now();
    new.expires_at := now() + interval '6 hours';
    return new;
end;
$$;

create trigger pins_enforce_lifetime
    before insert on public.pins
    for each row execute function public.pins_enforce_lifetime();

-- ─────────────────────────────────────────────────────────────────────────────
-- Reactions & "On my way" pings
-- ─────────────────────────────────────────────────────────────────────────────
create table public.reactions (
    pin_id      uuid not null references public.pins (id) on delete cascade,
    user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
    emoji       text not null check (emoji in ('🔥', '😍', '😂', '👀', '🫶')),
    created_at  timestamptz not null default now(),
    primary key (pin_id, user_id, emoji)
);

create index reactions_user_idx on public.reactions (user_id);

create table public.pings (
    id           uuid primary key default gen_random_uuid(),
    from_id      uuid not null default auth.uid() references public.profiles (id) on delete cascade,
    to_id        uuid not null references public.profiles (id) on delete cascade,
    pin_id       uuid references public.pins (id) on delete set null,
    eta_seconds  integer not null check (eta_seconds between 0 and 86400),
    created_at   timestamptz not null default now(),
    seen_at      timestamptz
);

create index pings_to_unseen_idx on public.pings (to_id, created_at desc) where seen_at is null;
create index pings_from_idx on public.pings (from_id);
create index pings_pin_idx on public.pings (pin_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- Helper functions
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.are_friends(a uuid, b uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.friendships f
        where f.status = 'accepted'
          and ((f.requester_id = a and f.addressee_id = b) or (f.requester_id = b and f.addressee_id = a))
    );
$$;

create or replace function public.has_active_pin(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1 from public.pins p where p.author_id = uid and p.expires_at > now()
    );
$$;

-- Sends a request by invite code or username. Accepts automatically if the other
-- person already sent one. Returns: requested | accepted | already_friends |
-- already_requested | not_found | self.
create or replace function public.send_friend_request(target text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
    me uuid := auth.uid();
    other uuid;
    existing public.friendships%rowtype;
    cleaned text := trim(target);
begin
    if me is null then
        raise exception 'not_authenticated';
    end if;

    select p.id into other
    from public.profiles p
    where p.invite_code = upper(cleaned)
       or p.username = lower(trim(leading '@' from cleaned))
    limit 1;

    if other is null then
        return 'not_found';
    end if;
    if other = me then
        return 'self';
    end if;

    select * into existing
    from public.friendships f
    where (f.requester_id = me and f.addressee_id = other)
       or (f.requester_id = other and f.addressee_id = me);

    if found then
        if existing.status = 'accepted' then
            return 'already_friends';
        end if;
        if existing.requester_id = other then
            update public.friendships
               set status = 'accepted', responded_at = now()
             where id = existing.id;
            return 'accepted';
        end if;
        return 'already_requested';
    end if;

    insert into public.friendships (requester_id, addressee_id) values (me, other);
    return 'requested';
end;
$$;

create or replace function public.respond_friend_request(request_id uuid, accept boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    me uuid := auth.uid();
begin
    if me is null then
        raise exception 'not_authenticated';
    end if;
    if accept then
        update public.friendships
           set status = 'accepted', responded_at = now()
         where id = request_id and addressee_id = me and status = 'pending';
    else
        delete from public.friendships
         where id = request_id and addressee_id = me and status = 'pending';
    end if;
end;
$$;

revoke all on function public.are_friends(uuid, uuid) from public, anon;
revoke all on function public.has_active_pin(uuid) from public, anon;
revoke all on function public.send_friend_request(text) from public, anon;
revoke all on function public.respond_friend_request(uuid, boolean) from public, anon;
revoke all on function public.handle_new_user() from public, anon, authenticated;
grant execute on function public.are_friends(uuid, uuid) to authenticated;
grant execute on function public.has_active_pin(uuid) to authenticated;
grant execute on function public.send_friend_request(text) to authenticated;
grant execute on function public.respond_friend_request(uuid, boolean) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- Row Level Security
-- ─────────────────────────────────────────────────────────────────────────────
alter table public.profiles enable row level security;
alter table public.friendships enable row level security;
alter table public.pins enable row level security;
alter table public.reactions enable row level security;
alter table public.pings enable row level security;

-- Profiles: any signed-in user can look people up (search by username / invite code);
-- only the owner can edit their profile.
create policy profiles_select on public.profiles
    for select to authenticated using (true);
create policy profiles_update on public.profiles
    for update to authenticated
    using (id = (select auth.uid()))
    with check (id = (select auth.uid()));

-- Friendships: visible to both sides; created/accepted through RPCs; either side can delete.
create policy friendships_select on public.friendships
    for select to authenticated
    using ((select auth.uid()) in (requester_id, addressee_id));
create policy friendships_delete on public.friendships
    for delete to authenticated
    using ((select auth.uid()) in (requester_id, addressee_id));

-- Pins: own pins always; friends' pins only while alive.
create policy pins_select on public.pins
    for select to authenticated
    using (
        author_id = (select auth.uid())
        or (expires_at > now() and public.are_friends((select auth.uid()), author_id))
    );
create policy pins_insert on public.pins
    for insert to authenticated
    with check (author_id = (select auth.uid()));
create policy pins_delete on public.pins
    for delete to authenticated
    using (author_id = (select auth.uid()));

-- Reactions: visible with the pin; reacting to a friend's pin requires your own live drop.
create policy reactions_select on public.reactions
    for select to authenticated
    using (exists (select 1 from public.pins p where p.id = pin_id));
create policy reactions_insert on public.reactions
    for insert to authenticated
    with check (
        user_id = (select auth.uid())
        and exists (
            select 1 from public.pins p
            where p.id = pin_id
              and (p.author_id = (select auth.uid()) or public.has_active_pin((select auth.uid())))
        )
    );
create policy reactions_delete on public.reactions
    for delete to authenticated
    using (user_id = (select auth.uid()));

-- Pings: only between friends.
create policy pings_select on public.pings
    for select to authenticated
    using ((select auth.uid()) in (from_id, to_id));
create policy pings_insert on public.pings
    for insert to authenticated
    with check (from_id = (select auth.uid()) and public.are_friends((select auth.uid()), to_id));
create policy pings_update on public.pings
    for update to authenticated
    using (to_id = (select auth.uid()))
    with check (to_id = (select auth.uid()));

-- ─────────────────────────────────────────────────────────────────────────────
-- Storage
--   avatars/{uid}/avatar-{ts}.jpg            public read, owner write
--   pins/{uid}/{pinId}/full.jpg|thumb.jpg     owner, or friend WITH a live drop
--   pins/{uid}/{pinId}/blur.jpg               owner or any friend (pre-blurred preview)
-- ─────────────────────────────────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
    ('avatars', 'avatars', true, 2097152, array['image/jpeg']),
    ('pins', 'pins', false, 5242880, array['image/jpeg'])
on conflict (id) do nothing;

create policy avatars_insert on storage.objects
    for insert to authenticated
    with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
-- Upsert uploads (INSERT ... ON CONFLICT DO UPDATE ... RETURNING) also need SELECT.
create policy avatars_select on storage.objects
    for select to authenticated
    using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy avatars_update on storage.objects
    for update to authenticated
    using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text)
    with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy avatars_delete on storage.objects
    for delete to authenticated
    using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy pin_objects_insert on storage.objects
    for insert to authenticated
    with check (bucket_id = 'pins' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy pin_objects_delete on storage.objects
    for delete to authenticated
    using (bucket_id = 'pins' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy pin_objects_select on storage.objects
    for select to authenticated
    using (
        bucket_id = 'pins'
        and (
            (storage.foldername(name))[1] = (select auth.uid())::text
            or (
                -- the pin row must be visible (friend + not expired, via pins RLS)
                exists (select 1 from public.pins p where p.id::text = (storage.foldername(name))[2])
                and (storage.filename(name) = 'blur.jpg' or public.has_active_pin((select auth.uid())))
            )
        )
    );
