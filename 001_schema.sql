-- =====================================================================
-- Highway Eat: Supabase backend (PostgreSQL)
-- Run ONCE on a new Supabase project: Dashboard -> SQL Editor -> New query -> paste this whole file -> Run.
-- Then run 002_functions.sql, then 003_storage_realtime.sql, then 004_reference_data.sql.
-- Nothing here is demo data. Kitchens, menus, orders and users are created by real people through the app.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- small helpers ----------
create or replace function public.today_ist() returns date
language sql stable as $$ select (now() at time zone 'Asia/Kolkata')::date $$;

create or replace function public.haversine_km(lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision)
returns double precision language sql immutable as $$
  select 2 * 6371 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)))
$$;

-- ---------- people and roles ----------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text not null,
  phone       text,
  email       text,
  veg_only    boolean not null default false,
  default_size text not null default 'full' check (default_size in ('half','full')),
  notify      jsonb not null default '{"orders":true,"taste":true,"offers":false}',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table if not exists public.user_roles (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  role       text not null check (role in ('customer','kitchen_partner','delivery_partner','admin')),
  granted_by uuid references public.profiles(id),
  granted_at timestamptz not null default now(),
  primary key (user_id, role)
);

create or replace function public.has_role(r text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = auth.uid() and role = r)
$$;
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$ select public.has_role('admin') $$;

-- every new sign-up becomes a profile with the CUSTOMER role only.
-- Partner and admin roles are never self-assigned (see approve flow and make_admin).
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, phone, email)
  values (new.id,
          coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''), split_part(coalesce(new.email, 'user'), '@', 1)),
          nullif(new.raw_user_meta_data ->> 'phone', ''),
          new.email);
  insert into public.user_roles (user_id, role) values (new.id, 'customer');
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- settings and reference ----------
create table if not exists public.app_settings (
  key   text primary key,
  value jsonb not null
);
create table if not exists public.service_areas (
  id     uuid primary key default gen_random_uuid(),
  name   text not null,
  lat    double precision not null,
  lng    double precision not null,
  active boolean not null default true
);
create table if not exists public.dishes (                 -- the dish catalogue: types of dish
  key        text primary key,
  name       text not null,
  category   text not null check (category in ('sabzi','protein','premium','dal','bread','rice','side')),
  is_veg     boolean not null,
  is_premium boolean not null default false,
  emoji      text,
  base_price_full int not null default 100
);

-- ---------- kitchens and menus ----------
create table if not exists public.kitchens (
  id           uuid primary key default gen_random_uuid(),
  owner_id     uuid not null references public.profiles(id),
  name         text not null,
  area         text,
  address      text,
  lat          double precision not null,
  lng          double precision not null,
  diet         text not null default 'veg' check (diet in ('veg','both')),
  default_capacity numeric not null default 20 check (default_capacity >= 0),
  avg_prep_min int not null default 25,
  capabilities text[] not null default '{}',
  commission_pct int not null default 15 check (commission_pct between 0 and 40),
  status       text not null default 'active' check (status in ('active','paused','suspended')),
  rating_avg   numeric(3,2) not null default 0,
  rating_count int not null default 0,
  photo_path   text,
  hours_open   text,
  hours_close  text,
  from_application uuid,
  created_at   timestamptz not null default now()
);
create index if not exists kitchens_owner_idx on public.kitchens (owner_id);

create table if not exists public.kitchen_capacity (       -- full tiffin = 1.0, half = 0.5
  kitchen_id   uuid not null references public.kitchens(id) on delete cascade,
  service_date date not null,
  capacity     numeric not null check (capacity >= 0),
  used         numeric not null default 0 check (used >= 0),
  primary key (kitchen_id, service_date),
  check (used <= capacity)                                  -- the database itself refuses overselling
);

create table if not exists public.kitchen_dishes (          -- one kitchen's version of a dish = a menu item
  id            uuid primary key default gen_random_uuid(),
  kitchen_id    uuid not null references public.kitchens(id) on delete cascade,
  dish_key      text not null references public.dishes(key),
  price_full    int not null check (price_full >= 0),
  price_half    int not null check (price_half >= 0),
  status        text not null default 'available' check (status in ('available','limited','unavailable')),
  tomorrow_status text not null default 'available' check (tomorrow_status in ('available','limited','unavailable')),
  tomorrow_cap  int not null default 0 check (tomorrow_cap >= 0),
  rating_avg    numeric(3,2) not null default 0,
  rating_count  int not null default 0,
  times_ordered int not null default 0,
  image_path    text,
  is_active     boolean not null default true,
  unique (kitchen_id, dish_key)
);
create index if not exists kitchen_dishes_kitchen_idx on public.kitchen_dishes (kitchen_id);

-- ---------- delivery partners ----------
create table if not exists public.delivery_partners (
  user_id      uuid primary key references public.profiles(id) on delete cascade,
  display_name text not null,
  vehicle      text,
  online       boolean not null default false,
  lat          double precision,
  lng          double precision,
  last_seen    timestamptz,
  earned_total int not null default 0,
  deliveries   int not null default 0,
  from_application uuid
);

-- ---------- orders ----------
create table if not exists public.orders (
  id             uuid primary key default gen_random_uuid(),
  public_id      text not null unique,
  customer_id    uuid not null references public.profiles(id),
  customer_label text not null,                              -- first name and initial only
  kitchen_id     uuid not null references public.kitchens(id),
  address_area   text not null default '',
  distance_km    numeric(7,2) not null default 0,
  eta_min        int not null default 0,
  units          numeric not null,
  subtotal       int not null,
  total          int not null,
  commission     int not null default 0,
  payment_method text not null default 'cod',
  payment_status text not null default 'pending' check (payment_status in ('pending','paid','refunded')),
  status         text not null default 'confirmed'
                 check (status in ('confirmed','accepted','preparing','ready','assigned','picked','out','delivered','cancelled')),
  rated          boolean not null default false,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index if not exists orders_customer_idx on public.orders (customer_id, created_at desc);
create index if not exists orders_kitchen_idx  on public.orders (kitchen_id, status);
create index if not exists orders_status_idx   on public.orders (status);

create table if not exists public.order_private (          -- sensitive: full name, phone, address, coordinates
  order_id     uuid primary key references public.orders(id) on delete cascade,
  customer_name text not null,
  phone        text,
  address_text text not null,
  lat          double precision not null,
  lng          double precision not null
);
create table if not exists public.order_lines (            -- what the customer chose
  id         uuid primary key default gen_random_uuid(),
  order_id   uuid not null references public.orders(id) on delete cascade,
  dish_key   text not null references public.dishes(key),
  size       text not null check (size in ('half','full')),
  qty        int not null check (qty between 1 and 10),
  unit_price int not null,
  unique (order_id, dish_key, size)
);
create table if not exists public.order_items (            -- what is packed (mains plus dal, roti, rice)
  id       uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  dish_key text not null references public.dishes(key),
  role     text not null,
  qty      int not null default 1
);
create table if not exists public.order_status_events (
  id       bigserial primary key,
  order_id uuid not null references public.orders(id) on delete cascade,
  status   text not null,
  actor_id uuid references public.profiles(id),
  at       timestamptz not null default now()
);
create index if not exists order_events_order_idx on public.order_status_events (order_id, at);

create table if not exists public.delivery_assignments (
  order_id     uuid primary key references public.orders(id) on delete cascade,
  partner_id   uuid not null references public.profiles(id),
  partner_name text not null,
  assigned_at  timestamptz not null default now(),
  picked_at    timestamptz,
  delivered_at timestamptz,
  payout       int not null default 0
);
create index if not exists assignments_partner_idx on public.delivery_assignments (partner_id);

-- ---------- customer extras ----------
create table if not exists public.addresses (
  id          uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.profiles(id) on delete cascade,
  label       text not null,
  text        text not null,
  lat         double precision not null,
  lng         double precision not null
);
create table if not exists public.favourites (               -- My Taste: a kitchen's dish, not a dish name
  customer_id     uuid not null references public.profiles(id) on delete cascade,
  kitchen_dish_id uuid not null references public.kitchen_dishes(id) on delete cascade,
  my_rating       smallint check (my_rating between 1 and 5),
  times_ordered   int not null default 0,
  created_at      timestamptz not null default now(),
  primary key (customer_id, kitchen_dish_id)
);
create table if not exists public.favourite_kitchens (
  customer_id uuid not null references public.profiles(id) on delete cascade,
  kitchen_id  uuid not null references public.kitchens(id) on delete cascade,
  primary key (customer_id, kitchen_id)
);
create table if not exists public.ratings (
  id              uuid primary key default gen_random_uuid(),
  order_id        uuid not null references public.orders(id) on delete cascade,
  customer_id     uuid not null references public.profiles(id),
  target          text not null check (target in ('order','kitchen','dish')),
  kitchen_dish_id uuid references public.kitchen_dishes(id),
  stars           smallint not null check (stars between 1 and 5),
  created_at      timestamptz not null default now()
);

-- ---------- partner applications ----------
create table if not exists public.document_requirements (   -- every document is OPTIONAL by default
  partner_type  text not null check (partner_type in ('kitchen','delivery')),
  doc_key       text not null,
  label         text not null,
  applies_to    text not null default 'all' check (applies_to in ('all','motor')),
  min_files     int not null default 1,
  required      boolean not null default false,
  required_from date,
  updated_by    uuid references public.profiles(id),
  updated_at    timestamptz not null default now(),
  primary key (partner_type, doc_key),
  check (required or required_from is null)
);
create table if not exists public.partner_applications (
  id          uuid primary key default gen_random_uuid(),
  public_id   text not null unique,
  type        text not null check (type in ('kitchen','delivery')),
  applicant_id uuid not null references public.profiles(id),
  status      text not null default 'submitted' check (status in ('submitted','under_review','more_info','approved','rejected')),
  form        jsonb not null,
  req_snapshot jsonb not null default '{}',
  verified_docs     boolean not null default false,
  verified_location boolean not null default false,
  verified_contact  boolean not null default false,
  decision_note text,
  reviewed_by uuid references public.profiles(id),
  grant_ref   uuid,
  submitted_at timestamptz not null default now(),
  decided_at  timestamptz,
  check (status <> 'approved' or (verified_docs and verified_location and verified_contact))
);
create unique index if not exists partner_app_one_open on public.partner_applications (applicant_id, type)
  where status in ('submitted','under_review','more_info','approved');
create table if not exists public.application_documents (
  id             uuid primary key default gen_random_uuid(),
  application_id uuid not null references public.partner_applications(id) on delete cascade,
  doc_key        text not null,
  file_name      text not null,
  storage_path   text not null,
  uploaded_at    timestamptz not null default now()
);
create table if not exists public.application_events (
  id             bigserial primary key,
  application_id uuid not null references public.partner_applications(id) on delete cascade,
  status         text not null,
  actor_id       uuid references public.profiles(id),
  note           text,
  at             timestamptz not null default now()
);

-- ---------- reception chat, notifications, logs ----------
create table if not exists public.chat_threads (
  user_id      uuid primary key references public.profiles(id) on delete cascade,
  role         text not null,
  status       text not null default 'open' check (status in ('open','resolved')),
  unread_admin int not null default 0,
  unread_user  int not null default 0,
  updated_at   timestamptz not null default now()
);
create table if not exists public.chat_messages (
  id             uuid primary key default gen_random_uuid(),
  thread_user_id uuid not null references public.chat_threads(user_id) on delete cascade,
  sender         text not null check (sender in ('user','reception','auto')),
  body           text not null check (char_length(body) between 1 and 800),
  ctx            text,
  created_at     timestamptz not null default now()
);
create index if not exists chat_messages_thread_idx on public.chat_messages (thread_user_id, created_at);
create table if not exists public.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  title      text not null,
  body       text,
  kind       text not null default 'account',
  read       boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists notifications_user_idx on public.notifications (user_id, created_at desc);
create table if not exists public.activity_log (
  id        bigserial primary key,
  at        timestamptz not null default now(),
  actor_id  uuid,
  action    text not null,
  entity    text,
  entity_id text,
  meta      jsonb not null default '{}'
);
create table if not exists public.error_log (
  id      bigserial primary key,
  at      timestamptz not null default now(),
  user_id uuid,
  source  text not null default 'client',
  message text not null,
  stack   text,
  context jsonb not null default '{}'
);

-- ---------- ownership helpers used by the security rules ----------
create or replace function public.owns_kitchen(k uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.kitchens where id = k and owner_id = auth.uid())
$$;
create or replace function public.is_assigned_rider(o uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.delivery_assignments where order_id = o and partner_id = auth.uid())
$$;
create or replace function public.is_online_rider() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.delivery_partners where user_id = auth.uid() and online)
$$;

-- ---------- column protection: nobody can edit their own ratings, commission or earnings ----------
create or replace function public.is_system() returns boolean
language sql stable as $$
  select coalesce(current_setting('app.system', true), '') = '1' or auth.uid() is null
$$;

create or replace function public.protect_kitchens() returns trigger language plpgsql as $$
begin
  if public.is_system() or public.is_admin() then return new; end if;
  if tg_op = 'INSERT' then raise exception 'Kitchens are created only by approving an application'; end if;
  new.owner_id := old.owner_id; new.commission_pct := old.commission_pct; new.status := old.status;
  new.rating_avg := old.rating_avg; new.rating_count := old.rating_count; new.from_application := old.from_application;
  return new;
end $$;
drop trigger if exists protect_kitchens_t on public.kitchens;
create trigger protect_kitchens_t before insert or update on public.kitchens for each row execute function public.protect_kitchens();

create or replace function public.protect_kitchen_dishes() returns trigger language plpgsql as $$
begin
  if public.is_system() or public.is_admin() then return new; end if;
  if tg_op = 'INSERT' then
    new.rating_avg := 0; new.rating_count := 0; new.times_ordered := 0; return new;
  end if;
  new.rating_avg := old.rating_avg; new.rating_count := old.rating_count; new.times_ordered := old.times_ordered;
  new.kitchen_id := old.kitchen_id; new.dish_key := old.dish_key;
  return new;
end $$;
drop trigger if exists protect_kitchen_dishes_t on public.kitchen_dishes;
create trigger protect_kitchen_dishes_t before insert or update on public.kitchen_dishes for each row execute function public.protect_kitchen_dishes();

create or replace function public.protect_delivery_partners() returns trigger language plpgsql as $$
begin
  if public.is_system() or public.is_admin() then return new; end if;
  if tg_op = 'INSERT' then raise exception 'Delivery partners are created only by approving an application'; end if;
  new.user_id := old.user_id; new.display_name := old.display_name;
  new.earned_total := old.earned_total; new.deliveries := old.deliveries; new.from_application := old.from_application;
  return new;
end $$;
drop trigger if exists protect_delivery_partners_t on public.delivery_partners;
create trigger protect_delivery_partners_t before insert or update on public.delivery_partners for each row execute function public.protect_delivery_partners();

create or replace function public.protect_profiles() returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists protect_profiles_t on public.profiles;
create trigger protect_profiles_t before update on public.profiles for each row execute function public.protect_profiles();

-- ---------- row level security: the real access control ----------
alter table public.profiles             enable row level security;
alter table public.user_roles           enable row level security;
alter table public.app_settings         enable row level security;
alter table public.service_areas        enable row level security;
alter table public.dishes               enable row level security;
alter table public.kitchens             enable row level security;
alter table public.kitchen_capacity     enable row level security;
alter table public.kitchen_dishes       enable row level security;
alter table public.delivery_partners    enable row level security;
alter table public.orders               enable row level security;
alter table public.order_private        enable row level security;
alter table public.order_lines          enable row level security;
alter table public.order_items          enable row level security;
alter table public.order_status_events  enable row level security;
alter table public.delivery_assignments enable row level security;
alter table public.addresses            enable row level security;
alter table public.favourites           enable row level security;
alter table public.favourite_kitchens   enable row level security;
alter table public.ratings              enable row level security;
alter table public.document_requirements enable row level security;
alter table public.partner_applications enable row level security;
alter table public.application_documents enable row level security;
alter table public.application_events   enable row level security;
alter table public.chat_threads         enable row level security;
alter table public.chat_messages        enable row level security;
alter table public.notifications        enable row level security;
alter table public.activity_log         enable row level security;
alter table public.error_log            enable row level security;

-- profiles and roles
drop policy if exists profiles_self on public.profiles;
create policy profiles_self on public.profiles for select to authenticated using (id = auth.uid() or public.is_admin());
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
drop policy if exists roles_self on public.user_roles;
create policy roles_self on public.user_roles for select to authenticated using (user_id = auth.uid() or public.is_admin());

-- reference data: readable by everyone, changed only by admin
drop policy if exists settings_read on public.app_settings;
create policy settings_read on public.app_settings for select to anon, authenticated using (true);
drop policy if exists areas_read on public.service_areas;
create policy areas_read on public.service_areas for select to anon, authenticated using (true);
drop policy if exists areas_admin on public.service_areas;
create policy areas_admin on public.service_areas for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists dishes_read on public.dishes;
create policy dishes_read on public.dishes for select to anon, authenticated using (true);
drop policy if exists dishes_admin on public.dishes;
create policy dishes_admin on public.dishes for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists docreq_read on public.document_requirements;
create policy docreq_read on public.document_requirements for select to anon, authenticated using (true);

-- kitchens and menus: browsable by anyone, edited by the owner
drop policy if exists kitchens_read on public.kitchens;
create policy kitchens_read on public.kitchens for select to anon, authenticated
  using (status = 'active' or owner_id = auth.uid() or public.is_admin());
drop policy if exists kitchens_owner_update on public.kitchens;
create policy kitchens_owner_update on public.kitchens for update to authenticated
  using (owner_id = auth.uid() or public.is_admin()) with check (owner_id = auth.uid() or public.is_admin());
drop policy if exists capacity_read on public.kitchen_capacity;
create policy capacity_read on public.kitchen_capacity for select to anon, authenticated using (true);
drop policy if exists capacity_owner on public.kitchen_capacity;
create policy capacity_owner on public.kitchen_capacity for all to authenticated
  using (public.owns_kitchen(kitchen_id)) with check (public.owns_kitchen(kitchen_id));
drop policy if exists kd_read on public.kitchen_dishes;
create policy kd_read on public.kitchen_dishes for select to anon, authenticated
  using (is_active or public.owns_kitchen(kitchen_id) or public.is_admin());
drop policy if exists kd_owner_write on public.kitchen_dishes;
create policy kd_owner_write on public.kitchen_dishes for all to authenticated
  using (public.owns_kitchen(kitchen_id) or public.is_admin()) with check (public.owns_kitchen(kitchen_id) or public.is_admin());

-- delivery partners
drop policy if exists dp_read on public.delivery_partners;
create policy dp_read on public.delivery_partners for select to authenticated using (user_id = auth.uid() or public.is_admin());
drop policy if exists dp_update_self on public.delivery_partners;
create policy dp_update_self on public.delivery_partners for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- orders: customer sees own, kitchen sees its own, riders see ready orders and their own, admin sees all.
-- Clients never write orders directly; they call place_order / order_advance (see 002_functions.sql).
drop policy if exists orders_read on public.orders;
create policy orders_read on public.orders for select to authenticated using (
  customer_id = auth.uid()
  or public.owns_kitchen(kitchen_id)
  or public.is_admin()
  or (public.has_role('delivery_partner') and (status = 'ready' or public.is_assigned_rider(id)))
);
drop policy if exists order_private_read on public.order_private;
create policy order_private_read on public.order_private for select to authenticated using (
  public.is_admin()
  or exists (select 1 from public.orders o where o.id = order_id and o.customer_id = auth.uid())
  or public.is_assigned_rider(order_id)
);
drop policy if exists order_lines_read on public.order_lines;
create policy order_lines_read on public.order_lines for select to authenticated using (exists (select 1 from public.orders o where o.id = order_id));
drop policy if exists order_items_read on public.order_items;
create policy order_items_read on public.order_items for select to authenticated using (exists (select 1 from public.orders o where o.id = order_id));
drop policy if exists order_events_read on public.order_status_events;
create policy order_events_read on public.order_status_events for select to authenticated using (exists (select 1 from public.orders o where o.id = order_id));
drop policy if exists assignments_read on public.delivery_assignments;
create policy assignments_read on public.delivery_assignments for select to authenticated using (exists (select 1 from public.orders o where o.id = order_id));

-- customer extras: own rows only
drop policy if exists addresses_own on public.addresses;
create policy addresses_own on public.addresses for all to authenticated using (customer_id = auth.uid()) with check (customer_id = auth.uid());
drop policy if exists fav_own on public.favourites;
create policy fav_own on public.favourites for select to authenticated using (customer_id = auth.uid());   -- writes go through toggle_favourite()
drop policy if exists favk_own on public.favourite_kitchens;
create policy favk_own on public.favourite_kitchens for all to authenticated using (customer_id = auth.uid()) with check (customer_id = auth.uid());
drop policy if exists ratings_own on public.ratings;
create policy ratings_own on public.ratings for select to authenticated using (customer_id = auth.uid() or public.is_admin());

-- applications: the applicant sees their own, admin sees all. Writes only through functions.
drop policy if exists apps_read on public.partner_applications;
create policy apps_read on public.partner_applications for select to authenticated using (applicant_id = auth.uid() or public.is_admin());
drop policy if exists appdocs_read on public.application_documents;
create policy appdocs_read on public.application_documents for select to authenticated
  using (exists (select 1 from public.partner_applications a where a.id = application_id));
drop policy if exists appevents_read on public.application_events;
create policy appevents_read on public.application_events for select to authenticated
  using (exists (select 1 from public.partner_applications a where a.id = application_id));

-- chat, notifications, logs
drop policy if exists chat_threads_read on public.chat_threads;
create policy chat_threads_read on public.chat_threads for select to authenticated using (user_id = auth.uid() or public.is_admin());
drop policy if exists chat_messages_read on public.chat_messages;
create policy chat_messages_read on public.chat_messages for select to authenticated using (thread_user_id = auth.uid() or public.is_admin());
drop policy if exists notes_read on public.notifications;
create policy notes_read on public.notifications for select to authenticated using (user_id = auth.uid());
drop policy if exists notes_update on public.notifications;
create policy notes_update on public.notifications for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists activity_admin on public.activity_log;
create policy activity_admin on public.activity_log for select to authenticated using (public.is_admin());
drop policy if exists errors_admin on public.error_log;
create policy errors_admin on public.error_log for select to authenticated using (public.is_admin());
