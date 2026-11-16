-- Live Photo profile pictures (iPhone): the original still + paired video, stored next to the
-- regular JPEG avatar in the public avatars bucket. Other clients keep showing avatar_path.
alter table public.profiles
    add column if not exists avatar_live_photo text,
    add column if not exists avatar_live_video text;

alter table public.profiles
    drop constraint if exists profiles_avatar_live_paths;
alter table public.profiles
    add constraint profiles_avatar_live_paths check (
        (avatar_live_photo is null and avatar_live_video is null)
        or (avatar_live_photo like id::text || '/%' and avatar_live_video like id::text || '/%')
    );

update storage.buckets
    set file_size_limit = 15728640,
        allowed_mime_types = array['image/jpeg', 'image/heic', 'video/quicktime']
    where id = 'avatars';
