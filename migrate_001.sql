-- Nova, миграция 001: реакции и ответы.
-- Запустите целиком в Supabase -> SQL Editor -> Run. Можно запускать повторно (безопасно).

-- Ответы (цитирование): ссылка на исходное сообщение
alter table public.messages add column if not exists reply_to bigint references public.messages(id) on delete cascade;
alter table public.conv_posts add column if not exists reply_to bigint references public.conv_posts(id) on delete cascade;
create index if not exists messages_reply_to on public.messages (reply_to);
create index if not exists conv_posts_reply_to on public.conv_posts (reply_to);

-- Реакции: одна и та же реакция от пользователя на объект — один раз (unique)
create table if not exists public.reactions (
  id bigint generated always as identity primary key,
  target_kind text not null check (target_kind in ('message', 'conv_post')),
  target_id bigint not null,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  emoji text not null check (char_length(emoji) <= 10),
  created_at timestamptz not null default now(),
  unique (target_kind, target_id, user_id, emoji)
);
create index if not exists reactions_target on public.reactions (target_kind, target_id);

alter table public.reactions enable row level security;

drop policy if exists "reactions: читают все вошедшие" on public.reactions;
drop policy if exists "reactions: своя запись" on public.reactions;
drop policy if exists "reactions: удаление своей" on public.reactions;

create policy "reactions: читают все вошедшие" on public.reactions for select to authenticated using (true);
create policy "reactions: своя запись" on public.reactions for insert to authenticated with check (user_id = auth.uid());
create policy "reactions: удаление своей" on public.reactions for delete to authenticated using (user_id = auth.uid());
