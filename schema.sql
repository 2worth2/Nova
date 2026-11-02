-- Nova: схема базы данных. Вставьте целиком в Supabase -> SQL Editor -> Run.

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null check (username ~ '^[A-Za-z][A-Za-z0-9_]{2,31}$'),
  display_name text check (char_length(display_name) <= 40),
  created_at timestamptz not null default now()
);
create unique index profiles_username_lower on public.profiles (lower(username));

create table public.posts (
  id bigint generated always as identity primary key,
  author uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index posts_created on public.posts (created_at desc);

create table public.comments (
  id bigint generated always as identity primary key,
  post_id bigint not null references public.posts(id) on delete cascade,
  author uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index comments_post on public.comments (post_id, created_at);

create table public.messages (
  id bigint generated always as identity primary key,
  sender uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  recipient uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 4000),
  created_at timestamptz not null default now(),
  check (sender <> recipient)
);
create index messages_sender on public.messages (sender, created_at desc);
create index messages_recipient on public.messages (recipient, created_at desc);

-- профиль создаётся автоматически при регистрации
create function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, username) values (new.id, new.raw_user_meta_data->>'username');
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- права доступа (RLS): кто что может читать и писать
alter table public.profiles enable row level security;
alter table public.posts enable row level security;
alter table public.comments enable row level security;
alter table public.messages enable row level security;

create policy "profiles: читают все вошедшие" on public.profiles for select to authenticated using (true);
create policy "profiles: правит владелец" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy "posts: читают все вошедшие" on public.posts for select to authenticated using (true);
create policy "posts: пишет от своего имени" on public.posts for insert to authenticated with check (author = auth.uid());
create policy "posts: удаляет автор" on public.posts for delete to authenticated using (author = auth.uid());

create policy "comments: читают все вошедшие" on public.comments for select to authenticated using (true);
create policy "comments: пишет от своего имени" on public.comments for insert to authenticated with check (author = auth.uid());
create policy "comments: удаляет автор" on public.comments for delete to authenticated using (author = auth.uid());

create policy "messages: видят только участники" on public.messages for select to authenticated using (sender = auth.uid() or recipient = auth.uid());
create policy "messages: отправка от своего имени" on public.messages for insert to authenticated with check (sender = auth.uid());

-- мгновенная доставка новых записей
alter publication supabase_realtime add table public.posts, public.messages;
