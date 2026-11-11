-- 008: продажа собственных анонимных номеров.
-- Запуск: Supabase SQL Editor → вставить целиком → Run. Можно запускать повторно (всё идемпотентно).

-- флаг «выставлен на продажу» + признак «куплен за GR» (продавать можно только купленные)
alter table public.phone_numbers add column if not exists listed boolean not null default false;
alter table public.phone_numbers add column if not exists purchased boolean not null default false;

-- номера, которые уже у владельцев, считаем купленными (иначе продать их было бы нельзя)
update public.phone_numbers set purchased = true where owner is not null and not purchased;

-- выставить свой номер на продажу
drop function if exists public.number_sell(bigint, bigint);
drop function if exists public.number_sell(text, bigint);
create or replace function public.number_sell(p_id bigint, p_price bigint)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if auth.uid() is null then raise exception 'Требуется вход'; end if;
  if p_price is null or p_price < 1 or p_price > 10000000 then raise exception 'Цена: от 1 до 10 000 000 GR'; end if;
  select * into r from public.phone_numbers where id = p_id for update;
  if not found then raise exception 'Номер не найден'; end if;
  if r.archived then raise exception 'Номер в архиве'; end if;
  if r.owner is distinct from auth.uid() then raise exception 'Это не ваш номер'; end if;
  if not r.purchased then raise exception 'Продавать можно только купленные номера'; end if;
  update public.phone_numbers set listed = true, price = p_price where id = p_id;
end $$;

-- снять свой номер с продажи
drop function if exists public.number_unlist(bigint);
drop function if exists public.number_unlist(text);
create or replace function public.number_unlist(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if auth.uid() is null then raise exception 'Требуется вход'; end if;
  select * into r from public.phone_numbers where id = p_id for update;
  if not found then raise exception 'Номер не найден'; end if;
  if r.owner is distinct from auth.uid() then raise exception 'Это не ваш номер'; end if;
  update public.phone_numbers set listed = false where id = p_id;
end $$;

-- покупка номера: работает и для лотов админа (без владельца), и для лотов пользователей (listed)
-- продавец получает полную стоимость на баланс GR
drop function if exists public.market_buy_number(bigint);
drop function if exists public.market_buy_number(integer);
drop function if exists public.market_buy_number(numeric);
drop function if exists public.market_buy_number(uuid);
drop function if exists public.market_buy_number(text);
create or replace function public.market_buy_number(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare n record;
begin
  if auth.uid() is null then raise exception 'Требуется вход'; end if;
  select * into n from public.phone_numbers where id = p_id for update;
  if not found then raise exception 'Номер не найден'; end if;
  if n.archived then raise exception 'Номер в архиве'; end if;
  if n.owner is not null and not n.listed then raise exception 'Номер не продаётся'; end if;
  if n.owner = auth.uid() then raise exception 'Это уже ваш номер'; end if;
  if n.price is null or n.price < 1 then raise exception 'Номер не продаётся'; end if;
  update public.profiles set gr = gr - n.price where id = auth.uid() and gr >= n.price;
  if not found then raise exception 'Не хватает GR'; end if;
  if n.owner is not null then
    update public.profiles set gr = gr + n.price where id = n.owner;
  end if;
  update public.phone_numbers set owner = auth.uid(), listed = false, purchased = true where id = p_id;
end $$;
