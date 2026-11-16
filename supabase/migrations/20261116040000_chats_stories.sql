-- ─────────────────────────────────────────────────────────────────────────────
-- Chats (1-to-1, groups, 24 h live chats from a map hub) and 24 h stories.
-- ─────────────────────────────────────────────────────────────────────────────

-- Chats -----------------------------------------------------------------------

create table if not exists public.chat_threads (
    id uuid primary key default gen_random_uuid(),
    kind text not null check (kind in ('direct', 'group', 'cluster')),
    title text check (title is null or char_length(title) between 1 and 60),
    emoji text not null default '' check (char_length(emoji) <= 8),
    created_by uuid not null default auth.uid() references auth.users (id) on delete cascade,
    created_at timestamptz not null default now(),
    expires_at timestamptz
);

create table if not exists public.chat_members (
    thread_id uuid not null references public.chat_threads (id) on delete cascade,
    user_id uuid not null references public.profiles (id) on delete cascade,
    joined_at timestamptz not null default now(),
    last_read_at timestamptz not null default now(),
    primary key (thread_id, user_id)
);
create index if not exists chat_members_user_idx on public.chat_members (user_id);

create table if not exists public.chat_messages (
    id uuid primary key default gen_random_uuid(),
    thread_id uuid not null references public.chat_threads (id) on delete cascade,
    sender_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
    kind text not null check (kind in ('text', 'photo', 'pin_reply', 'story_reply', 'location')),
    body text not null default '' check (char_length(body) <= 2000),
    attachment_bucket text check (attachment_bucket is null or attachment_bucket in ('chat', 'pins', 'stories')),
    attachment_path text check (attachment_path is null or char_length(attachment_path) <= 300),
    ref_id uuid,
    place_name text check (place_name is null or char_length(place_name) <= 120),
    latitude double precision check (latitude is null or latitude between -90 and 90),
    longitude double precision check (longitude is null or longitude between -180 and 180),
    eta_minutes integer check (eta_minutes is null or eta_minutes between 0 and 1440),
    created_at timestamptz not null default now()
);
create index if not exists chat_messages_thread_idx on public.chat_messages (thread_id, created_at desc);

create table if not exists public.chat_reactions (
    message_id uuid not null references public.chat_messages (id) on delete cascade,
    user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
    emoji text not null check (char_length(emoji) between 1 and 8),
    created_at timestamptz not null default now(),
    primary key (message_id, user_id, emoji)
);

create or replace function public.is_chat_member(thread uuid, uid uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.chat_members m
        join public.chat_threads t on t.id = m.thread_id
        where m.thread_id = thread and m.user_id = uid
          and (t.expires_at is null or t.expires_at > now())
    );
$$;

alter table public.chat_threads enable row level security;
alter table public.chat_members enable row level security;
alter table public.chat_messages enable row level security;
alter table public.chat_reactions enable row level security;

drop policy if exists chat_threads_select on public.chat_threads;
create policy chat_threads_select on public.chat_threads
    for select to authenticated using (public.is_chat_member(id, auth.uid()));

drop policy if exists chat_members_select on public.chat_members;
create policy chat_members_select on public.chat_members
    for select to authenticated using (public.is_chat_member(thread_id, auth.uid()));

drop policy if exists chat_messages_select on public.chat_messages;
create policy chat_messages_select on public.chat_messages
    for select to authenticated using (public.is_chat_member(thread_id, auth.uid()));
drop policy if exists chat_messages_insert on public.chat_messages;
create policy chat_messages_insert on public.chat_messages
    for insert to authenticated
    with check (sender_id = auth.uid() and public.is_chat_member(thread_id, auth.uid()));
drop policy if exists chat_messages_delete on public.chat_messages;
create policy chat_messages_delete on public.chat_messages
    for delete to authenticated using (sender_id = auth.uid());

drop policy if exists chat_reactions_select on public.chat_reactions;
create policy chat_reactions_select on public.chat_reactions
    for select to authenticated
    using (exists (select 1 from public.chat_messages m where m.id = message_id));
drop policy if exists chat_reactions_insert on public.chat_reactions;
create policy chat_reactions_insert on public.chat_reactions
    for insert to authenticated
    with check (user_id = auth.uid() and exists (select 1 from public.chat_messages m where m.id = message_id));
drop policy if exists chat_reactions_delete on public.chat_reactions;
create policy chat_reactions_delete on public.chat_reactions
    for delete to authenticated using (user_id = auth.uid());

grant select on public.chat_threads, public.chat_members to authenticated;
grant select, insert, delete on public.chat_messages, public.chat_reactions to authenticated;

-- Opens (or creates) the 1-to-1 chat with a friend.
create or replace function public.open_direct_chat(friend uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    me uuid := auth.uid();
    found_id uuid;
begin
    if me is null then raise exception 'not signed in'; end if;
    if friend = me or not public.are_friends(me, friend) then raise exception 'not friends'; end if;
    select t.id into found_id
    from public.chat_threads t
    where t.kind = 'direct'
      and exists (select 1 from public.chat_members m where m.thread_id = t.id and m.user_id = me)
      and exists (select 1 from public.chat_members m where m.thread_id = t.id and m.user_id = friend)
    limit 1;
    if found_id is not null then return found_id; end if;
    insert into public.chat_threads (kind, created_by) values ('direct', me) returning id into found_id;
    insert into public.chat_members (thread_id, user_id) values (found_id, me), (found_id, friend);
    return found_id;
end;
$$;

-- Creates a group with friends. ephemeral_hours > 0 makes it a live chat that disappears.
create or replace function public.create_group_chat(title text, emoji text, members uuid[], ephemeral_hours integer default 0)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    me uuid := auth.uid();
    new_id uuid;
    member uuid;
begin
    if me is null then raise exception 'not signed in'; end if;
    if title is null or btrim(title) = '' then raise exception 'missing title'; end if;
    if coalesce(array_length(members, 1), 0) = 0 then raise exception 'no members'; end if;
    insert into public.chat_threads (kind, title, emoji, created_by, expires_at)
    values (
        case when ephemeral_hours > 0 then 'cluster' else 'group' end,
        left(btrim(title), 60), left(coalesce(emoji, ''), 8), me,
        case when ephemeral_hours > 0 then now() + make_interval(hours => least(ephemeral_hours, 48)) end
    )
    returning id into new_id;
    insert into public.chat_members (thread_id, user_id) values (new_id, me);
    foreach member in array members loop
        if member <> me and public.are_friends(me, member) then
            insert into public.chat_members (thread_id, user_id) values (new_id, member) on conflict do nothing;
        end if;
    end loop;
    return new_id;
end;
$$;

create or replace function public.mark_chat_read(thread uuid)
returns void
language sql
security definer
set search_path = ''
as $$
    update public.chat_members set last_read_at = now() where thread_id = thread and user_id = auth.uid();
$$;

create or replace function public.leave_chat(thread uuid)
returns void
language sql
security definer
set search_path = ''
as $$
    delete from public.chat_members where thread_id = thread and user_id = auth.uid();
$$;

-- All my conversations with participants, last message and unread count.
create or replace function public.my_chat_threads()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
    select coalesce(jsonb_agg(row_data order by sort_at desc), '[]'::jsonb)
    from (
        select
            jsonb_build_object(
                'id', t.id,
                'kind', t.kind,
                'title', t.title,
                'emoji', t.emoji,
                'created_at', t.created_at,
                'expires_at', t.expires_at,
                'participants', (
                    select coalesce(jsonb_agg(to_jsonb(p)), '[]'::jsonb)
                    from public.chat_members m join public.profiles p on p.id = m.user_id
                    where m.thread_id = t.id
                ),
                'last_message', (
                    select to_jsonb(lm) from (
                        select msg.id, msg.thread_id, msg.sender_id, msg.kind, msg.body, msg.attachment_bucket,
                               msg.attachment_path, msg.ref_id, msg.place_name, msg.latitude, msg.longitude,
                               msg.eta_minutes, msg.created_at
                        from public.chat_messages msg
                        where msg.thread_id = t.id
                        order by msg.created_at desc
                        limit 1
                    ) lm
                ),
                'unread_count', (
                    select count(*)
                    from public.chat_messages msg
                    where msg.thread_id = t.id and msg.sender_id <> auth.uid() and msg.created_at > me.last_read_at
                )
            ) as row_data,
            coalesce((select max(msg.created_at) from public.chat_messages msg where msg.thread_id = t.id), t.created_at) as sort_at
        from public.chat_threads t
        join public.chat_members me on me.thread_id = t.id and me.user_id = auth.uid()
        where t.expires_at is null or t.expires_at > now()
    ) rows;
$$;

revoke all on function public.open_direct_chat(uuid) from public, anon;
revoke all on function public.create_group_chat(text, text, uuid[], integer) from public, anon;
revoke all on function public.mark_chat_read(uuid) from public, anon;
revoke all on function public.leave_chat(uuid) from public, anon;
revoke all on function public.my_chat_threads() from public, anon;
grant execute on function public.open_direct_chat(uuid) to authenticated;
grant execute on function public.create_group_chat(text, text, uuid[], integer) to authenticated;
grant execute on function public.mark_chat_read(uuid) to authenticated;
grant execute on function public.leave_chat(uuid) to authenticated;
grant execute on function public.my_chat_threads() to authenticated;

-- Stories -----------------------------------------------------------------------

create table if not exists public.stories (
    id uuid primary key default gen_random_uuid(),
    author_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
    image_path text not null check (char_length(image_path) <= 300),
    overlay_text text not null default '' check (char_length(overlay_text) <= 80),
    overlay_y double precision not null default 0.75 check (overlay_y between 0 and 1),
    location_tag text check (location_tag is null or char_length(location_tag) <= 120),
    created_at timestamptz not null default now(),
    expires_at timestamptz not null default (now() + interval '24 hours')
);
create index if not exists stories_author_idx on public.stories (author_id, created_at desc);

create table if not exists public.story_views (
    story_id uuid not null references public.stories (id) on delete cascade,
    viewer_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
    viewed_at timestamptz not null default now(),
    liked boolean not null default false,
    primary key (story_id, viewer_id)
);

alter table public.stories enable row level security;
alter table public.story_views enable row level security;

drop policy if exists stories_select on public.stories;
create policy stories_select on public.stories
    for select to authenticated
    using (expires_at > now() and (author_id = auth.uid() or public.are_friends(auth.uid(), author_id)));
drop policy if exists stories_insert on public.stories;
create policy stories_insert on public.stories
    for insert to authenticated
    with check (author_id = auth.uid() and expires_at <= now() + interval '24 hours 5 minutes');
drop policy if exists stories_delete on public.stories;
create policy stories_delete on public.stories
    for delete to authenticated using (author_id = auth.uid());

drop policy if exists story_views_select on public.story_views;
create policy story_views_select on public.story_views
    for select to authenticated
    using (
        viewer_id = auth.uid()
        or exists (select 1 from public.stories s where s.id = story_id and s.author_id = auth.uid())
    );
drop policy if exists story_views_insert on public.story_views;
create policy story_views_insert on public.story_views
    for insert to authenticated
    with check (viewer_id = auth.uid() and exists (select 1 from public.stories s where s.id = story_id));
drop policy if exists story_views_update on public.story_views;
create policy story_views_update on public.story_views
    for update to authenticated
    using (viewer_id = auth.uid())
    with check (viewer_id = auth.uid());

grant select, insert, delete on public.stories to authenticated;
grant select, insert, update on public.story_views to authenticated;

-- Storage -----------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
    ('chat', 'chat', false, 6291456, array['image/jpeg']),
    ('stories', 'stories', false, 6291456, array['image/jpeg'])
on conflict (id) do update
    set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists chat_objects_insert on storage.objects;
create policy chat_objects_insert on storage.objects
    for insert to authenticated
    with check (
        bucket_id = 'chat'
        and (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$'
        and public.is_chat_member(((storage.foldername(name))[1])::uuid, auth.uid())
    );
drop policy if exists chat_objects_select on storage.objects;
create policy chat_objects_select on storage.objects
    for select to authenticated
    using (
        bucket_id = 'chat'
        and (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$'
        and public.is_chat_member(((storage.foldername(name))[1])::uuid, auth.uid())
    );

drop policy if exists story_objects_insert on storage.objects;
create policy story_objects_insert on storage.objects
    for insert to authenticated
    with check (bucket_id = 'stories' and (storage.foldername(name))[1] = (select auth.uid())::text);
drop policy if exists story_objects_delete on storage.objects;
create policy story_objects_delete on storage.objects
    for delete to authenticated
    using (bucket_id = 'stories' and (storage.foldername(name))[1] = (select auth.uid())::text);
drop policy if exists story_objects_select on storage.objects;
create policy story_objects_select on storage.objects
    for select to authenticated
    using (
        bucket_id = 'stories'
        and (
            (storage.foldername(name))[1] = (select auth.uid())::text
            or (
                (storage.foldername(name))[1] ~ '^[0-9a-f-]{36}$'
                and public.are_friends(auth.uid(), ((storage.foldername(name))[1])::uuid)
            )
        )
    );

-- Housekeeping: expired stories and live chats go away.
create or replace function public.cleanup_chats_stories()
returns void
language sql
security definer
set search_path = ''
as $$
    delete from public.stories where expires_at < now() - interval '1 hour';
    delete from public.chat_threads where expires_at is not null and expires_at < now() - interval '1 hour';
$$;
revoke all on function public.cleanup_chats_stories() from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'pindrop-cleanup-chats-stories';
select cron.schedule('pindrop-cleanup-chats-stories', '17 * * * *', 'select public.cleanup_chats_stories()');
