-- ─────────────────────────────────────────────────────────────────────────────
-- Now playing: what you and your friends are listening to.
--
-- Sources:
--   • Spotify  — linked in the app (OAuth PKCE); the server keeps the refresh token
--                and asks Spotify every 30 s, so it works with the app closed.
--   • Last.fm  — just a username; works for anything that scrobbles to Last.fm
--                (Spotify, Apple Music via a scrobbler, YouTube Music…), app closed too.
--   • Apple Music — reported by the iPhone app itself while it is open.
--
-- Keys live in public.music_config (no client access):
--   spotify_client_id, lastfm_api_key
-- ─────────────────────────────────────────────────────────────────────────────

create extension if not exists http with schema extensions;
create extension if not exists pg_cron;

create table if not exists public.music_config (
    key text primary key,
    value text not null
);
alter table public.music_config enable row level security;
revoke all on public.music_config from anon, authenticated;

create table if not exists public.music_links (
    user_id uuid primary key references auth.users (id) on delete cascade,
    spotify_refresh_token text,
    spotify_access_token text,
    spotify_expires_at timestamptz,
    spotify_error text,
    lastfm_username text check (lastfm_username is null or lastfm_username ~ '^[A-Za-z0-9_.-]{2,32}$'),
    updated_at timestamptz not null default now()
);
alter table public.music_links enable row level security;
revoke all on public.music_links from anon, authenticated;

create table if not exists public.now_playing (
    user_id uuid primary key references auth.users (id) on delete cascade,
    provider text not null check (provider in ('spotify', 'lastfm', 'apple')),
    track text not null check (char_length(track) between 1 and 300),
    artist text not null default '' check (char_length(artist) <= 300),
    album text not null default '' check (char_length(album) <= 300),
    artwork_url text check (artwork_url is null or artwork_url ~ '^https://'),
    track_url text check (track_url is null or track_url ~ '^https://'),
    is_playing boolean not null default true,
    updated_at timestamptz not null default now()
);
alter table public.now_playing enable row level security;
revoke insert, update, delete on public.now_playing from anon, authenticated;
grant select on public.now_playing to authenticated;

drop policy if exists now_playing_select on public.now_playing;
create policy now_playing_select on public.now_playing
    for select to authenticated
    using (user_id = auth.uid() or public.are_friends(auth.uid(), user_id));

-- ─────────────────────────────────────────────────────────────────────────────
-- Client RPCs
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.music_status()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
    select jsonb_build_object(
        'spotify_client_id', (select value from public.music_config where key = 'spotify_client_id'),
        'lastfm_available', exists (select 1 from public.music_config where key = 'lastfm_api_key'),
        'spotify_connected', coalesce((select l.spotify_refresh_token is not null from public.music_links l where l.user_id = auth.uid()), false),
        'spotify_error', (select l.spotify_error from public.music_links l where l.user_id = auth.uid()),
        'lastfm_username', (select l.lastfm_username from public.music_links l where l.user_id = auth.uid())
    );
$$;

create or replace function public.link_spotify(refresh_token text, access_token text, expires_in integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    if auth.uid() is null then
        raise exception 'not signed in';
    end if;
    insert into public.music_links (user_id, spotify_refresh_token, spotify_access_token, spotify_expires_at, spotify_error, updated_at)
    values (auth.uid(), refresh_token, access_token, now() + make_interval(secs => greatest(expires_in - 60, 0)), null, now())
    on conflict (user_id) do update
        set spotify_refresh_token = excluded.spotify_refresh_token,
            spotify_access_token = excluded.spotify_access_token,
            spotify_expires_at = excluded.spotify_expires_at,
            spotify_error = null,
            updated_at = now();
    perform public.poll_music_for(auth.uid());
end;
$$;

create or replace function public.link_lastfm(username text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    if auth.uid() is null then
        raise exception 'not signed in';
    end if;
    if username is null or username !~ '^[A-Za-z0-9_.-]{2,32}$' then
        raise exception 'invalid username';
    end if;
    insert into public.music_links (user_id, lastfm_username, updated_at)
    values (auth.uid(), username, now())
    on conflict (user_id) do update set lastfm_username = excluded.lastfm_username, updated_at = now();
    perform public.poll_music_for(auth.uid());
end;
$$;

create or replace function public.unlink_music(provider text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    if provider = 'spotify' then
        update public.music_links
           set spotify_refresh_token = null, spotify_access_token = null, spotify_expires_at = null, spotify_error = null, updated_at = now()
         where user_id = auth.uid();
    elsif provider = 'lastfm' then
        update public.music_links set lastfm_username = null, updated_at = now() where user_id = auth.uid();
    end if;
    delete from public.now_playing np where np.user_id = auth.uid() and np.provider = unlink_music.provider;
end;
$$;

-- Apple Music (iPhone, app open): the app reports the song it sees playing.
create or replace function public.report_now_playing(track text, artist text, album text, is_playing boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    current_row public.now_playing;
begin
    if auth.uid() is null then
        raise exception 'not signed in';
    end if;
    select * into current_row from public.now_playing where user_id = auth.uid();
    -- A song playing on Spotify / Last.fm in the last 2 minutes wins over Apple Music.
    if found and current_row.provider <> 'apple' and current_row.is_playing and current_row.updated_at > now() - interval '2 minutes' then
        return;
    end if;
    if track is null or btrim(track) = '' then
        update public.now_playing set is_playing = false where user_id = auth.uid() and provider = 'apple';
        return;
    end if;
    insert into public.now_playing (user_id, provider, track, artist, album, artwork_url, track_url, is_playing, updated_at)
    values (auth.uid(), 'apple', left(track, 300), left(coalesce(artist, ''), 300), left(coalesce(album, ''), 300), null, null, coalesce(is_playing, true), now())
    on conflict (user_id) do update
        set provider = 'apple', track = excluded.track, artist = excluded.artist, album = excluded.album,
            artwork_url = null, track_url = null, is_playing = excluded.is_playing, updated_at = now();
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Server polling (pg_cron, every 30 s)
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.store_now_playing(
    uid uuid, source text, p_track text, p_artist text, p_album text, p_artwork text, p_url text, p_playing boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    current_row public.now_playing;
begin
    select * into current_row from public.now_playing where user_id = uid;
    if p_track is null or btrim(p_track) = '' then
        -- Nothing playing on this source: mark it paused (keeps "last listened").
        update public.now_playing set is_playing = false where user_id = uid and provider = source and is_playing;
        return;
    end if;
    -- Do not overwrite a song playing right now from another source with a paused one.
    if found and current_row.provider <> source and current_row.is_playing and not p_playing
       and current_row.updated_at > now() - interval '2 minutes' then
        return;
    end if;
    if found and current_row.provider = source and current_row.track = left(p_track, 300)
       and current_row.artist = left(coalesce(p_artist, ''), 300) and current_row.is_playing = p_playing then
        update public.now_playing set updated_at = now() where user_id = uid;
        return;
    end if;
    insert into public.now_playing (user_id, provider, track, artist, album, artwork_url, track_url, is_playing, updated_at)
    values (
        uid, source, left(p_track, 300), left(coalesce(p_artist, ''), 300), left(coalesce(p_album, ''), 300),
        case when p_artwork ~ '^https://' then p_artwork end,
        case when p_url ~ '^https://' then p_url end,
        p_playing, now()
    )
    on conflict (user_id) do update
        set provider = excluded.provider, track = excluded.track, artist = excluded.artist, album = excluded.album,
            artwork_url = excluded.artwork_url, track_url = excluded.track_url, is_playing = excluded.is_playing, updated_at = now();
end;
$$;

create or replace function public.poll_music_for(uid uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    link public.music_links;
    client_id text := (select value from public.music_config where key = 'spotify_client_id');
    lastfm_key text := (select value from public.music_config where key = 'lastfm_api_key');
    response extensions.http_response;
    body jsonb;
    item jsonb;
    access text;
    track_json jsonb;
begin
    select * into link from public.music_links where user_id = uid;
    if not found then
        return;
    end if;
    perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '5000');

    -- Spotify
    if link.spotify_refresh_token is not null and client_id is not null then
        begin
            access := link.spotify_access_token;
            if access is null or link.spotify_expires_at is null or link.spotify_expires_at < now() + interval '30 seconds' then
                response := extensions.http_post(
                    'https://accounts.spotify.com/api/token',
                    'grant_type=refresh_token&refresh_token=' || extensions.urlencode(link.spotify_refresh_token)
                        || '&client_id=' || extensions.urlencode(client_id),
                    'application/x-www-form-urlencoded'
                );
                body := response.content::jsonb;
                if response.status <> 200 or body ->> 'access_token' is null then
                    update public.music_links
                       set spotify_error = coalesce(body ->> 'error', 'http ' || response.status),
                           -- A revoked or invalid token stops being retried.
                           spotify_refresh_token = case when body ->> 'error' = 'invalid_grant' then null else spotify_refresh_token end
                     where user_id = uid;
                    access := null;
                else
                    access := body ->> 'access_token';
                    update public.music_links
                       set spotify_access_token = access,
                           spotify_expires_at = now() + make_interval(secs => greatest(coalesce((body ->> 'expires_in')::int, 3600) - 60, 0)),
                           spotify_refresh_token = coalesce(body ->> 'refresh_token', spotify_refresh_token),
                           spotify_error = null
                     where user_id = uid;
                end if;
            end if;
            if access is not null then
                response := extensions.http((
                    'GET',
                    'https://api.spotify.com/v1/me/player/currently-playing?additional_types=episode',
                    array[extensions.http_header('Authorization', 'Bearer ' || access)],
                    null,
                    null
                )::extensions.http_request);
                if response.status = 200 and response.content is not null and response.content <> '' then
                    body := response.content::jsonb;
                    item := body -> 'item';
                    if item is not null and jsonb_typeof(item) = 'object' then
                        perform public.store_now_playing(
                            uid, 'spotify',
                            item ->> 'name',
                            coalesce(
                                (select string_agg(a ->> 'name', ', ') from jsonb_array_elements(coalesce(item -> 'artists', '[]'::jsonb)) a),
                                item -> 'show' ->> 'name', ''
                            ),
                            coalesce(item -> 'album' ->> 'name', ''),
                            coalesce(item -> 'album' -> 'images' -> 0 ->> 'url', item -> 'images' -> 0 ->> 'url'),
                            item -> 'external_urls' ->> 'spotify',
                            coalesce((body ->> 'is_playing')::boolean, false)
                        );
                    end if;
                elsif response.status = 204 then
                    perform public.store_now_playing(uid, 'spotify', null, null, null, null, null, false);
                elsif response.status = 401 then
                    update public.music_links set spotify_expires_at = null where user_id = uid;
                end if;
            end if;
        exception when others then
            update public.music_links set spotify_error = left(sqlerrm, 200) where user_id = uid;
        end;
    end if;

    -- Last.fm
    if link.lastfm_username is not null and lastfm_key is not null then
        begin
            response := extensions.http_get(
                'https://ws.audioscrobbler.com/2.0/?method=user.getrecenttracks&format=json&limit=1&user='
                    || extensions.urlencode(link.lastfm_username) || '&api_key=' || extensions.urlencode(lastfm_key)
            );
            if response.status = 200 then
                body := response.content::jsonb;
                track_json := body -> 'recenttracks' -> 'track';
                if jsonb_typeof(track_json) = 'array' then
                    track_json := track_json -> 0;
                end if;
                if track_json is not null and jsonb_typeof(track_json) = 'object' then
                    perform public.store_now_playing(
                        uid, 'lastfm',
                        track_json ->> 'name',
                        coalesce(track_json -> 'artist' ->> '#text', track_json -> 'artist' ->> 'name', ''),
                        coalesce(track_json -> 'album' ->> '#text', ''),
                        nullif(track_json -> 'image' -> 3 ->> '#text', ''),
                        track_json ->> 'url',
                        coalesce(track_json -> '@attr' ->> 'nowplaying', 'false') = 'true'
                    );
                end if;
            end if;
        exception when others then
            null;
        end;
    end if;
end;
$$;

create or replace function public.poll_now_playing()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    uid uuid;
begin
    for uid in
        select l.user_id from public.music_links l
        where l.spotify_refresh_token is not null or l.lastfm_username is not null
    loop
        perform public.poll_music_for(uid);
    end loop;
    -- Old paused songs are forgotten after a day.
    delete from public.now_playing where not is_playing and updated_at < now() - interval '1 day';
end;
$$;

revoke all on function public.poll_now_playing() from public, anon, authenticated;
revoke all on function public.poll_music_for(uuid) from public, anon, authenticated;
revoke all on function public.store_now_playing(uuid, text, text, text, text, text, text, boolean) from public, anon, authenticated;
revoke all on function public.music_status() from public, anon;
revoke all on function public.link_spotify(text, text, integer) from public, anon;
revoke all on function public.link_lastfm(text) from public, anon;
revoke all on function public.unlink_music(text) from public, anon;
revoke all on function public.report_now_playing(text, text, text, boolean) from public, anon;
grant execute on function public.music_status() to authenticated;
grant execute on function public.link_spotify(text, text, integer) to authenticated;
grant execute on function public.link_lastfm(text) to authenticated;
grant execute on function public.unlink_music(text) to authenticated;
grant execute on function public.report_now_playing(text, text, text, boolean) to authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'pindrop-now-playing';
select cron.schedule('pindrop-now-playing', '30 seconds', 'select public.poll_now_playing()');
