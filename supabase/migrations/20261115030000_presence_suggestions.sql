-- PinDrop: "friend is online" (app open) and friend suggestions.

-- ─────────────────────────────────────────────────────────────────────────────
-- App presence: only "app open in the last minute", never a position.
-- ─────────────────────────────────────────────────────────────────────────────
create table public.app_presence (
    user_id       uuid primary key references public.profiles (id) on delete cascade,
    last_seen_at  timestamptz not null default now()
);
alter table public.app_presence enable row level security;
-- No client policies: read only through friends_online().

create function public.touch_presence()
returns void
language sql
security definer
set search_path = ''
as $$
    insert into public.app_presence (user_id, last_seen_at)
    values ((select auth.uid()), now())
    on conflict (user_id) do update set last_seen_at = now();
$$;

create function public.go_offline()
returns void
language sql
security definer
set search_path = ''
as $$
    delete from public.app_presence where user_id = (select auth.uid());
$$;

-- Friends with the app open right now.
create function public.friends_online()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
    select p.user_id
    from public.app_presence p
    where p.last_seen_at > now() - interval '75 seconds'
      and p.user_id <> (select auth.uid())
      and public.are_friends((select auth.uid()), p.user_id);
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Suggestions: friends of friends first, then people active near you.
-- Positions are never returned, only who and why.
-- ─────────────────────────────────────────────────────────────────────────────
create function public.suggested_friends(lim integer default 20)
returns table (profile_id uuid, mutual_count integer, reason text)
language sql
stable
security definer
set search_path = ''
as $$
    with me as (
        select (select auth.uid()) as id
    ),
    my_friends as (
        select case when f.requester_id = me.id then f.addressee_id else f.requester_id end as fid
        from public.friendships f, me
        where f.status = 'accepted' and me.id in (f.requester_id, f.addressee_id)
    ),
    related as (
        select case when f.requester_id = me.id then f.addressee_id else f.requester_id end as uid
        from public.friendships f, me
        where me.id in (f.requester_id, f.addressee_id)
    ),
    fof as (
        select case when f.requester_id = mf.fid then f.addressee_id else f.requester_id end as uid,
               count(*)::integer as mutual
        from public.friendships f
        join my_friends mf on mf.fid in (f.requester_id, f.addressee_id)
        where f.status = 'accepted'
        group by 1
    ),
    my_live as (
        select l.latitude, l.longitude
        from public.live_locations l, me
        where l.user_id = me.id
    ),
    nearby as (
        select l.user_id as uid
        from public.live_locations l, my_live m
        where l.updated_at > now() - interval '14 days'
          and public.distance_m(m.latitude, m.longitude, l.latitude, l.longitude) < 50000
    ),
    candidates as (
        select uid from fof
        union
        select uid from nearby
    )
    select c.uid,
           coalesce(fof.mutual, 0),
           case when fof.mutual is not null then 'mutual' else 'nearby' end
    from candidates c
    left join fof on fof.uid = c.uid
    join public.profiles p on p.id = c.uid and p.is_setup
    cross join me
    where c.uid <> me.id
      and c.uid not in (select uid from related)
    order by coalesce(fof.mutual, 0) desc, p.created_at desc
    limit greatest(1, least(coalesce(lim, 20), 50));
$$;

revoke all on function public.touch_presence() from public, anon;
revoke all on function public.go_offline() from public, anon;
revoke all on function public.friends_online() from public, anon;
revoke all on function public.suggested_friends(integer) from public, anon;
grant execute on function public.touch_presence() to authenticated;
grant execute on function public.go_offline() to authenticated;
grant execute on function public.friends_online() to authenticated;
grant execute on function public.suggested_friends(integer) to authenticated;
