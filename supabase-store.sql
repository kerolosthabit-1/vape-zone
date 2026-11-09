-- ============================================================
--  Vape Zone Store — المتجر الإلكتروني والطلبات
--  نفّذ الملف ده مرة واحدة في Supabase -> SQL Editor -> Run
--  بعد ما تكون نفّذت supabase-setup.sql
-- ============================================================

-- ------------------------------------------------------------
-- 1) روابط المتاجر: slug فريد لكل محل
-- ------------------------------------------------------------
create table if not exists public.store_slugs (
  slug       text primary key,
  shop_id    text not null unique,
  updated_at timestamptz not null default now()
);

alter table public.store_slugs drop constraint if exists store_slug_format;
alter table public.store_slugs
  add constraint store_slug_format
  check (slug ~ '^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$');

alter table public.store_slugs enable row level security;

drop policy if exists store_slugs_select on public.store_slugs;
create policy store_slugs_select on public.store_slugs
  for select to authenticated using (shop_id = auth.uid()::text);

drop policy if exists store_slugs_insert on public.store_slugs;
create policy store_slugs_insert on public.store_slugs
  for insert to authenticated with check (shop_id = auth.uid()::text);

drop policy if exists store_slugs_update on public.store_slugs;
create policy store_slugs_update on public.store_slugs
  for update to authenticated
  using (shop_id = auth.uid()::text)
  with check (shop_id = auth.uid()::text);

drop policy if exists store_slugs_delete on public.store_slugs;
create policy store_slugs_delete on public.store_slugs
  for delete to authenticated using (shop_id = auth.uid()::text);

grant select, insert, update, delete on public.store_slugs to authenticated;

-- ------------------------------------------------------------
-- 2) جدول الطلبات
-- ------------------------------------------------------------
create table if not exists public.orders (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,
  shop_id       text not null,
  customer      jsonb not null default '{}'::jsonb,
  fulfillment   text not null default 'delivery' check (fulfillment in ('delivery', 'pickup')),
  payment       text not null default 'cod',
  items         jsonb not null default '[]'::jsonb,
  subtotal      numeric(12,2) not null default 0,
  delivery_fee  numeric(12,2) not null default 0,
  total         numeric(12,2) not null default 0,
  status        text not null default 'new' check (status in ('new', 'confirmed', 'done', 'rejected', 'cancelled')),
  note          text not null default '',
  reject_reason text not null default '',
  sale_id       text not null default '',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists orders_shop_created_idx on public.orders (shop_id, created_at desc);
create index if not exists orders_shop_status_idx  on public.orders (shop_id, status);

alter table public.orders enable row level security;

drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders
  for select to authenticated using (shop_id = auth.uid()::text);

drop policy if exists orders_update on public.orders;
create policy orders_update on public.orders
  for update to authenticated
  using (shop_id = auth.uid()::text)
  with check (shop_id = auth.uid()::text);

-- مفيش سياسة insert/delete: إنشاء الطلبات بيتم من دالة store_place_order فقط
revoke insert, update, delete on public.orders from anon;
revoke insert, delete on public.orders from authenticated;
grant select, update on public.orders to authenticated;

-- ------------------------------------------------------------
-- 3) تحديث updated_at تلقائيًا
-- ------------------------------------------------------------
create or replace function public.touch_orders()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists orders_touch on public.orders;
create trigger orders_touch before update on public.orders
  for each row execute function public.touch_orders();

-- ------------------------------------------------------------
-- 4) تفعيل المزامنة اللحظية (Realtime) للطلبات
-- ------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'orders'
  ) then
    alter publication supabase_realtime add table public.orders;
  end if;
end $$;

alter table public.orders replica identity full;

-- ------------------------------------------------------------
-- 5) البحث عن المتجر بالـ slug (دالة داخلية)
-- ------------------------------------------------------------
create or replace function public.store_lookup(p_slug text)
returns table (shop_id text, data jsonb)
language sql
security definer
set search_path = public
as $$
  select s.id as shop_id, s.data
  from public.store_slugs sl
  join public.shops s on s.id = sl.shop_id
  where sl.slug = lower(trim(p_slug))

  union all

  select s.id as shop_id, s.data
  from public.shops s
  where lower(coalesce(s.data -> 'settings' -> 'store' ->> 'slug', '')) = lower(trim(p_slug))
    and not exists (
      select 1 from public.store_slugs sl2
      where sl2.slug = lower(trim(p_slug))
    )

  limit 1;
$$;

revoke all on function public.store_lookup(text) from public;
revoke all on function public.store_lookup(text) from anon;
revoke all on function public.store_lookup(text) from authenticated;

-- ------------------------------------------------------------
-- 6) كتالوج المتجر للعميل (بدون أي بيانات تكلفة)
-- ------------------------------------------------------------
create or replace function public.store_catalog(p_slug text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  st       record;
  cfg      jsonb;
  reserved jsonb := '{}'::jsonb;
  prods    jsonb;
begin
  select * into st from public.store_lookup(p_slug) limit 1;

  if st.shop_id is null then
    return jsonb_build_object('ok', false, 'error', 'store_not_found');
  end if;

  cfg := coalesce(st.data -> 'settings' -> 'store', '{}'::jsonb);

  -- الكميات المحجوزة في الطلبات الجارية (جديد + مقبول)
  select coalesce(jsonb_object_agg(x.pid, x.qty), '{}'::jsonb)
    into reserved
  from (
    select it ->> 'id' as pid,
           sum(greatest(0, coalesce((it ->> 'qty')::int, 0))) as qty
    from public.orders o
    cross join lateral jsonb_array_elements(
      case when jsonb_typeof(o.items) = 'array' then o.items else '[]'::jsonb end
    ) it
    where o.shop_id = st.shop_id
      and o.status in ('new', 'confirmed')
      and it ->> 'id' is not null
    group by 1
  ) x;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id',       p ->> 'id',
      'name',     coalesce(p ->> 'name', ''),
      'category', coalesce(nullif(p ->> 'category', ''), 'أخرى'),
      'price',    coalesce(nullif(p ->> 'storePrice', '')::numeric, nullif(p ->> 'price', '')::numeric, 0),
      'oldPrice', case
                    when nullif(p ->> 'storePrice', '') is not null
                     and (p ->> 'storePrice')::numeric < coalesce(nullif(p ->> 'price', '')::numeric, 0)
                    then (p ->> 'price')::numeric
                    else null
                  end,
      'desc',     coalesce(p ->> 'desc', ''),
      'img',      coalesce(p ->> 'img', ''),
      'qty',      greatest(0,
                    coalesce(nullif(p ->> 'qty', '')::int, 0)
                    - coalesce((reserved ->> (p ->> 'id'))::int, 0)
                  ),
      'min',      coalesce(nullif(p ->> 'min', '')::int, 0)
    ) order by coalesce(nullif(p ->> 'category', ''), 'أخرى'), coalesce(p ->> 'name', '')), '[]'::jsonb)
    into prods
  from jsonb_array_elements(
    case when jsonb_typeof(st.data -> 'products') = 'array' then st.data -> 'products' else '[]'::jsonb end
  ) p
  where coalesce(p ->> 'hidden', 'false') not in ('true', '1');

  return jsonb_build_object(
    'ok', true,
    'store', jsonb_build_object(
      'slug',         coalesce(nullif(cfg ->> 'slug', ''), lower(trim(p_slug))),
      'name',         coalesce(nullif(cfg ->> 'name', ''), nullif(st.data -> 'settings' ->> 'shopName', ''), 'Vape Zone Store'),
      'active',       coalesce(cfg ->> 'active', 'true') <> 'false',
      'phone',        coalesce(cfg ->> 'phone', ''),
      'whatsapp',     coalesce(cfg ->> 'whatsapp', ''),
      'address',      coalesce(cfg ->> 'address', ''),
      'hours',        coalesce(cfg ->> 'hours', ''),
      'announcement', coalesce(cfg ->> 'announcement', ''),
      'deliveryFee',  coalesce(nullif(cfg ->> 'deliveryFee', '')::numeric, 0),
      'minOrder',     coalesce(nullif(cfg ->> 'minOrder', '')::numeric, 0),
      'deliveryNote', coalesce(cfg ->> 'deliveryNote', ''),
      'pickupNote',   coalesce(cfg ->> 'pickupNote', ''),
      'payments',     case
                        when jsonb_typeof(cfg -> 'payments') = 'array' then cfg -> 'payments'
                        else '["cod"]'::jsonb
                      end
    ),
    'products', prods
  );
end $$;

grant execute on function public.store_catalog(text) to anon, authenticated;

-- ------------------------------------------------------------
-- 7) إنشاء طلب جديد (الأسعار والمخزون بتتحقق من السيرفر)
-- ------------------------------------------------------------
create or replace function public.store_place_order(
  p_slug         text,
  p_customer     jsonb,
  p_items        jsonb,
  p_fulfillment  text default 'delivery',
  p_payment      text default 'cod',
  p_note         text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  st          record;
  cfg         jsonb;
  v_name      text;
  v_phone     text;
  v_address   text;
  v_area      text;
  v_fulfill   text;
  v_payment   text;
  v_item      record;
  v_prod      jsonb;
  v_price     numeric;
  v_qty       int;
  v_reserved  int;
  v_avail     int;
  v_subtotal  numeric := 0;
  v_delivery  numeric := 0;
  v_total     numeric;
  v_min       numeric := 0;
  v_code      text;
  v_id        uuid;
  v_lines     jsonb := '[]'::jsonb;
  v_attempt   int := 0;
begin
  select * into st from public.store_lookup(p_slug) limit 1;

  if st.shop_id is null then
    return jsonb_build_object('ok', false, 'error', 'store_not_found');
  end if;

  cfg := coalesce(st.data -> 'settings' -> 'store', '{}'::jsonb);

  -- قفل لكل محل: يمنع بيع آخر قطعة مرتين لو عميلين طلبوا في نفس اللحظة
  perform pg_advisory_xact_lock(hashtext(st.shop_id));

  if coalesce(cfg ->> 'active', 'true') = 'false' then
    return jsonb_build_object('ok', false, 'error', 'store_closed');
  end if;

  if p_customer is null or jsonb_typeof(p_customer) <> 'object' then
    return jsonb_build_object('ok', false, 'error', 'customer');
  end if;

  v_name    := trim(coalesce(p_customer ->> 'name', ''));
  v_phone   := regexp_replace(coalesce(p_customer ->> 'phone', ''), '[^0-9]', '', 'g');
  v_address := trim(coalesce(p_customer ->> 'address', ''));
  v_area    := trim(coalesce(p_customer ->> 'area', ''));

  v_fulfill := case when p_fulfillment = 'pickup' then 'pickup' else 'delivery' end;
  v_payment := case when p_payment in ('cod', 'instapay', 'wallet') then p_payment else 'cod' end;

  if length(v_name) < 2 then
    return jsonb_build_object('ok', false, 'error', 'name');
  end if;
  if length(v_phone) < 10 or length(v_phone) > 15 then
    return jsonb_build_object('ok', false, 'error', 'phone');
  end if;
  if v_fulfill = 'delivery' and length(v_address) < 5 then
    return jsonb_build_object('ok', false, 'error', 'address');
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'empty');
  end if;
  if jsonb_array_length(p_items) = 0 then
    return jsonb_build_object('ok', false, 'error', 'empty');
  end if;
  if jsonb_array_length(p_items) > 50 then
    return jsonb_build_object('ok', false, 'error', 'too_many');
  end if;

  -- منع spam: 5 طلبات كحد أقصى من نفس الرقم في 10 دقائق
  if (
    select count(*) from public.orders o
    where o.shop_id = st.shop_id
      and regexp_replace(coalesce(o.customer ->> 'phone', ''), '[^0-9]', '', 'g') = v_phone
      and o.created_at > now() - interval '10 minutes'
  ) >= 5 then
    return jsonb_build_object('ok', false, 'error', 'rate_limit');
  end if;

  for v_item in
    select x.id, sum(greatest(1, coalesce(x.qty, 1)))::int as qty
    from jsonb_to_recordset(p_items) as x(id text, qty int)
    group by x.id
  loop
    v_qty := v_item.qty;

    if v_qty > 99 then
      return jsonb_build_object('ok', false, 'error', 'too_many');
    end if;

    select p into v_prod
    from jsonb_array_elements(
      case when jsonb_typeof(st.data -> 'products') = 'array' then st.data -> 'products' else '[]'::jsonb end
    ) p
    where p ->> 'id' = v_item.id
    limit 1;

    if v_prod is null then
      return jsonb_build_object('ok', false, 'error', 'item_missing', 'item', v_item.id);
    end if;

    if coalesce(v_prod ->> 'hidden', 'false') in ('true', '1') then
      return jsonb_build_object('ok', false, 'error', 'item_hidden', 'item', coalesce(v_prod ->> 'name', ''));
    end if;

    select coalesce(sum(greatest(0, coalesce((it ->> 'qty')::int, 0))), 0)::int
      into v_reserved
    from public.orders o
    cross join lateral jsonb_array_elements(
      case when jsonb_typeof(o.items) = 'array' then o.items else '[]'::jsonb end
    ) it
    where o.shop_id = st.shop_id
      and o.status in ('new', 'confirmed')
      and it ->> 'id' = v_item.id;

    v_avail := greatest(0, coalesce(nullif(v_prod ->> 'qty', '')::int, 0) - v_reserved);

    if v_qty > v_avail then
      return jsonb_build_object(
        'ok', false,
        'error', 'out_of_stock',
        'item', coalesce(v_prod ->> 'name', v_item.id),
        'available', v_avail
      );
    end if;

    v_price := coalesce(nullif(v_prod ->> 'storePrice', '')::numeric, nullif(v_prod ->> 'price', '')::numeric, 0);
    v_subtotal := v_subtotal + (v_price * v_qty);

    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'id',       v_prod ->> 'id',
      'name',     coalesce(v_prod ->> 'name', ''),
      'price',    v_price,
      'qty',      v_qty,
      'subtotal', v_price * v_qty
    ));
  end loop;

  v_min := coalesce(nullif(cfg ->> 'minOrder', '')::numeric, 0);
  if v_min > 0 and v_subtotal < v_min then
    return jsonb_build_object('ok', false, 'error', 'min_order', 'min', v_min);
  end if;

  v_delivery := case
                  when v_fulfill = 'pickup' then 0
                  else coalesce(nullif(cfg ->> 'deliveryFee', '')::numeric, 0)
                end;
  v_total := v_subtotal + v_delivery;

  loop
    v_attempt := v_attempt + 1;
    v_code := 'VZ-' || upper(substr(md5(random()::text || clock_timestamp()::text || v_attempt::text), 1, 6));
    exit when not exists (select 1 from public.orders o where o.code = v_code);
    exit when v_attempt >= 12;
  end loop;

  insert into public.orders (
    code, shop_id, customer, fulfillment, payment, items,
    subtotal, delivery_fee, total, status, note
  ) values (
    v_code, st.shop_id,
    jsonb_build_object(
      'name', v_name,
      'phone', v_phone,
      'address', v_address,
      'area', v_area
    ),
    v_fulfill, v_payment, v_lines,
    v_subtotal, v_delivery, v_total, 'new',
    left(coalesce(p_note, ''), 500)
  )
  returning id into v_id;

  return jsonb_build_object(
    'ok', true,
    'id', v_id,
    'code', v_code,
    'subtotal', v_subtotal,
    'deliveryFee', v_delivery,
    'total', v_total
  );

exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'busy');
  when invalid_text_representation or numeric_value_out_of_range or invalid_parameter_value then
    return jsonb_build_object('ok', false, 'error', 'bad_items');
end $$;

grant execute on function public.store_place_order(text, jsonb, jsonb, text, text, text) to anon, authenticated;

-- ------------------------------------------------------------
-- 8) تتبع الأوردر بكود + رقم الموبايل
-- ------------------------------------------------------------
create or replace function public.store_track_order(p_code text, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  o       record;
  v_phone text;
begin
  v_phone := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');

  select * into o
  from public.orders
  where upper(code) = upper(trim(coalesce(p_code, '')))
    and regexp_replace(coalesce(customer ->> 'phone', ''), '[^0-9]', '', 'g') = v_phone
  limit 1;

  if o.id is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return jsonb_build_object(
    'ok', true,
    'order', jsonb_build_object(
      'code', o.code,
      'status', o.status,
      'fulfillment', o.fulfillment,
      'payment', o.payment,
      'items', o.items,
      'subtotal', o.subtotal,
      'deliveryFee', o.delivery_fee,
      'total', o.total,
      'note', o.note,
      'rejectReason', o.reject_reason,
      'createdAt', o.created_at
    )
  );
end $$;

grant execute on function public.store_track_order(text, text) to anon, authenticated;

-- ------------------------------------------------------------
-- 9) إلغاء الأوردر من العميل (وهو لسه جديد فقط)
-- ------------------------------------------------------------
create or replace function public.store_cancel_order(p_code text, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  o       record;
  v_phone text;
begin
  v_phone := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');

  update public.orders
     set status = 'cancelled'
   where upper(code) = upper(trim(coalesce(p_code, '')))
     and regexp_replace(coalesce(customer ->> 'phone', ''), '[^0-9]', '', 'g') = v_phone
     and status = 'new'
  returning * into o;

  if o.id is null then
    return jsonb_build_object('ok', false, 'error', 'cannot_cancel');
  end if;

  return jsonb_build_object('ok', true, 'code', o.code);
end $$;

grant execute on function public.store_cancel_order(text, text) to anon, authenticated;

-- تحديث كاش الـ API بعد إنشاء الجداول والدوال
notify pgrst, 'reload schema';

-- ============================================================
--  خلاصة: العملاء بيقروا الكتالوج ويعملوا طلبات من غير تسجيل دخول،
--  وأنت بس اللي بتشوف وتدير الطلبات من حسابك.
-- ============================================================
