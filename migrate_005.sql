-- Nova, миграция 005: витрина профиля — закрепление и скрытие подарков.
-- Запустите целиком в Supabase -> SQL Editor -> Run. Можно запускать повторно (безопасно).

alter table public.user_gifts add column if not exists showcase_hidden boolean not null default false;
alter table public.user_gifts add column if not exists showcase_pinned boolean not null default false;

-- Переключение витрины: pin = закрепить/открепить, hide = скрыть/вернуть.
create or replace function public.gift_showcase(p_gift bigint, p_op text)
returns void
language plpgsql security definer set search_path = public as $$
declare g record; n int;
begin
  select * into g from public.user_gifts where id = p_gift for update;
  if not found then raise exception 'Подарок не найден'; end if;
  if g.owner <> auth.uid() then raise exception 'Это не ваш подарок'; end if;

  if p_op = 'pin' then
    if g.showcase_hidden then raise exception 'Сначала верните подарок в профиль'; end if;
    if not g.showcase_pinned then
      select count(*) into n from public.user_gifts where owner = auth.uid() and showcase_pinned;
      if n >= 9 then raise exception 'Максимум 9 закреплённых подарков'; end if;
    end if;
    update public.user_gifts set showcase_pinned = not showcase_pinned where id = p_gift;
  elsif p_op = 'hide' then
    update public.user_gifts set showcase_hidden = not showcase_hidden, showcase_pinned = false where id = p_gift;
  else
    raise exception 'Неизвестное действие';
  end if;
end $$;
