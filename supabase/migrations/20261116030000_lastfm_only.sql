-- Spotify is read only through Last.fm scrobbling: drop the direct Spotify link.
delete from public.music_config where key = 'spotify_client_id';
update public.music_links
   set spotify_refresh_token = null, spotify_access_token = null, spotify_expires_at = null, spotify_error = null;
delete from public.now_playing where provider = 'spotify';
revoke all on function public.link_spotify(text, text, integer) from authenticated;
