-- PinDrop: device notifications. Every message, pin, capsule, story (from friends) and every
-- in-app notification becomes a push event for the people concerned. The apps fetch new events
-- (pending_push) while open and when the system wakes them in the background, and show them
-- as system notifications. Events are kept for 3 days.

create table public.push_events (
    id          bigint generated always as identity primary key,
    user_id     uuid not null references public.profiles (id) on delete cascade,
    -- message, pin, capsule, story, or an in-app notification kind (friend_request, ping, ...)
    kind        text not null,
    actor_id    uuid references public.profiles (id) on delete cascade,
    ref_id      uuid,
    thread_id   uuid references public.chat_threads (id) on delete cascade,
    sub         text,
    detail      text,
    created_at  timestamptz not null default now()
);
create index push_events_user_idx on public.push_events (user_id, id);
create index push_events_actor_idx on public.push_events (actor_id);
create index push_events_thread_idx on public.push_events (thread_id);
create index push_events_created_idx on public.push_events (created_at);
alter table public.push_events enable row level security;
create policy push_events_select on public.push_events
    for select to authenticated using (user_id = (select auth.uid()));

-- Accepted friends of a user.
create function public.friend_ids(who uuid)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
    select case when f.requester_id = who then f.addressee_id else f.requester_id end
    from public.friendships f
    where f.status = 'accepted' and who in (f.requester_id, f.addressee_id);
$$;
revoke all on function public.friend_ids(uuid) from public, anon, authenticated;

create function public.push_on_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.push_events (user_id, kind, actor_id, ref_id, thread_id, sub, detail)
    select m.user_id, 'message', new.sender_id, new.id, new.thread_id, new.kind, left(new.body, 160)
    from public.chat_members m
    where m.thread_id = new.thread_id and m.user_id <> new.sender_id;
    return new;
exception when others then
    return new;
end;
$$;

create function public.push_on_pin()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.push_events (user_id, kind, actor_id, ref_id, sub, detail)
    select f, 'pin', new.author_id, new.id, case when new.video_path is null then 'photo' else 'video' end, left(new.place_name, 120)
    from public.friend_ids(new.author_id) f;
    return new;
exception when others then
    return new;
end;
$$;

create function public.push_on_capsule()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if new.recipient_id is not null then
        if public.are_friends(new.author_id, new.recipient_id) then
            insert into public.push_events (user_id, kind, actor_id, ref_id, sub)
            values (new.recipient_id, 'capsule', new.author_id, new.id, 'for_you');
        end if;
    else
        insert into public.push_events (user_id, kind, actor_id, ref_id, sub)
        select f, 'capsule', new.author_id, new.id, 'friends'
        from public.friend_ids(new.author_id) f;
    end if;
    return new;
exception when others then
    return new;
end;
$$;

create function public.push_on_story()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.push_events (user_id, kind, actor_id, ref_id, sub, detail)
    select f, 'story', new.author_id, new.id, case when new.video_path is null then 'photo' else 'video' end, left(new.location_tag, 120)
    from public.friend_ids(new.author_id) f;
    return new;
exception when others then
    return new;
end;
$$;

create function public.push_on_notification()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.push_events (user_id, kind, actor_id, ref_id, detail)
    values (
        new.user_id, new.kind, new.actor_id, new.place_id,
        (select left(p.emoji || ' ' || p.name, 120) from public.places p where p.id = new.place_id)
    );
    return new;
exception when others then
    return new;
end;
$$;

create trigger chat_messages_push after insert on public.chat_messages
    for each row execute function public.push_on_message();
create trigger pins_push after insert on public.pins
    for each row execute function public.push_on_pin();
create trigger geo_capsules_push after insert on public.geo_capsules
    for each row execute function public.push_on_capsule();
create trigger stories_push after insert on public.stories
    for each row execute function public.push_on_story();
create trigger notifications_push after insert on public.notifications
    for each row execute function public.push_on_notification();

revoke all on function public.push_on_message() from public, anon, authenticated;
revoke all on function public.push_on_pin() from public, anon, authenticated;
revoke all on function public.push_on_capsule() from public, anon, authenticated;
revoke all on function public.push_on_story() from public, anon, authenticated;
revoke all on function public.push_on_notification() from public, anon, authenticated;

-- New events after `after` (an event id), oldest first, with the names needed for the text.
-- Pass null to get only the current cursor (no events), e.g. on first launch.
create function public.pending_push(after bigint)
returns table (
    id bigint,
    kind text,
    sub text,
    detail text,
    ref_id uuid,
    thread_id uuid,
    actor_id uuid,
    actor_name text,
    thread_title text,
    thread_emoji text,
    thread_kind text,
    created_at timestamptz
)
language sql
stable
security invoker
set search_path = ''
as $$
    select e.id, e.kind, e.sub, e.detail, e.ref_id, e.thread_id, e.actor_id,
           a.display_name, t.title, t.emoji, t.kind, e.created_at
    from public.push_events e
    left join public.profiles a on a.id = e.actor_id
    left join public.chat_threads t on t.id = e.thread_id
    where e.user_id = (select auth.uid())
      and after is not null
      and e.id > after
      and e.created_at > now() - interval '1 day'
    union all
    select coalesce(max(e.id), 0), 'cursor', null, null, null, null, null, null, null, null, null, now()
    from public.push_events e
    where e.user_id = (select auth.uid())
    having after is null
    order by 1
    limit 40;
$$;
revoke all on function public.pending_push(bigint) from public, anon;
grant execute on function public.pending_push(bigint) to authenticated;

-- Old events are dropped once a day-ish, piggybacking on new inserts.
create function public.push_events_cleanup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if random() < 0.02 then
        delete from public.push_events where created_at < now() - interval '3 days';
    end if;
    return null;
end;
$$;
revoke all on function public.push_events_cleanup() from public, anon, authenticated;
create trigger push_events_cleanup after insert on public.push_events
    for each statement execute function public.push_events_cleanup();
