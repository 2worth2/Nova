-- Nova, миграция 004: безопасность + фото и непрочитанные в личных чатах.
-- Запустите целиком в Supabase -> SQL Editor -> Run. Можно запускать повторно (безопасно).

-- ============ 1) защита привилегированных колонок profiles ============
-- БЫЛО: политика UPDATE разрешала любому клиенту менять свою строку как угодно —
-- включая самовольно выданные себе gr, is_admin, is_premium, is_verified, is_banned.
-- RLS не умеет ограничивать столбцы, поэтому ставим триггер BEFORE UPDATE:
-- он откатывает привилегированные поля к их прежним значениям.
-- Функция БЕЗ security definer: тогда current_user внутри триггера отражает роль,
-- от которой реально идёт UPDATE — 'authenticated' для клиента (поля защищены),
-- 'postgres'/'supabase_admin'/'service_role' — для security definer RPC
-- (админка, gift_*, начисления GR) и серверных сценариев — они не ограничиваются.

create or replace function public.profile_guard() returns trigger
language plpgsql set search_path = public as $$
declare po jsonb; pn jsonb; k text;
begin
  if current_user in ('postgres', 'supabase_admin', 'authenticator', 'service_role') then return new; end if;
  po := to_jsonb(old);
  pn := to_jsonb(new);
  foreach k in array array['gr', 'is_admin', 'is_premium', 'is_verified', 'is_banned'] loop
    if pn ? k and po ? k and (pn->k is distinct from po->k) then
      pn := jsonb_set(pn, array[k], po->k);
    end if;
  end loop;
  new := jsonb_populate_record(null::public.profiles, pn);
  return new;
end $$;

drop trigger if exists profile_guard on public.profiles;
create trigger profile_guard before update on public.profiles
  for each row execute function public.profile_guard();

-- ============ 2) gift_upgrade: без дублей тиража ============
-- Апгрейд берёт случайный экземпляр из pool (jsonb-массив [num, model, backdrop, symbol]),
-- но сначала исключает номера, уже занятые другими экземплярами того же типа.
-- Если ВСЕ номера коллекции разобраны — допускается повтор из полного пула
-- (supply ограничен, иначе апгрейд стал бы невозможен).

create or replace function public.gift_upgrade(p_gift bigint)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  g record; t record; pool jsonb; inst jsonb; n int;
  mp numeric; bp numeric; sp numeric; num int;
  taken int[];
begin
  select * into g from public.user_gifts where id = p_gift for update;
  if not found then raise exception 'Подарок не найден'; end if;
  if g.owner <> auth.uid() then raise exception 'Это не ваш подарок'; end if;
  if g.status <> 'regular' then raise exception 'Уже улучшен'; end if;

  select * into t from public.gift_types where slug = g.type;
  if not found then raise exception 'Подарок не найден'; end if;
  pool := coalesce(t.pool, '[]'::jsonb);
  if coalesce(jsonb_array_length(pool), 0) = 0 then raise exception 'Пул коллекции пуст'; end if;

  -- номера тиража, уже занятые другими экземплярами (pool: [num, model, backdrop, symbol])
  select coalesce(array_agg(edition), '{}') into taken
    from public.user_gifts where type = g.type and edition is not null;

  -- сначала выбираем только из свободных номеров
  pool := coalesce((
    select jsonb_agg(e) from jsonb_array_elements(pool) e
      where (e->>0) is not null and not ((e->>0)::int = any(taken))
  ), '[]'::jsonb);
  if coalesce(jsonb_array_length(pool), 0) = 0 then
    -- все номера заняты: берем случайный из полного пула (дубль допустим)
    select coalesce(jsonb_agg(e), '[]'::jsonb) into pool from jsonb_array_elements(t.pool) e;
  end if;
  if coalesce(jsonb_array_length(pool), 0) = 0 then raise exception 'Пул коллекции пуст'; end if;

  n := floor(random() * jsonb_array_length(pool))::int;
  inst := pool -> n;
  num := nullif(inst->>0, '')::int;

  select round(100.0 * ga.weight / s.total, 2) into mp
    from public.gift_attrs ga
    cross join (select sum(weight) as total from public.gift_attrs where type_slug = g.type and kind = 'model') s
    where ga.type_slug = g.type and ga.kind = 'model' and ga.value = inst->>1;
  select round(100.0 * ga.weight / s.total, 2) into bp
    from public.gift_attrs ga
    cross join (select sum(weight) as total from public.gift_attrs where type_slug = g.type and kind = 'backdrop') s
    where ga.type_slug = g.type and ga.kind = 'backdrop' and ga.value = inst->>2;
  select round(100.0 * ga.weight / s.total, 2) into sp
    from public.gift_attrs ga
    cross join (select sum(weight) as total from public.gift_attrs where type_slug = g.type and kind = 'symbol') s
    where ga.type_slug = g.type and ga.kind = 'symbol' and ga.value = inst->>3;

  update public.user_gifts set
    model = coalesce(inst->>1, 'Стандарт'), model_pct = coalesce(mp, 50),
    backdrop = coalesce(inst->>2, 'Полночь'), backdrop_pct = coalesce(bp, 50),
    symbol = coalesce(inst->>3, 'Звёзды'), symbol_pct = coalesce(sp, 50),
    edition = num,
    asset = 'gift/' || t.slug || '-' || num || '.webp',
    status = 'collectible', upgraded_at = now()
  where id = p_gift;

  select * into g from public.user_gifts where id = p_gift;
  return to_jsonb(g);
end $$;

-- ============ 3) удаление своих сообщений в личке ============
-- Раньше DELETE для messages был запрещён всем; теперь отправитель может
-- удалить своё сообщение (у получателя оно исчезнет по подписке realtime).

drop policy if exists "messages: удаляет отправитель" on public.messages;
create policy "messages: удаляет отправитель" on public.messages for delete to authenticated using (sender = auth.uid());

-- ============ 4) фото в личных сообщениях ============
alter table public.messages add column if not exists image_url text;

-- ============ 5) непрочитанные в личках ============
alter table public.messages add column if not exists read_at timestamptz;

-- отметить сообщения от собеседника прочитанными (вызывается клиентом при
-- открытии чата и при входящем сообщении в открытом чате)
create or replace function public.dm_mark_read(p_peer uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.messages set read_at = now()
    where recipient = auth.uid() and sender = p_peer and read_at is null;
end $$;

