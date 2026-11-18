-- Chats like Instagram: seen receipts (chat_members.last_read_at, already readable by members),
-- voice messages, chat themes and "delete for everyone".

-- Voice messages: an m4a in the chat bucket, with its length and a small waveform (0-9 digits).
alter table public.chat_messages add column if not exists duration_ms integer;
alter table public.chat_messages add column if not exists waveform text;
alter table public.chat_messages drop constraint if exists chat_messages_duration_check;
alter table public.chat_messages add constraint chat_messages_duration_check check (duration_ms is null or (duration_ms >= 0 and duration_ms <= 600000));
alter table public.chat_messages drop constraint if exists chat_messages_waveform_check;
alter table public.chat_messages add constraint chat_messages_waveform_check check (waveform is null or char_length(waveform) <= 64);
alter table public.chat_messages drop constraint if exists chat_messages_kind_check;
alter table public.chat_messages add constraint chat_messages_kind_check
    check (kind = any (array['text', 'photo', 'pin_reply', 'story_reply', 'location', 'voice', 'theme']));

update storage.buckets
set allowed_mime_types = array['image/jpeg', 'audio/mp4', 'audio/m4a', 'audio/x-m4a', 'audio/aac'],
    file_size_limit = 10485760
where id = 'chat';

-- Your own uploads can be removed (when you delete a message for everyone).
drop policy if exists chat_objects_delete on storage.objects;
create policy chat_objects_delete on storage.objects for delete to authenticated
    using (bucket_id = 'chat' and owner_id = (select auth.uid())::text);

-- Chat themes.
alter table public.chat_threads add column if not exists theme text not null default 'default';
alter table public.chat_threads drop constraint if exists chat_threads_theme_check;
alter table public.chat_threads add constraint chat_threads_theme_check check (char_length(theme) between 1 and 24);

create or replace function public.set_chat_theme(thread uuid, theme text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    me uuid := auth.uid();
    clean text := left(btrim(coalesce(theme, 'default')), 24);
begin
    if me is null or not public.is_chat_member(thread, me) then raise exception 'not a member'; end if;
    if clean = '' then clean := 'default'; end if;
    update public.chat_threads set theme = clean where id = thread;
    insert into public.chat_messages (thread_id, sender_id, kind, body) values (thread, me, 'theme', clean);
end;
$$;
grant execute on function public.set_chat_theme(uuid, text) to authenticated;

-- A message deleted for everyone takes its pending notifications with it.
create or replace function public.chat_message_deleted()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    delete from public.push_events where kind = 'message' and ref_id = old.id;
    return old;
exception when others then
    return old;
end;
$$;
drop trigger if exists chat_message_deleted on public.chat_messages;
create trigger chat_message_deleted after delete on public.chat_messages
    for each row execute function public.chat_message_deleted();

-- Threads now carry their theme; the last message its voice details.
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
                'theme', t.theme,
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
                               msg.eta_minutes, msg.duration_ms, msg.waveform, msg.created_at
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
                      and msg.kind <> 'theme'
                )
            ) as row_data,
            coalesce((select max(msg.created_at) from public.chat_messages msg where msg.thread_id = t.id), t.created_at) as sort_at
        from public.chat_threads t
        join public.chat_members me on me.thread_id = t.id and me.user_id = auth.uid()
        where t.expires_at is null or t.expires_at > now()
    ) rows;
$$;
