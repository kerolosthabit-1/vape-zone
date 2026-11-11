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
  status        text not null default 'new',
  note          text not null default '',
  reject_reason text not null default '',
  sale_id       text not null default '',
  payment_ref   text not null default '',
  payment_proof text not null default '',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- ترقية قواعد البيانات القديمة (آمنة للتكرار)
alter table public.orders add column if not exists payment_ref   text not null default '';
alter table public.orders add column if not exists payment_proof text not null default '';

alter table public.orders drop constraint if exists orders_status_check;
alter table public.orders
  add constraint orders_status_check
  check (status in ('new', 'confirmed', 'ready', 'out_for_delivery', 'done', 'rejected', 'cancelled'));

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
-- 5ب) إلغاء الأوردرات القديمة اللي لسه «جديد» (تحرير المخزون المحجوز)
-- ------------------------------------------------------------
create or replace function public.store_expire_orders_internal(p_shop_id text, p_hours int)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_hours int;
  v_n     int := 0;
begin
  v_hours := greatest(0, least(720, coalesce(p_hours, 24)));
  if v_hours = 0 then
    return 0;
  end if;

  update public.orders
     set status = 'cancelled',
         reject_reason = coalesce(nullif(reject_reason, ''), 'إلغاء تلقائي — الأوردر اتأكدش خلال ' || v_hours || ' ساعة')
   where shop_id = p_shop_id
     and status = 'new'
     and created_at < now() - make_interval(hours => v_hours);
  get diagnostics v_n = row_count;
  return v_n;
end $$;

revoke all on function public.store_expire_orders_internal(text, int) from public;
revoke all on function public.store_expire_orders_internal(text, int) from anon;
revoke all on function public.store_expire_orders_internal(text, int) from authenticated;

-- نسخة عامة بالـ slug: بتنفّذ التنظيف حسب إعداد autoCancelHours بتاع المالك
create or replace function public.store_expire_orders(p_slug text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  st      record;
  v_hours int;
  v_n     int;
begin
  select * into st from public.store_lookup(p_slug) limit 1;
  if st.shop_id is null then
    return jsonb_build_object('ok', false, 'error', 'store_not_found');
  end if;

  v_hours := case
               when (st.data -> 'settings' -> 'store' ->> 'autoCancelHours') ~ '^[0-9]{1,3}$'
                 then least(720, (st.data -> 'settings' -> 'store' ->> 'autoCancelHours')::int)
               else 24
             end;
  v_n := public.store_expire_orders_internal(st.shop_id, v_hours);
  return jsonb_build_object('ok', true, 'cancelled', v_n, 'hours', v_hours);
end $$;

grant execute on function public.store_expire_orders(text) to anon, authenticated;

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
  st           record;
  cfg          jsonb;
  v_hours      int;
  reserved     jsonb := '{}'::jsonb;
  reserved_var jsonb := '{}'::jsonb;
  ratings      jsonb := '{}'::jsonb;
  prods        jsonb;
begin
  select * into st from public.store_lookup(p_slug) limit 1;

  if st.shop_id is null then
    return jsonb_build_object('ok', false, 'error', 'store_not_found');
  end if;

  cfg := coalesce(st.data -> 'settings' -> 'store', '{}'::jsonb);

  -- إلغاء تلقائي للأوردرات القديمة اللي لسه «جديد» (تحرير المخزون المحجوز)
  v_hours := case
               when (cfg ->> 'autoCancelHours') ~ '^[0-9]{1,3}$' then least(720, (cfg ->> 'autoCancelHours')::int)
               else 24
             end;
  perform public.store_expire_orders_internal(st.shop_id, v_hours);

  -- الكميات المحجوزة في الطلبات الجارية (جديد + مقبول + جاهز + خرج للتوصيل)
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
      and o.status in ('new', 'confirmed', 'ready', 'out_for_delivery')
      and it ->> 'id' is not null
    group by 1
  ) x;

  -- الكميات المحجوزة لكل قيمة خيار (طعم/لون) في الطلبات الجارية
  select coalesce(jsonb_object_agg(x.vk, x.qty), '{}'::jsonb)
    into reserved_var
  from (
    select (it ->> 'id') || '|' || g.key || '|' || g.value as vk,
           sum(greatest(0, coalesce((it ->> 'qty')::int, 0))) as qty
    from public.orders o
    cross join lateral jsonb_array_elements(
      case when jsonb_typeof(o.items) = 'array' then o.items else '[]'::jsonb end
    ) it
    cross join lateral jsonb_each_text(
      case when jsonb_typeof(it -> 'opts') = 'object' then it -> 'opts' else '{}'::jsonb end
    ) g
    where o.shop_id = st.shop_id
      and o.status in ('new', 'confirmed', 'ready', 'out_for_delivery')
      and it ->> 'id' is not null
    group by 1
  ) x;

  -- متوسط التقييمات الظاهرة لكل صنف
  select coalesce(jsonb_object_agg(x.pid, jsonb_build_object('avg', x.avg, 'count', x.cnt)), '{}'::jsonb)
    into ratings
  from (
    select r.product_id as pid,
           round(avg(r.rating)::numeric, 1) as avg,
           count(*)::int as cnt
    from public.store_reviews r
    where r.shop_id = st.shop_id
      and r.hidden = false
    group by r.product_id
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
      'opts',     (
                    select coalesce(jsonb_agg(
                      g || jsonb_build_object(
                        'stock',
                        coalesce((
                          select jsonb_object_agg(v, greatest(0,
                                   case when (g -> 'stock' ->> v) ~ '^[0-9]+$' then (g -> 'stock' ->> v)::int else 0 end
                                   - coalesce((reserved_var ->> ((p ->> 'id') || '|' || (g ->> 'name') || '|' || v))::int, 0)
                                 ))
                          from jsonb_array_elements_text(
                                 case when jsonb_typeof(g -> 'values') = 'array' then g -> 'values' else '[]'::jsonb end
                               ) v
                          where jsonb_typeof(g -> 'stock') = 'object'
                            and (g -> 'stock') ? v
                        ), '{}'::jsonb)
                      )
                    ), '[]'::jsonb)
                    from jsonb_array_elements(
                      case when jsonb_typeof(p -> 'opts') = 'array' then p -> 'opts' else '[]'::jsonb end
                    ) g
                  ),
      'img',      coalesce(p ->> 'img', ''),
      'qty',      greatest(0,
                    coalesce(nullif(p ->> 'qty', '')::int, 0)
                    - coalesce((reserved ->> (p ->> 'id'))::int, 0)
                  ),
      'min',      coalesce(nullif(p ->> 'min', '')::int, 0),
      'rating',   coalesce((ratings -> (p ->> 'id') ->> 'avg')::numeric, 0),
      'reviews',  coalesce((ratings -> (p ->> 'id') ->> 'count')::int, 0)
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
      'freeOver',     coalesce(nullif(cfg ->> 'freeOver', '')::numeric, 0),
      'zones',        case
                        when jsonb_typeof(cfg -> 'zones') = 'array' then cfg -> 'zones'
                        else '[]'::jsonb
                      end,
      'deliveryNote', coalesce(cfg ->> 'deliveryNote', ''),
      'pickupNote',   coalesce(cfg ->> 'pickupNote', ''),
      'paymentInfo',  coalesce(cfg ->> 'paymentInfo', ''),
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
  v_zone      text;
  v_zones     jsonb;
  v_zone_fee  numeric;
  v_zone_n    int := 0;
  v_free      numeric := 0;
  v_pay_ref   text;
  v_pay_proof text;
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
  v_variant   text;
  v_opts      jsonb;
  v_group     jsonb;
  v_gname     text;
  v_gvals     jsonb;
  v_optval    text;
  v_hours     int;
  v_cap       int;
  v_var_res   int;
  v_attempt   int := 0;
begin
  select * into st from public.store_lookup(p_slug) limit 1;

  if st.shop_id is null then
    return jsonb_build_object('ok', false, 'error', 'store_not_found');
  end if;

  cfg := coalesce(st.data -> 'settings' -> 'store', '{}'::jsonb);

  -- قفل لكل محل: يمنع بيع آخر قطعة مرتين لو عميلين طلبوا في نفس اللحظة
  perform pg_advisory_xact_lock(hashtext(st.shop_id));

  -- إلغاء تلقائي للأوردرات القديمة اللي لسه «جديد» (تحرير المخزون المحجوز)
  v_hours := case
               when (cfg ->> 'autoCancelHours') ~ '^[0-9]{1,3}$' then least(720, (cfg ->> 'autoCancelHours')::int)
               else 24
             end;
  perform public.store_expire_orders_internal(st.shop_id, v_hours);

  if coalesce(cfg ->> 'active', 'true') = 'false' then
    return jsonb_build_object('ok', false, 'error', 'store_closed');
  end if;

  if p_customer is null or jsonb_typeof(p_customer) <> 'object' then
    return jsonb_build_object('ok', false, 'error', 'customer');
  end if;

  v_name    := trim(coalesce(p_customer ->> 'name', ''));
  v_phone   := regexp_replace(coalesce(p_customer ->> 'phone', ''), '[^0-9]', '', 'g');
  v_address := trim(coalesce(p_customer ->> 'address', ''));
  v_zone    := trim(coalesce(p_customer ->> 'zone', p_customer ->> 'area', ''));
  v_area    := v_zone;
  v_pay_ref   := left(trim(coalesce(p_customer ->> 'paymentRef', '')), 60);
  v_pay_proof := left(coalesce(p_customer ->> 'paymentProof', ''), 1500000);
  -- نقبل صور التحويل فقط (data URL) لمنع أي روابط خارجية
  if v_pay_proof !~* '^data:image/(png|jpe?g|webp);base64,' then
    v_pay_proof := '';
  end if;

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

  -- 1) التحقق من المتاح لكل صنف (مجموع الكميات مهما اختلفت الأطعمه/الألوان)
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
      and o.status in ('new', 'confirmed', 'ready', 'out_for_delivery')
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
  end loop;

  -- 2) بناء سطور الأوردر مع الخيارات (طعم/لون/مقاس) وحساب الإجمالي
  for v_item in
    select x.id, x.opts, sum(greatest(1, coalesce(x.qty, 1)))::int as qty
    from jsonb_to_recordset(p_items) as x(id text, qty int, opts jsonb)
    group by x.id, x.opts
  loop
    v_qty := v_item.qty;

    select p into v_prod
    from jsonb_array_elements(
      case when jsonb_typeof(st.data -> 'products') = 'array' then st.data -> 'products' else '[]'::jsonb end
    ) p
    where p ->> 'id' = v_item.id
    limit 1;

    v_opts := case
                when jsonb_typeof(v_prod -> 'opts') = 'array' then v_prod -> 'opts'
                else '[]'::jsonb
              end;
    v_variant := '';

    -- لو الصنف ليه أطعمه/ألوان، لازم العميل يختار قيمة متاحة من كل خيار
    if jsonb_array_length(v_opts) > 0 then
      for v_group in select g from jsonb_array_elements(v_opts) g
      loop
        v_gname := trim(coalesce(v_group ->> 'name', ''));
        continue when v_gname = '';

        v_gvals := case
                     when jsonb_typeof(v_group -> 'values') = 'array' then v_group -> 'values'
                     else '[]'::jsonb
                   end;
        continue when jsonb_array_length(v_gvals) = 0;

        v_optval := trim(coalesce(v_item.opts ->> v_gname, ''));

        if v_optval = '' then
          return jsonb_build_object(
            'ok', false, 'error', 'variant',
            'item', coalesce(v_prod ->> 'name', ''),
            'group', v_gname
          );
        end if;

        if not (v_gvals ? v_optval) then
          return jsonb_build_object(
            'ok', false, 'error', 'variant_invalid',
            'item', coalesce(v_prod ->> 'name', ''),
            'group', v_gname
          );
        end if;

        -- لو القيمة دي ليها كمية محددة، نتحقق من المتاح بعد حجز الطلبات الجارية
        if jsonb_typeof(v_group -> 'stock') = 'object' and (v_group -> 'stock') ? v_optval then
          select coalesce(sum(greatest(0, coalesce((it ->> 'qty')::int, 0))), 0)::int
            into v_var_res
          from public.orders o
          cross join lateral jsonb_array_elements(
            case when jsonb_typeof(o.items) = 'array' then o.items else '[]'::jsonb end
          ) it
          where o.shop_id = st.shop_id
            and o.status in ('new', 'confirmed', 'ready', 'out_for_delivery')
            and it ->> 'id' = v_item.id
            and coalesce(it -> 'opts' ->> v_gname, '') = v_optval;

          v_cap := greatest(0,
                     case when (v_group -> 'stock' ->> v_optval) ~ '^[0-9]+$'
                          then (v_group -> 'stock' ->> v_optval)::int else 0 end
                     - v_var_res);

          if v_qty > v_cap then
            return jsonb_build_object(
              'ok', false, 'error', 'variant_stock',
              'item', coalesce(v_prod ->> 'name', ''),
              'group', v_gname,
              'value', v_optval,
              'available', v_cap
            );
          end if;
        end if;

        v_variant := v_variant || case when v_variant = '' then '' else ' · ' end || v_optval;
      end loop;
    end if;

    v_price := coalesce(nullif(v_prod ->> 'storePrice', '')::numeric, nullif(v_prod ->> 'price', '')::numeric, 0);
    v_subtotal := v_subtotal + (v_price * v_qty);

    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'id',       v_prod ->> 'id',
      'name',     coalesce(v_prod ->> 'name', ''),
      'variant',  v_variant,
      'opts',     coalesce(v_item.opts, '{}'::jsonb),
      'price',    v_price,
      'qty',      v_qty,
      'subtotal', v_price * v_qty
    ));
  end loop;

  v_min := coalesce(nullif(cfg ->> 'minOrder', '')::numeric, 0);
  if v_min > 0 and v_subtotal < v_min then
    return jsonb_build_object('ok', false, 'error', 'min_order', 'min', v_min);
  end if;

  v_zones := case when jsonb_typeof(cfg -> 'zones') = 'array' then cfg -> 'zones' else '[]'::jsonb end;
  v_free  := coalesce(nullif(cfg ->> 'freeOver', '')::numeric, 0);

  if v_fulfill = 'pickup' then
    v_delivery := 0;
  elsif jsonb_array_length(v_zones) > 0 then
    -- اختيار المنطقة: السعر من إعدادات المالك، ولو المنطقة مش موجودة نرفض الطلب
    select count(*)::int,
           max(coalesce(nullif(z ->> 'fee', '')::numeric, coalesce(nullif(cfg ->> 'deliveryFee', '')::numeric, 0)))
      into v_zone_n, v_zone_fee
    from jsonb_array_elements(v_zones) z
    where (z ->> 'name') = v_zone
       or coalesce(z ->> 'id', '') = v_zone;

    if v_zone_n = 0 or v_zone = '' then
      return jsonb_build_object('ok', false, 'error', 'zone');
    end if;

    v_delivery := coalesce(v_zone_fee, 0);
  else
    v_delivery := coalesce(nullif(cfg ->> 'deliveryFee', '')::numeric, 0);
  end if;

  -- توصيل مجاني فوق مبلغ معين (لا يشمل الاستلام من الفرع)
  if v_fulfill = 'delivery' and v_free > 0 and v_subtotal >= v_free then
    v_delivery := 0;
  end if;

  v_total := v_subtotal + v_delivery;

  loop
    v_attempt := v_attempt + 1;
    v_code := 'VZ-' || upper(substr(md5(random()::text || clock_timestamp()::text || v_attempt::text), 1, 6));
    exit when not exists (select 1 from public.orders o where o.code = v_code);
    exit when v_attempt >= 12;
  end loop;

  insert into public.orders (
    code, shop_id, customer, fulfillment, payment, items,
    subtotal, delivery_fee, total, status, note, payment_ref, payment_proof
  ) values (
    v_code, st.shop_id,
    jsonb_build_object(
      'name', v_name,
      'phone', v_phone,
      'address', v_address,
      'area', v_area,
      'zone', v_zone
    ),
    v_fulfill, v_payment, v_lines,
    v_subtotal, v_delivery, v_total, 'new',
    left(coalesce(p_note, ''), 500),
    v_pay_ref, v_pay_proof
  )
  returning id into v_id;

  return jsonb_build_object(
    'ok', true,
    'id', v_id,
    'code', v_code,
    'subtotal', v_subtotal,
    'deliveryFee', v_delivery,
    'total', v_total,
    'zone', v_zone
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
      'paymentRef', o.payment_ref,
      'hasProof', (o.payment_proof <> ''),
      'items', o.items,
      'subtotal', o.subtotal,
      'deliveryFee', o.delivery_fee,
      'total', o.total,
      'note', o.note,
      'rejectReason', o.reject_reason,
      'area', coalesce(nullif(o.customer ->> 'zone', ''), o.customer ->> 'area', ''),
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

-- ------------------------------------------------------------
-- 10) تقييمات المنتجات (بعد التسليم فقط)
-- ------------------------------------------------------------
create table if not exists public.store_reviews (
  id             uuid primary key default gen_random_uuid(),
  shop_id        text not null,
  product_id     text not null,
  order_code     text not null,
  customer_name  text not null default '',
  customer_phone text not null default '',
  rating         int  not null check (rating between 1 and 5),
  comment        text not null default '',
  hidden         boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (order_code, product_id)
);

create index if not exists store_reviews_product_idx
  on public.store_reviews (shop_id, product_id, created_at desc);
create index if not exists store_reviews_shop_idx
  on public.store_reviews (shop_id, created_at desc);

alter table public.store_reviews enable row level security;

drop policy if exists store_reviews_select on public.store_reviews;
create policy store_reviews_select on public.store_reviews
  for select to authenticated using (shop_id = auth.uid()::text);

drop policy if exists store_reviews_update on public.store_reviews;
create policy store_reviews_update on public.store_reviews
  for update to authenticated
  using (shop_id = auth.uid()::text)
  with check (shop_id = auth.uid()::text);

drop policy if exists store_reviews_delete on public.store_reviews;
create policy store_reviews_delete on public.store_reviews
  for delete to authenticated using (shop_id = auth.uid()::text);

revoke all on public.store_reviews from anon;
revoke insert on public.store_reviews from authenticated;
grant select, update, delete on public.store_reviews to authenticated;

create or replace function public.touch_store_reviews()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists store_reviews_touch on public.store_reviews;
create trigger store_reviews_touch before update on public.store_reviews
  for each row execute function public.touch_store_reviews();

-- إرسال تقييم: لازم أوردر مكتمل بنفس الكود + الموبايل، والصنف يكون داخل الأوردر
create or replace function public.store_submit_review(
  p_slug       text,
  p_code       text,
  p_phone      text,
  p_product_id text,
  p_rating     int,
  p_comment    text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  st        record;
  o         record;
  v_phone   text;
  v_name    text;
  v_display text;
  v_comment text;
  v_id      uuid;
begin
  select * into st from public.store_lookup(p_slug) limit 1;
  if st.shop_id is null then
    return jsonb_build_object('ok', false, 'error', 'store_not_found');
  end if;

  if p_rating is null or p_rating < 1 or p_rating > 5 then
    return jsonb_build_object('ok', false, 'error', 'rating');
  end if;

  if p_product_id is null or trim(p_product_id) = '' then
    return jsonb_build_object('ok', false, 'error', 'product');
  end if;

  v_phone := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');

  select * into o
  from public.orders
  where shop_id = st.shop_id
    and upper(code) = upper(trim(coalesce(p_code, '')))
    and regexp_replace(coalesce(customer ->> 'phone', ''), '[^0-9]', '', 'g') = v_phone
  limit 1;

  if o.id is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  if o.status <> 'done' then
    return jsonb_build_object('ok', false, 'error', 'not_done');
  end if;

  if not exists (
    select 1
    from jsonb_array_elements(
      case when jsonb_typeof(o.items) = 'array' then o.items else '[]'::jsonb end
    ) it
    where it ->> 'id' = trim(p_product_id)
  ) then
    return jsonb_build_object('ok', false, 'error', 'product');
  end if;

  v_name := trim(coalesce(o.customer ->> 'name', ''));
  v_display := split_part(v_name, ' ', 1);
  if v_display = '' then v_display := 'عميل'; end if;
  if position(' ' in v_name) > 0 then
    v_display := v_display || ' ' || left(split_part(v_name, ' ', 2), 1) || '.';
  end if;

  v_comment := left(trim(coalesce(p_comment, '')), 500);

  begin
    insert into public.store_reviews (
      shop_id, product_id, order_code, customer_name, customer_phone, rating, comment
    ) values (
      st.shop_id, trim(p_product_id), o.code, v_display, v_phone, p_rating, v_comment
    )
    returning id into v_id;
  exception
    when unique_violation then
      return jsonb_build_object('ok', false, 'error', 'already');
  end;

  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

grant execute on function public.store_submit_review(text, text, text, text, int, text) to anon, authenticated;

-- عرض تقييمات منتج (المخفي لا يظهر)
create or replace function public.store_product_reviews(p_slug text, p_product_id text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  st      record;
  v_avg   numeric := 0;
  v_count int := 0;
  v_list  jsonb := '[]'::jsonb;
begin
  select * into st from public.store_lookup(p_slug) limit 1;
  if st.shop_id is null then
    return jsonb_build_object('ok', false, 'error', 'store_not_found');
  end if;

  select coalesce(round(avg(r.rating)::numeric, 1), 0), count(*)::int
    into v_avg, v_count
  from public.store_reviews r
  where r.shop_id = st.shop_id
    and r.product_id = trim(p_product_id)
    and r.hidden = false;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id',        r.id,
      'name',      r.customer_name,
      'rating',    r.rating,
      'comment',   r.comment,
      'createdAt', r.created_at
    ) order by r.created_at desc), '[]'::jsonb)
    into v_list
  from (
    select * from public.store_reviews
    where shop_id = st.shop_id
      and product_id = trim(p_product_id)
      and hidden = false
    order by created_at desc
    limit 30
  ) r;

  return jsonb_build_object(
    'ok', true,
    'avg', v_avg,
    'count', v_count,
    'reviews', v_list
  );
end $$;

grant execute on function public.store_product_reviews(text, text) to anon, authenticated;

-- تحديث كاش الـ API بعد إنشاء الجداول والدوال
notify pgrst, 'reload schema';

-- ============================================================
--  خلاصة: العملاء بيقروا الكتالوج ويعملوا طلبات من غير تسجيل دخول،
--  وأنت بس اللي بتشوف وتدير الطلبات من حسابك.
-- ============================================================
