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
  order_number text not null unique,
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
  reserved_until timestamptz,
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
  reason text not null check (reason in ('restock', 'sale', 'return', 'correction', 'reservation_release')),
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
