-- Videos (max 10 s) for pins, geo-capsules and stories.
-- The photo columns keep the first frame (poster), so maps, thumbnails and blurred previews
-- keep working; video_path points to the MP4 in the same storage folder (same policies).

alter table public.pins add column if not exists video_path text;
alter table public.geo_capsules add column if not exists video_path text;
alter table public.stories add column if not exists video_path text;

update storage.buckets
set file_size_limit = 31457280,
    allowed_mime_types = array['image/jpeg', 'video/mp4']
where id in ('pins', 'capsules', 'stories');
