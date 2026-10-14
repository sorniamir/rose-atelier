-- ROSÉ ATELIER store schema — starter migration.
-- Review currency/price units and provider-specific payment flow before production.
-- Do not apply this migration to an unrelated Supabase project.

create table if not exists public.store_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  sku text unique,
  name text not null,
  description text not null default '',
  category text not null check (category in ('apparel', 'accessories', 'fragrance')),
  price_amount numeric(14,2) not null check (price_amount >= 0),
  compare_at_amount numeric(14,2) check (compare_at_amount is null or compare_at_amount >= price_amount),
  currency_code text not null default 'IRR' check (currency_code ~ '^[A-Z]{3}$'),
  stock integer not null default 0 check (stock >= 0),
  image_url text,
  is_published boolean not null default false,
  is_featured boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists products_published_category_idx
  on public.products (category, is_published);
create index if not exists products_featured_idx
  on public.products (is_featured, created_at desc)
  where is_published = true;

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique default ('RA-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10))),
  customer_id uuid references auth.users(id) on delete set null,
  customer_name text not null,
  customer_phone text not null,
  shipping_address text not null,
  customer_note text,
  total_amount numeric(14,2) not null check (total_amount >= 0),
  currency_code text not null check (currency_code ~ '^[A-Z]{3}$'),
  status text not null default 'pending_payment'
    check (status in ('pending_payment', 'paid', 'processing', 'shipped', 'delivered', 'cancelled', 'refunded')),
  payment_status text not null default 'unpaid'
    check (payment_status in ('unpaid', 'pending', 'paid', 'failed', 'refunded')),
  payment_provider text,
  payment_reference text unique,
  reserved_until timestamptz default (now() + interval '15 minutes'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists orders_customer_created_idx
  on public.orders (customer_id, created_at desc);
create index if not exists orders_status_created_idx
  on public.orders (status, created_at desc);

create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid references public.products(id) on delete set null,
  product_name text not null,
  sku text,
  unit_price numeric(14,2) not null check (unit_price >= 0),
  quantity integer not null check (quantity > 0),
  line_total numeric(14,2) generated always as (unit_price * quantity) stored,
  created_at timestamptz not null default now(),
  unique (order_id, product_id)
);

create index if not exists order_items_order_idx on public.order_items (order_id);
create index if not exists order_items_product_idx on public.order_items (product_id);

-- Track inventory changes for auditability. Only trusted server code should write this table.
create table if not exists public.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete restrict,
  quantity_delta integer not null check (quantity_delta <> 0),
  reason text not null check (reason in ('restock', 'sale', 'return', 'correction', 'reservation', 'reservation_release')),
  order_id uuid references public.orders(id) on delete set null,
  note text,
  actor_user_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists inventory_movements_product_created_idx
  on public.inventory_movements (product_id, created_at desc);

-- Every public-schema table uses RLS. Browser clients never receive write access to stock or orders.
alter table public.store_admins enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.inventory_movements enable row level security;

drop policy if exists "admins can read own membership" on public.store_admins;
create policy "admins can read own membership"
  on public.store_admins for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists "published products or admin can read products" on public.products;
create policy "published products or admin can read products"
  on public.products for select to anon, authenticated
  using (
    is_published = true
    or exists (
      select 1 from public.store_admins a
      where a.user_id = (select auth.uid())
    )
  );

drop policy if exists "admins can insert products" on public.products;
create policy "admins can insert products"
  on public.products for insert to authenticated
  with check (exists (select 1 from public.store_admins a where a.user_id = (select auth.uid())));

drop policy if exists "admins can update products" on public.products;
create policy "admins can update products"
  on public.products for update to authenticated
  using (exists (select 1 from public.store_admins a where a.user_id = (select auth.uid())))
  with check (exists (select 1 from public.store_admins a where a.user_id = (select auth.uid())));

drop policy if exists "admins can delete products" on public.products;
create policy "admins can delete products"
  on public.products for delete to authenticated
  using (exists (select 1 from public.store_admins a where a.user_id = (select auth.uid())));

drop policy if exists "customers and admins can read orders" on public.orders;
create policy "customers and admins can read orders"
  on public.orders for select to authenticated
  using (
    customer_id = (select auth.uid())
    or exists (select 1 from public.store_admins a where a.user_id = (select auth.uid()))
  );

drop policy if exists "customers and admins can read order items" on public.order_items;
create policy "customers and admins can read order items"
  on public.order_items for select to authenticated
  using (
    exists (
      select 1 from public.orders o
      where o.id = order_id
        and (
          o.customer_id = (select auth.uid())
          or exists (select 1 from public.store_admins a where a.user_id = (select auth.uid()))
        )
    )
  );

drop policy if exists "admins can read inventory history" on public.inventory_movements;
create policy "admins can read inventory history"
  on public.inventory_movements for select to authenticated
  using (exists (select 1 from public.store_admins a where a.user_id = (select auth.uid())));

-- Explicit grants complement RLS. No anon/authenticated INSERT/UPDATE on orders/items/inventory.
grant select on public.products to anon, authenticated;
grant select on public.store_admins, public.orders, public.order_items to authenticated;
grant select on public.inventory_movements to authenticated;
grant insert, update, delete on public.products to authenticated;
grant all on public.store_admins, public.products, public.orders, public.order_items, public.inventory_movements to service_role;

-- Add the first administrator manually after creating the user in Supabase Auth:
-- insert into public.store_admins (user_id) values ('<auth.users UUID>');
-- Never expose service_role/secret keys to browser code.


-- Create an order and reserve inventory in one database transaction.
-- This RPC is deliberately callable only by server-side service_role code.
create or replace function public.create_store_order(
  p_customer_id uuid,
  p_customer_name text,
  p_customer_phone text,
  p_shipping_address text,
  p_customer_note text,
  p_currency_code text,
  p_items jsonb
)
returns uuid
language plpgsql
security invoker
set search_path = pg_catalog, public
as $$
declare
  v_order_id uuid;
  v_total numeric(14,2) := 0;
  v_item record;
  v_product public.products%rowtype;
begin
  if p_customer_id is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if length(trim(coalesce(p_customer_name, ''))) not between 2 and 160
     or length(trim(coalesce(p_customer_phone, ''))) not between 8 and 32
     or length(trim(coalesce(p_shipping_address, ''))) not between 8 and 1200 then
    raise exception 'Invalid customer or shipping information' using errcode = '22023';
  end if;
  if p_currency_code !~ '^[A-Z]{3}$' then
    raise exception 'Invalid currency code' using errcode = '22023';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' then
    raise exception 'Items must be an array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 20 then
    raise exception 'Order must contain between 1 and 20 products' using errcode = '22023';
  end if;

  insert into public.orders (
    customer_id, customer_name, customer_phone, shipping_address,
    customer_note, total_amount, currency_code, status, payment_status,
    reserved_until
  ) values (
    p_customer_id, trim(p_customer_name), trim(p_customer_phone),
    trim(p_shipping_address), nullif(trim(coalesce(p_customer_note, '')), ''),
    0, p_currency_code, 'pending_payment', 'unpaid', now() + interval '15 minutes'
  ) returning id into v_order_id;

  -- Aggregate duplicate product IDs and lock in consistent order to avoid deadlocks.
  for v_item in
    select
      (item.value ->> 'product_id')::uuid as product_id,
      sum((item.value ->> 'quantity')::integer)::integer as quantity
    from jsonb_array_elements(p_items) as item(value)
    group by (item.value ->> 'product_id')::uuid
    order by (item.value ->> 'product_id')::uuid
  loop
    if v_item.quantity < 1 or v_item.quantity > 20 then
      raise exception 'Invalid product quantity' using errcode = '22023';
    end if;

    select * into v_product
    from public.products
    where id = v_item.product_id and is_published = true
    for update;

    if not found then
      raise exception 'Product is not available: %', v_item.product_id using errcode = 'P0002';
    end if;
    if v_product.currency_code <> p_currency_code then
      raise exception 'Product currency does not match store currency' using errcode = '22023';
    end if;
    if v_product.stock < v_item.quantity then
      raise exception 'Insufficient stock for product: %', v_product.name using errcode = 'P0001';
    end if;

    update public.products
      set stock = stock - v_item.quantity, updated_at = now()
      where id = v_product.id;

    insert into public.order_items (
      order_id, product_id, product_name, sku, unit_price, quantity
    ) values (
      v_order_id, v_product.id, v_product.name, v_product.sku,
      v_product.price_amount, v_item.quantity
    );

    insert into public.inventory_movements (
      product_id, quantity_delta, reason, order_id, note, actor_user_id
    ) values (
      v_product.id, -v_item.quantity, 'reservation', v_order_id,
      'Stock reserved for checkout; release if payment is not completed.',
      p_customer_id
    );

    v_total := v_total + (v_product.price_amount * v_item.quantity);
  end loop;

  update public.orders
    set total_amount = v_total, updated_at = now()
    where id = v_order_id;

  return v_order_id;
end;
$$;

-- Called by a trusted backend after the payment provider's signature/status is verified.
-- The function is idempotent for the same order/reference pair.
create or replace function public.mark_store_order_paid(
  p_order_id uuid,
  p_provider text,
  p_reference text
)
returns uuid
language plpgsql
security invoker
set search_path = pg_catalog, public
as $$
declare
  v_order public.orders%rowtype;
begin
  if nullif(trim(coalesce(p_provider, '')), '') is null
     or nullif(trim(coalesce(p_reference, '')), '') is null then
    raise exception 'Payment provider and reference are required' using errcode = '22023';
  end if;

  select * into v_order
    from public.orders where id = p_order_id for update;

  if not found then
    raise exception 'Order not found' using errcode = 'P0002';
  end if;

  if v_order.payment_status = 'paid' then
    if v_order.payment_reference = p_reference then
      return v_order.id;
    end if;
    raise exception 'Order has already been paid with another reference' using errcode = '23505';
  end if;

  if v_order.status <> 'pending_payment'
     or v_order.reserved_until is null
     or v_order.reserved_until <= now() then
    raise exception 'Order reservation has expired' using errcode = 'P0001';
  end if;

  update public.orders
    set status = 'paid', payment_status = 'paid',
        payment_provider = trim(p_provider), payment_reference = trim(p_reference),
        reserved_until = null, updated_at = now()
    where id = p_order_id;

  return p_order_id;
end;
$$;

-- Release stock reserved by orders that were never paid. Schedule this RPC from a
-- trusted server/cron after the payment window has elapsed.
create or replace function public.release_expired_store_reservations()
returns integer
language plpgsql
security invoker
set search_path = pg_catalog, public
as $$
declare
  v_order record;
  v_released integer := 0;
begin
  for v_order in
    select o.id
    from public.orders o
    where o.status = 'pending_payment'
      and o.payment_status in ('unpaid', 'failed')
      and o.reserved_until <= now()
    order by o.created_at
    for update skip locked
  loop
    update public.products p
      set stock = p.stock + oi.quantity, updated_at = now()
      from public.order_items oi
      where oi.order_id = v_order.id and oi.product_id = p.id;

    insert into public.inventory_movements (
      product_id, quantity_delta, reason, order_id, note
    )
    select oi.product_id, oi.quantity, 'reservation_release', v_order.id,
           'Expired unpaid reservation released.'
    from public.order_items oi
    where oi.order_id = v_order.id and oi.product_id is not null;

    update public.orders
      set status = 'cancelled', reserved_until = null, updated_at = now()
      where id = v_order.id;

    v_released := v_released + 1;
  end loop;
  return v_released;
end;
$$;

-- Administrative stock changes are applied and logged atomically.
create or replace function public.adjust_product_inventory(
  p_product_id uuid,
  p_quantity_delta integer,
  p_reason text,
  p_note text,
  p_actor_user_id uuid
)
returns integer
language plpgsql
security invoker
set search_path = pg_catalog, public
as $$
declare
  v_stock integer;
begin
  if p_actor_user_id is null
     or p_quantity_delta = 0
     or p_reason not in ('restock', 'return', 'correction') then
    raise exception 'Invalid inventory adjustment' using errcode = '22023';
  end if;
  if p_reason in ('restock', 'return') and p_quantity_delta < 0 then
    raise exception 'Restock and return movements must increase stock' using errcode = '22023';
  end if;
  if p_reason = 'correction' and length(trim(coalesce(p_note, ''))) < 4 then
    raise exception 'Correction requires an audit note' using errcode = '22023';
  end if;

  update public.products
    set stock = stock + p_quantity_delta, updated_at = now()
    where id = p_product_id and stock + p_quantity_delta >= 0
    returning stock into v_stock;

  if not found then
    raise exception 'Product not found or stock cannot become negative' using errcode = 'P0001';
  end if;

  insert into public.inventory_movements (
    product_id, quantity_delta, reason, note, actor_user_id
  ) values (
    p_product_id, p_quantity_delta, p_reason,
    nullif(trim(coalesce(p_note, '')), ''), p_actor_user_id
  );
  return v_stock;
end;
$$;

revoke all on function public.create_store_order(uuid, text, text, text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.mark_store_order_paid(uuid, text, text) from public, anon, authenticated;
revoke all on function public.release_expired_store_reservations() from public, anon, authenticated;
revoke all on function public.adjust_product_inventory(uuid, integer, text, text, uuid) from public, anon, authenticated;
grant execute on function public.create_store_order(uuid, text, text, text, text, text, jsonb) to service_role;
grant execute on function public.mark_store_order_paid(uuid, text, text) to service_role;
grant execute on function public.release_expired_store_reservations() to service_role;
grant execute on function public.adjust_product_inventory(uuid, integer, text, text, uuid) to service_role;
