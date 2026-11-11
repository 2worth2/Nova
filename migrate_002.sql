-- Nova, миграция 002: подарки (как в Telegram: обычный подарок -> улучшение в коллекционный
-- со случайными атрибутами (модель/фон/символ), номером тиража, редкостью и вторичным рынком).
-- Запустите целиком в Supabase -> SQL Editor -> Run. Можно запускать повторно (безопасно).

-- ============ каталог ============
create table if not exists public.gift_types (
  slug text primary key,
  name text not null,
  price bigint not null check (price between 1 and 10000000),
  supply int not null check (supply > 0),
  issued int not null default 0,
  sort int not null default 0
);

-- пул атрибутов с весами выпадения (kind: model | backdrop | symbol)
create table if not exists public.gift_attrs (
  type_slug text not null references public.gift_types(slug) on delete cascade,
  kind text not null check (kind in ('model', 'backdrop', 'symbol')),
  value text not null,
  weight int not null check (weight between 1 and 10000),
  primary key (type_slug, kind, value)
);

-- ============ экземпляры подарков ============
create table if not exists public.user_gifts (
  id bigint generated always as identity primary key,
  type text not null references public.gift_types(slug),
  owner uuid not null references public.profiles(id) on delete cascade,
  giver uuid references public.profiles(id) on delete set null,
  caption text check (caption is null or char_length(caption) <= 120),
  status text not null default 'regular' check (status in ('regular', 'collectible', 'listed')),
  model text, backdrop text, symbol text,
  model_pct numeric check (model_pct is null or model_pct between 0 and 100),
  backdrop_pct numeric check (backdrop_pct is null or backdrop_pct between 0 and 100),
  symbol_pct numeric check (symbol_pct is null or symbol_pct between 0 and 100),
  edition int,
  price bigint check (price is null or price between 1 and 10000000),
  opened_at timestamptz,
  created_at timestamptz not null default now(),
  upgraded_at timestamptz
);
create index if not exists user_gifts_owner on public.user_gifts (owner, id desc);
create index if not exists user_gifts_type on public.user_gifts (type, id desc);
create index if not exists user_gifts_listed on public.user_gifts (status) where status = 'listed';

-- подарок виден и в чате: тип сообщения
alter table public.messages add column if not exists kind text not null default 'text';
alter table public.messages add column if not exists gift_id bigint references public.user_gifts(id) on delete set null;

-- ============ RLS ============
alter table public.gift_types enable row level security;
alter table public.gift_attrs enable row level security;
alter table public.user_gifts enable row level security;

drop policy if exists "gift_types: читают все вошедшие" on public.gift_types;
drop policy if exists "gift_attrs: читают все вошедшие" on public.gift_attrs;
drop policy if exists "user_gifts: читают все вошедшие" on public.user_gifts;
create policy "gift_types: читают все вошедшие" on public.gift_types for select to authenticated using (true);
create policy "gift_attrs: читают все вошедшие" on public.gift_attrs for select to authenticated using (true);
-- витрина публичная: чужие подарки видно в профиле
create policy "user_gifts: читают все вошедшие" on public.user_gifts for select to authenticated using (true);
-- вставка/обновление/удаление — только через RPC ниже (security definer)

-- ============ честный roll атрибута по весам ============
create or replace function public.gift_roll_one(p_type text, p_kind text)
returns table (val text, pct numeric)
language plpgsql volatile security definer set search_path = public as $$
declare
  r float; total int; acc int; rw record;
begin
  select coalesce(sum(weight), 0) into total from public.gift_attrs
    where type_slug = p_type and kind = p_kind;
  if total is null or total = 0 then return; end if;
  r := random() * total; acc := 0;
  for rw in select ga.value as v, ga.weight as w from public.gift_attrs ga
    where ga.type_slug = p_type and ga.kind = p_kind order by ga.weight desc loop
    acc := acc + rw.w;
    if r <= acc then
      val := rw.v;
      pct := round(100.0 * rw.w / total, 2);
      return next;
      return;
    end if;
  end loop;
end $$;

-- ============ отправить подарок (за GR) ============
create or replace function public.gift_send(p_to uuid, p_type text, p_caption text default null)
returns bigint
language plpgsql security definer set search_path = public as $$
declare
  t record; gid bigint;
begin
  if p_caption is not null then p_caption := left(trim(p_caption), 120); if p_caption = '' then p_caption := null; end if; end if;
  select * into t from public.gift_types where slug = p_type;
  if not found then raise exception 'Подарок не найден'; end if;

  update public.profiles set gr = gr - t.price where id = auth.uid() and gr >= t.price;
  if not found then raise exception 'Недостаточно GR'; end if;

  if p_to is null then raise exception 'Получатель не выбран'; end if;
  insert into public.user_gifts (type, owner, giver, caption, status)
    values (p_type, p_to, auth.uid(), p_caption, 'regular') returning id into gid;
  if not found then
    update public.profiles set gr = gr + t.price where id = auth.uid();
    raise exception 'Получатель не выбран';
  end if;
  update public.gift_types set issued = issued + 1 where slug = p_type;

  -- подарок приходит сообщением в чат (как в Telegram)
  if p_to <> auth.uid() then
    insert into public.messages (sender, recipient, kind, gift_id, body)
      values (auth.uid(), p_to, 'gift', gid, '🎁 ' || t.name);
  end if;
  return gid;
end $$;

-- ============ открыть подарок в чате ============
create or replace function public.gift_open(p_gift bigint)
returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.user_gifts set opened_at = now()
    where id = p_gift and owner = auth.uid() and opened_at is null;
  if not found then raise exception 'Подарок не найден'; end if;
end $$;

-- ============ улучшение: roll модели, фона, символа + номер тиража ============
create or replace function public.gift_upgrade(p_gift bigint)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  g record; g2 record; m record; b record; s record; ed int;
begin
  select * into g from public.user_gifts where id = p_gift for update;
  if not found then raise exception 'Подарок не найден'; end if;
  if g.owner <> auth.uid() then raise exception 'Это не ваш подарок'; end if;
  if g.status <> 'regular' then raise exception 'Уже улучшен'; end if;

  select * into m from public.gift_roll_one(g.type, 'model');
  select * into b from public.gift_roll_one(g.type, 'backdrop');
  select * into s from public.gift_roll_one(g.type, 'symbol');

  ed := (select count(*) + 1 from public.user_gifts where type = g.type and status in ('collectible', 'listed'));

  update public.user_gifts set
    model = coalesce(m.val, 'Стандарт'), model_pct = m.pct,
    backdrop = coalesce(b.val, 'Полночь'), backdrop_pct = b.pct,
    symbol = coalesce(s.val, 'Звёзды'), symbol_pct = s.pct,
    edition = ed, status = 'collectible', upgraded_at = now()
  where id = p_gift;

  select * into g2 from public.user_gifts where id = p_gift;
  return to_jsonb(g2);
end $$;

-- ============ вторичный рынок ============
create or replace function public.gift_list(p_gift bigint, p_price bigint)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_price is null or p_price < 1 or p_price > 10000000 then raise exception 'Цена: целое число от 1 до 10 000 000'; end if;
  update public.user_gifts set price = p_price, status = 'listed'
    where id = p_gift and owner = auth.uid() and status = 'collectible';
  if not found then raise exception 'Можно выставлять только улучшенные подарки'; end if;
end $$;

create or replace function public.gift_unlist(p_gift bigint)
returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.user_gifts set price = null, status = 'collectible'
    where id = p_gift and owner = auth.uid() and status = 'listed';
  if not found then raise exception 'Лот не найден'; end if;
end $$;

create or replace function public.gift_buy(p_gift bigint)
returns void
language plpgsql security definer set search_path = public as $$
declare
  g record;
begin
  select * into g from public.user_gifts where id = p_gift for update;
  if not found then raise exception 'Лот не найден'; end if;
  if g.status <> 'listed' then raise exception 'Лот не продаётся'; end if;
  if g.owner = auth.uid() then raise exception 'Это ваш лот'; end if;
  update public.profiles set gr = gr - g.price where id = auth.uid() and gr >= g.price;
  if not found then raise exception 'Недостаточно GR'; end if;
  update public.profiles set gr = gr + g.price where id = g.owner;
  update public.user_gifts set owner = auth.uid(), price = null, status = 'collectible', opened_at = null where id = p_gift;
end $$;

-- ============ подарить подарок дальше ============
create or replace function public.gift_transfer(p_gift bigint, p_to uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare g record;
begin
  if p_to is null then raise exception 'Получатель не выбран'; end if;
  select * into g from public.user_gifts where id = p_gift for update;
  if not found then raise exception 'Подарок не найден'; end if;
  if g.owner <> auth.uid() then raise exception 'Это не ваш подарок'; end if;
  if g.status = 'listed' then raise exception 'Сначала снимите подарок с продажи'; end if;
  update public.user_gifts set owner = p_to, opened_at = null where id = p_gift;
  if p_to <> auth.uid() then
    insert into public.messages (sender, recipient, kind, gift_id, body)
      values (auth.uid(), p_to, 'gift', p_gift, '🎁 ' || (select name from public.gift_types where slug = g.type));
  end if;
end $$;

-- ============ каталог (idempotent сид) ============
do $$
declare
  i int; k int; t text;
  ts text[] := array['plasma_heart','cake','nova_star','rocket','teddy','gold_rose','comet','diamond','crown','cosmos_cube'];
  tn text[] := array['Плазменное сердце','Торт','Звезда Нова','Ракета','Мишка','Золотая роза','Комета','Бриллиант','Корона','Космический куб'];
  tp bigint[] := array[60,90,120,180,250,320,400,600,900,1500];
  tsup int[] := array[100000,100000,50000,50000,40000,30000,25000,20000,10000,5000];
  models text[][] := array[
    array['Стандарт','Пурпурный','Плазменный'],
    array['Стандарт','Ягодный','Золотой'],
    array['Стандарт','Лазурный','Золотой'],
    array['Стандарт','Нефритовый','Титановый'],
    array['Стандарт','Карамельный','Полярный'],
    array['Стандарт','Алый','Платиновый'],
    array['Стандарт','Аметистовый','Золотой'],
    array['Стандарт','Розовый','Радужный'],
    array['Стандарт','Рубиновый','Императорский'],
    array['Стандарт','Галактический','Аномальный']
  ];
  mw int[] := array[88,10,2];
  bds text[] := array['Полночь','Аква','Закат','Неон','Аметист','Золото'];
  bw int[] := array[40,25,18,10,5,2];
  sys text[] := array['Звёзды','Пузырьки','Сердца','Молнии','Кристаллы','Ракеты'];
  sw int[] := array[40,25,16,10,6,3];
begin
  for i in 1..10 loop
    insert into public.gift_types (slug, name, price, supply, sort)
      values (ts[i], tn[i], tp[i], tsup[i], i)
      on conflict (slug) do update set name = excluded.name, price = excluded.price, supply = excluded.supply, sort = excluded.sort;
    for k in 1..3 loop
      insert into public.gift_attrs (type_slug, kind, value, weight)
        values (ts[i], 'model', models[i][k], mw[k])
        on conflict (type_slug, kind, value) do update set weight = excluded.weight;
    end loop;
  end loop;
  for i in 1..6 loop
    for t in select slug from public.gift_types loop
      insert into public.gift_attrs (type_slug, kind, value, weight)
        values (t, 'backdrop', bds[i], bw[i])
        on conflict (type_slug, kind, value) do update set weight = excluded.weight;
      insert into public.gift_attrs (type_slug, kind, value, weight)
        values (t, 'symbol', sys[i], sw[i])
        on conflict (type_slug, kind, value) do update set weight = excluded.weight;
    end loop;
  end loop;
end $$;
