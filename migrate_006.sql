-- Nova, миграция 006.
-- 1) Номера NFT-подарков выдаются строго по порядку улучшений:
--    первый, кто улучшил подарок коллекции, получает №1, следующий — №2 и т.д.
--    Атрибуты (модель/фон/символ) и официальный рендер по-прежнему случайные
--    из реального пула коллекции — меняется только логика присвоения номера.
-- 2) Существующие улучшенные экземпляры перенумеровываются один раз по времени
--    улучшения: кто улучшил раньше — младший номер.
-- 3) Админ может добавлять анонимные номера с любым началом: +000, +666, +66,
--    +77, +777... (формат: +<1-4 цифры> и 8 цифр, например +666 6666 1337).

-- ============ 1) перенумерация уже выпущенных экземпляров ============
-- Порядковый номер = позиция по времени улучшения внутри своей коллекции.

with r as (
  select id, row_number() over (partition by type order by upgraded_at nulls last, id) as rn
  from public.user_gifts
  where status <> 'regular' and edition is not null
)
update public.user_gifts ug set edition = r.rn from r where ug.id = r.id;

-- ============ 2) gift_upgrade: порядковый номер тиража ============
-- Было: случайный номер из свободных в пуле.
-- Стало: атрибуты случайные из пула, но номер тиража — следующий свободный по порядку.

create or replace function public.gift_upgrade(p_gift bigint)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  g record; t record; pool jsonb; inst jsonb; n int;
  mp numeric; bp numeric; sp numeric; num int;
begin
  select * into g from public.user_gifts where id = p_gift for update;
  if not found then raise exception 'Подарок не найден'; end if;
  if g.owner <> auth.uid() then raise exception 'Это не ваш подарок'; end if;
  if g.status <> 'regular' then raise exception 'Уже улучшен'; end if;

  select * into t from public.gift_types where slug = g.type;
  if not found then raise exception 'Подарок не найден'; end if;
  pool := coalesce(t.pool, '[]'::jsonb);
  if coalesce(jsonb_array_length(pool), 0) = 0 then raise exception 'Пул коллекции пуст'; end if;

  -- атрибуты: случайный экземпляр реального пула коллекции [num, model, backdrop, symbol]
  n := floor(random() * jsonb_array_length(pool))::int;
  inst := pool -> n;

  -- номер тиража: следующий свободный ПО ПОРЯДКУ УЛУЧШЕНИЙ (первый улучшивший — №1).
  -- Блокируем строки этого типа, чтобы два одновременных улучшения не получили один номер.
  perform 1 from public.user_gifts where type = g.type order by id for update;
  select coalesce(max(edition), 0) + 1 into num
    from public.user_gifts where type = g.type and edition is not null;
  if num > t.supply then raise exception 'Тираж этой коллекции закончился'; end if;

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
    -- официальный рендер остаётся привязан к реальному номеру пула коллекции
    asset = 'gift/' || t.slug || '-' || coalesce(nullif(inst->>0, '')::int, num) || '.webp',
    status = 'collectible', upgraded_at = now()
  where id = p_gift;

  select * into g from public.user_gifts where id = p_gift;
  return to_jsonb(g);
end $$;

-- ============ 3) админ: анонимные номера с любым началом ============
-- Было: только +000. Теперь начальные цифры свободные: +666, +66, +77, +777 и т.д.
-- Заменяем старую функцию (перестраховка: снимаем возможные варианты сигнатуры).

drop function if exists public.admin_add_number(text, bigint);
drop function if exists public.admin_add_number(text, numeric);
drop function if exists public.admin_add_number(text, integer);

create function public.admin_add_number(p_num text, p_price bigint)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce((select is_admin from public.profiles where id = auth.uid()), false) is distinct from true then
    raise exception 'Только админ';
  end if;
  if p_num is null or p_num !~ '^\+\d{1,4} \d{4} \d{4}$' then
    raise exception 'Номер: +<начало> и 8 цифр, например +666 6666 1337';
  end if;
  if p_price is null or p_price < 1 or p_price > 10000000 then
    raise exception 'Цена: целое число от 1 до 10 000 000';
  end if;
  if exists (select 1 from public.phone_numbers where num = p_num) then
    raise exception 'Такой номер уже добавлен';
  end if;
  insert into public.phone_numbers (num, price, archived) values (p_num, p_price, false);
end $$;
