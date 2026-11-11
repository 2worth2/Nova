-- Nova, миграция 007.
-- Анонимные номера теперь могут иметь любое начало: +000, +666, +66, +77, +777...
-- В таблице phone_numbers остался старый check-констрейнт (только +000) —
-- именно он давал ошибку "violates check constraint phone_numbers_num_check".
-- Заменяем его на свободный формат: +<1-4 цифры> <4 цифры> <4 цифры>.

alter table public.phone_numbers drop constraint if exists phone_numbers_num_check;

alter table public.phone_numbers add constraint phone_numbers_num_check
  check (num ~ '^\+\d{1,4} \d{4} \d{4}$');
