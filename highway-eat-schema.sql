-- Highway Eat: PostgreSQL 16 + PostGIS schema
-- One shared database, multi-tenant by kitchen_id. Designed for 10,000+ kitchens.
-- Money is stored as integer paise. Times are timestamptz (UTC).

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ------------------------------------------------------------------ enums
CREATE TYPE user_role       AS ENUM ('customer','kitchen_owner','kitchen_staff','delivery_partner','admin','support');
CREATE TYPE meal_slot       AS ENUM ('lunch','dinner');
CREATE TYPE tiffin_size     AS ENUM ('half','full');
CREATE TYPE member_tier     AS ENUM ('basic','pro','gold','platinum');
CREATE TYPE dish_category   AS ENUM ('sabzi','protein','premium','dal','bread','rice','side');
CREATE TYPE avail_status    AS ENUM ('available','limited','unavailable');
CREATE TYPE order_status    AS ENUM ('confirmed','accepted','preparing','ready','assigned','picked_up','out_for_delivery','delivered','cancelled');
CREATE TYPE order_kind      AS ENUM ('one_time','subscription_meal');
CREATE TYPE sub_status      AS ENUM ('active','paused','expired','cancelled');
CREATE TYPE meal_state      AS ENUM ('planned','locked','skipped','delivered','failed');
CREATE TYPE pay_status      AS ENUM ('pending','paid','failed','refunded','partially_refunded');

-- ------------------------------------------------------------------ identity
CREATE TABLE users (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  role            user_role NOT NULL,
  phone_e164      text UNIQUE NOT NULL,            -- login via OTP; never shown to other roles
  email           text UNIQUE,
  display_name    text NOT NULL,
  status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active','suspended','deleted')),
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE customers (
  user_id         uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  diet_pref       text CHECK (diet_pref IN ('veg','jain','non_veg','any')) DEFAULT 'any',
  default_address_id uuid,
  marketing_opt_in boolean NOT NULL DEFAULT false
);

CREATE TABLE addresses (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id     uuid NOT NULL REFERENCES customers(user_id) ON DELETE CASCADE,
  label           text NOT NULL,
  line1           text NOT NULL,
  area            text NOT NULL,                    -- coarse label safe to show to a delivery partner before pickup
  geo             geography(Point,4326) NOT NULL,
  is_deleted      boolean NOT NULL DEFAULT false
);
CREATE INDEX addresses_geo_gix ON addresses USING gist (geo);
ALTER TABLE customers ADD FOREIGN KEY (default_address_id) REFERENCES addresses(id);

CREATE TABLE kitchen_partners (                     -- the business owner account
  user_id         uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  legal_name      text NOT NULL,
  fssai_license   text NOT NULL,                    -- food safety licence, required to go live
  payout_account_token text NOT NULL                -- provider token, never a raw bank number
);

CREATE TABLE delivery_partners (
  user_id         uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  vehicle         text NOT NULL,
  kyc_status      text NOT NULL DEFAULT 'pending' CHECK (kyc_status IN ('pending','approved','rejected')),
  online          boolean NOT NULL DEFAULT false,
  last_geo        geography(Point,4326),
  last_seen_at    timestamptz
);
CREATE INDEX delivery_partners_geo_gix ON delivery_partners USING gist (last_geo) WHERE online;

-- ------------------------------------------------------------------ kitchens
CREATE TABLE kitchens (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id        uuid NOT NULL REFERENCES kitchen_partners(user_id),
  name            text NOT NULL,
  diet_type       text NOT NULL CHECK (diet_type IN ('pure_veg','veg_and_non_veg')),
  offers_one_time boolean NOT NULL DEFAULT true,
  offers_7_day    boolean NOT NULL DEFAULT true,
  offers_30_day   boolean NOT NULL DEFAULT false,
  capabilities    text[] NOT NULL DEFAULT '{}',     -- e.g. spice, less_oil, no_onion_garlic, extra_protein. Bounds Platinum customisation.
  commission_bps  int NOT NULL DEFAULT 1500 CHECK (commission_bps BETWEEN 0 AND 4000),
  avg_prep_min    int NOT NULL DEFAULT 25,
  rating_avg      numeric(3,2) NOT NULL DEFAULT 0,
  rating_count    int NOT NULL DEFAULT 0,
  status          text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','active','paused','suspended')),
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX kitchens_active_idx ON kitchens (status) WHERE status='active';

CREATE TABLE kitchen_locations (
  kitchen_id      uuid PRIMARY KEY REFERENCES kitchens(id) ON DELETE CASCADE,
  address_line    text NOT NULL,
  area            text NOT NULL,
  geo             geography(Point,4326) NOT NULL,
  h3_res7         text NOT NULL                     -- precomputed cell for fast candidate lookup
);
CREATE INDEX kitchen_locations_geo_gix ON kitchen_locations USING gist (geo);
CREATE INDEX kitchen_locations_h3_idx  ON kitchen_locations (h3_res7);

CREATE TABLE kitchen_staff (
  user_id         uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  kitchen_id      uuid NOT NULL REFERENCES kitchens(id) ON DELETE CASCADE,
  staff_role      text NOT NULL CHECK (staff_role IN ('manager','cook','packer'))
);
CREATE INDEX kitchen_staff_kitchen_idx ON kitchen_staff (kitchen_id);

-- ------------------------------------------------------------------ dishes
-- dishes = the dish TYPE ("Bhindi Masala"). kitchen_dishes = ONE KITCHEN'S VERSION of it.
-- Favourites, ratings and demand all hang off kitchen_dishes, so
-- Bhindi from Kitchen A and Bhindi from Kitchen B are always distinct.
CREATE TABLE dishes (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name            text NOT NULL UNIQUE,
  category        dish_category NOT NULL,
  is_veg          boolean NOT NULL,
  is_premium      boolean NOT NULL DEFAULT false,
  search_tags     text[] NOT NULL DEFAULT '{}'
);
CREATE INDEX dishes_name_trgm ON dishes USING gin (name gin_trgm_ops);

CREATE TABLE kitchen_dishes (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kitchen_id      uuid NOT NULL REFERENCES kitchens(id) ON DELETE CASCADE,
  dish_id         uuid NOT NULL REFERENCES dishes(id),
  price_full_paise int NOT NULL CHECK (price_full_paise >= 0),
  price_half_paise int NOT NULL CHECK (price_half_paise >= 0),
  rating_avg      numeric(3,2) NOT NULL DEFAULT 0,
  rating_count    int NOT NULL DEFAULT 0,
  times_ordered   int NOT NULL DEFAULT 0,
  is_active       boolean NOT NULL DEFAULT true,
  UNIQUE (kitchen_id, dish_id)
);
CREATE INDEX kitchen_dishes_dish_idx ON kitchen_dishes (dish_id) WHERE is_active;

CREATE TABLE ingredients (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name            text NOT NULL UNIQUE,
  unit            text NOT NULL                      -- kg, l, piece
);
CREATE TABLE dish_ingredients (                      -- per-serving quantities, drives raw-material planning
  dish_id         uuid REFERENCES dishes(id) ON DELETE CASCADE,
  ingredient_id   uuid REFERENCES ingredients(id),
  qty_per_full    numeric(10,3) NOT NULL,
  PRIMARY KEY (dish_id, ingredient_id)
);

-- ------------------------------------------------------------------ menus and capacity
CREATE TABLE menus (                                 -- one row per kitchen, day and slot
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kitchen_id      uuid NOT NULL REFERENCES kitchens(id) ON DELETE CASCADE,
  service_date    date NOT NULL,
  slot            meal_slot NOT NULL,
  max_meals       int NOT NULL CHECK (max_meals >= 0),
  published_at    timestamptz,
  locked_at       timestamptz,                       -- set by the nightly job; no edits after this
  UNIQUE (kitchen_id, service_date, slot)
);
CREATE TABLE menu_items (
  menu_id         uuid REFERENCES menus(id) ON DELETE CASCADE,
  kitchen_dish_id uuid REFERENCES kitchen_dishes(id),
  status          avail_status NOT NULL DEFAULT 'available',
  capacity        int NOT NULL CHECK (capacity >= 0),
  reserved        int NOT NULL DEFAULT 0 CHECK (reserved >= 0),
  PRIMARY KEY (menu_id, kitchen_dish_id),
  CHECK (reserved <= capacity)                       -- the database itself refuses overselling
);

CREATE TABLE kitchen_capacities (                    -- tiffin units: full = 1.0, half = 0.5
  kitchen_id      uuid REFERENCES kitchens(id) ON DELETE CASCADE,
  service_date    date,
  slot            meal_slot,
  capacity_units  numeric(8,1) NOT NULL CHECK (capacity_units >= 0),
  reserved_units  numeric(8,1) NOT NULL DEFAULT 0 CHECK (reserved_units >= 0),
  PRIMARY KEY (kitchen_id, service_date, slot),
  CHECK (reserved_units <= capacity_units)
);
-- Reservation is one atomic statement. Zero rows updated means sold out:
--   UPDATE kitchen_capacities SET reserved_units = reserved_units + $units
--   WHERE kitchen_id=$k AND service_date=$d AND slot=$s AND reserved_units + $units <= capacity_units;

-- ------------------------------------------------------------------ plans and subscriptions
CREATE TABLE subscription_plans (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tier            member_tier NOT NULL,
  duration_days   int NOT NULL CHECK (duration_days IN (7,30)),
  size            tiffin_size NOT NULL,
  price_per_meal_paise int NOT NULL,
  discount_bps    int NOT NULL DEFAULT 0,
  max_skips       int NOT NULL,
  max_pauses      int NOT NULL,
  max_date_changes int NOT NULL,
  active          boolean NOT NULL DEFAULT true,
  UNIQUE (tier, duration_days, size)
);

CREATE TABLE subscriptions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id     uuid NOT NULL REFERENCES customers(user_id),
  plan_id         uuid NOT NULL REFERENCES subscription_plans(id),
  status          sub_status NOT NULL DEFAULT 'active',
  slot            meal_slot NOT NULL,
  delivery_window tstzrange,
  address_id      uuid NOT NULL REFERENCES addresses(id),
  preferred_kitchen_id uuid REFERENCES kitchens(id),  -- Gold and Platinum
  meals_total     int NOT NULL,
  meals_done      int NOT NULL DEFAULT 0,
  skips_used      int NOT NULL DEFAULT 0,
  pauses_used     int NOT NULL DEFAULT 0,
  date_changes_used int NOT NULL DEFAULT 0,
  starts_on       date NOT NULL,
  expires_on      date NOT NULL,                      -- pushed out when a meal is skipped
  premium_kitchen_dish_id uuid REFERENCES kitchen_dishes(id),  -- Platinum
  customisation   jsonb NOT NULL DEFAULT '{}',        -- validated against kitchens.capabilities
  CHECK (meals_done <= meals_total)
);
CREATE INDEX subscriptions_customer_idx ON subscriptions (customer_id, status);
CREATE INDEX subscriptions_active_slot_idx ON subscriptions (slot, status) WHERE status='active';

CREATE TABLE subscription_menu_prefs (               -- Gold "my preferred menu": tick / cross per kitchen dish
  subscription_id uuid REFERENCES subscriptions(id) ON DELETE CASCADE,
  kitchen_dish_id uuid REFERENCES kitchen_dishes(id),
  pref            text NOT NULL CHECK (pref IN ('want','skip')),
  PRIMARY KEY (subscription_id, kitchen_dish_id)
);

CREATE TABLE subscription_meals (                    -- each planned delivery of a subscription
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subscription_id uuid NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
  service_date    date NOT NULL,
  kitchen_id      uuid REFERENCES kitchens(id),       -- one kitchen per delivery; chosen by the planner
  state           meal_state NOT NULL DEFAULT 'planned',
  plan_notes      jsonb NOT NULL DEFAULT '[]',        -- substitutions and reasons shown to the customer
  order_id        uuid,
  UNIQUE (subscription_id, service_date)
);
CREATE INDEX subscription_meals_day_idx ON subscription_meals (service_date, kitchen_id, state);
CREATE TABLE subscription_meal_items (
  meal_id         uuid REFERENCES subscription_meals(id) ON DELETE CASCADE,
  kitchen_dish_id uuid REFERENCES kitchen_dishes(id),
  PRIMARY KEY (meal_id, kitchen_dish_id)
);

-- ------------------------------------------------------------------ orders
CREATE TABLE orders (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id       text UNIQUE NOT NULL,               -- HE-1234
  kind            order_kind NOT NULL,
  customer_id     uuid NOT NULL REFERENCES customers(user_id),
  kitchen_id      uuid NOT NULL REFERENCES kitchens(id),
  address_id      uuid NOT NULL REFERENCES addresses(id),
  status          order_status NOT NULL DEFAULT 'confirmed',
  service_date    date NOT NULL,
  slot            meal_slot NOT NULL,
  capacity_units  numeric(5,1) NOT NULL,              -- sum over order_lines: full = 1.0, half = 0.5, times qty
  subtotal_paise  int NOT NULL,
  delivery_fee_paise int NOT NULL DEFAULT 0,
  total_paise     int NOT NULL,
  commission_paise int NOT NULL,                      -- snapshot of the kitchen rate at order time
  distance_m      int NOT NULL,
  promised_eta_min int NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now()
  -- The service radius is enforced inside the order-placement transaction (eligible_kitchens()),
  -- so a modified client cannot order from a kitchen outside range.
);
CREATE INDEX orders_kitchen_day_idx  ON orders (kitchen_id, service_date, status);
CREATE INDEX orders_customer_idx     ON orders (customer_id, created_at DESC);
ALTER TABLE subscription_meals ADD FOREIGN KEY (order_id) REFERENCES orders(id);

CREATE TABLE order_lines (                           -- what the customer chose: one row per dish and size in the cart
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id        uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  kitchen_dish_id uuid NOT NULL REFERENCES kitchen_dishes(id),
  size            tiffin_size NOT NULL,
  qty             int NOT NULL CHECK (qty BETWEEN 1 AND 10),
  unit_price_paise int NOT NULL,
  UNIQUE (order_id, kitchen_dish_id, size)
);
-- A cart is one kitchen and one delivery. The API rejects lines from a second kitchen, and reserves
-- capacity for the whole order in a single atomic statement (see kitchen_capacities).

-- order_items = what is packed (the chosen mains plus dal, roti, rice quantities). order_lines = what was chosen.
CREATE TABLE order_items (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id        uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  kitchen_dish_id uuid NOT NULL REFERENCES kitchen_dishes(id),
  role            text NOT NULL CHECK (role IN ('main','dal','bread','rice','side')),
  qty             int NOT NULL DEFAULT 1,
  unit_price_paise int NOT NULL
);
CREATE INDEX order_items_order_idx ON order_items (order_id);
CREATE INDEX order_items_dish_idx  ON order_items (kitchen_dish_id);

CREATE TABLE order_status_events (                   -- append-only audit trail, powers live tracking
  id              bigserial PRIMARY KEY,
  order_id        uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  status          order_status NOT NULL,
  actor_user_id   uuid REFERENCES users(id),
  at              timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX order_status_events_order_idx ON order_status_events (order_id, at);

CREATE TABLE delivery_assignments (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id        uuid NOT NULL UNIQUE REFERENCES orders(id) ON DELETE CASCADE,
  partner_id      uuid NOT NULL REFERENCES delivery_partners(user_id),
  assigned_at     timestamptz NOT NULL DEFAULT now(),
  picked_up_at    timestamptz,
  delivered_at    timestamptz,
  payout_paise    int NOT NULL
);
CREATE INDEX delivery_assignments_partner_idx ON delivery_assignments (partner_id, assigned_at DESC);

-- ------------------------------------------------------------------ payments
CREATE TABLE payments (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id     uuid NOT NULL REFERENCES customers(user_id),
  order_id        uuid REFERENCES orders(id),
  subscription_id uuid REFERENCES subscriptions(id),
  amount_paise    int NOT NULL CHECK (amount_paise >= 0),
  method          text NOT NULL,                       -- upi, card, cod
  provider_ref    text,                                -- token/intent id from the gateway. No card numbers, ever.
  status          pay_status NOT NULL DEFAULT 'pending',
  idempotency_key text NOT NULL UNIQUE,
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (order_id IS NOT NULL OR subscription_id IS NOT NULL)
);

-- ------------------------------------------------------------------ taste, favourites, ratings
CREATE TABLE favourite_dishes (                      -- MY TASTE
  customer_id     uuid REFERENCES customers(user_id) ON DELETE CASCADE,
  kitchen_dish_id uuid REFERENCES kitchen_dishes(id) ON DELETE CASCADE,   -- kitchen + dish, never the bare dish name
  my_rating       smallint CHECK (my_rating BETWEEN 1 AND 5),
  times_ordered   int NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (customer_id, kitchen_dish_id)
);
CREATE INDEX favourite_dishes_dish_idx ON favourite_dishes (kitchen_dish_id);   -- "how many customers starred this" for kitchens

CREATE TABLE favourite_kitchens (
  customer_id     uuid REFERENCES customers(user_id) ON DELETE CASCADE,
  kitchen_id      uuid REFERENCES kitchens(id) ON DELETE CASCADE,
  PRIMARY KEY (customer_id, kitchen_id)
);

CREATE TABLE ratings (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id        uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  customer_id     uuid NOT NULL REFERENCES customers(user_id),
  target          text NOT NULL CHECK (target IN ('order','kitchen','dish')),
  kitchen_id      uuid REFERENCES kitchens(id),
  kitchen_dish_id uuid REFERENCES kitchen_dishes(id),
  stars           smallint NOT NULL CHECK (stars BETWEEN 1 AND 5),
  created_at      timestamptz NOT NULL DEFAULT now(),
  CHECK ((target='dish') = (kitchen_dish_id IS NOT NULL)),
  UNIQUE NULLS NOT DISTINCT (order_id, target, kitchen_dish_id)      -- one rating per order and target, only after delivery
);

-- ------------------------------------------------------------------ demand planning
CREATE TABLE demand_snapshots (                      -- CONFIRMED demand. Recomputed as orders and meals change.
  kitchen_id      uuid REFERENCES kitchens(id) ON DELETE CASCADE,
  service_date    date,
  slot            meal_slot,
  kitchen_dish_id uuid REFERENCES kitchen_dishes(id),
  confirmed_servings int NOT NULL DEFAULT 0,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (kitchen_id, service_date, slot, kitchen_dish_id)
);
CREATE TABLE demand_forecasts (                      -- ESTIMATED demand. Stored apart from confirmed so they can never be mixed up.
  kitchen_id      uuid REFERENCES kitchens(id) ON DELETE CASCADE,
  service_date    date,
  slot            meal_slot,
  kitchen_dish_id uuid REFERENCES kitchen_dishes(id),
  est_low         int NOT NULL,
  est_high        int NOT NULL,
  model_version   text NOT NULL,
  generated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (kitchen_id, service_date, slot, kitchen_dish_id, model_version),
  CHECK (est_low <= est_high)
);

-- ------------------------------------------------------------------ notifications and admin
CREATE TABLE notifications (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind            text NOT NULL,
  body            text NOT NULL,
  payload         jsonb NOT NULL DEFAULT '{}',
  read_at         timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX notifications_user_idx ON notifications (user_id, created_at DESC);

CREATE TABLE service_areas (                         -- the 20 km rule is data, not code
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name            text NOT NULL,
  boundary        geography(MultiPolygon,4326),
  max_radius_m    int NOT NULL DEFAULT 20000 CHECK (max_radius_m BETWEEN 1000 AND 50000),
  active          boolean NOT NULL DEFAULT true
);
CREATE TABLE commission_rules (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kitchen_id      uuid REFERENCES kitchens(id),        -- null = platform default
  bps             int NOT NULL CHECK (bps BETWEEN 0 AND 4000),
  effective_from  date NOT NULL
);
CREATE TABLE refunds (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id      uuid NOT NULL REFERENCES payments(id),
  order_id        uuid REFERENCES orders(id),
  amount_paise    int NOT NULL CHECK (amount_paise > 0),
  reason          text NOT NULL,
  state           text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','approved','rejected','paid_out')),
  decided_by      uuid REFERENCES users(id)
);
CREATE TABLE complaints (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id     uuid NOT NULL REFERENCES customers(user_id),
  order_id        uuid REFERENCES orders(id),
  kitchen_id      uuid REFERENCES kitchens(id),
  partner_id      uuid REFERENCES delivery_partners(user_id),
  body            text NOT NULL,
  state           text NOT NULL DEFAULT 'open' CHECK (state IN ('open','resolved')),
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE promotions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code            text UNIQUE NOT NULL,
  description     text NOT NULL,
  discount_bps    int,
  flat_paise      int,
  starts_at       timestamptz NOT NULL,
  ends_at         timestamptz NOT NULL,
  active          boolean NOT NULL DEFAULT true
);

-- ------------------------------------------------------------------ roles and partner applications
-- A person can hold several roles (a kitchen owner can also order food). Roles are GRANTED by the system,
-- never self-assigned: the only path to KITCHEN_PARTNER or DELIVERY_PARTNER is an approved application.
-- Admin accounts are created by staff onboarding, not by the public apps.
CREATE TABLE user_roles (
  user_id         uuid REFERENCES users(id) ON DELETE CASCADE,
  role            user_role NOT NULL,                 -- customer, kitchen_owner, delivery_partner, admin
  granted_by      uuid REFERENCES users(id),
  granted_at      timestamptz NOT NULL DEFAULT now(),
  revoked_at      timestamptz,
  PRIMARY KEY (user_id, role)
);
CREATE TYPE application_type   AS ENUM ('kitchen','delivery');
CREATE TYPE application_status AS ENUM ('submitted','under_review','more_info','approved','rejected');

CREATE TABLE partner_applications (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  public_id       text UNIQUE NOT NULL,               -- KA-1234 / DA-1234
  type            application_type NOT NULL,
  applicant_id    uuid NOT NULL REFERENCES users(id),
  status          application_status NOT NULL DEFAULT 'submitted',
  form            jsonb NOT NULL,                     -- the submitted answers (kitchen name, dishes, capacity, hours, vehicle ...)
  location        geography(Point,4326),
  bank_last4      text,                               -- full account number goes to the payment provider, never here
  bank_token      text,
  verified_docs     boolean NOT NULL DEFAULT false,   -- admin checklist; approval requires all three
  verified_location boolean NOT NULL DEFAULT false,
  verified_contact  boolean NOT NULL DEFAULT false,
  decision_note   text,                               -- rejection reason or the information requested
  reviewed_by     uuid REFERENCES users(id),
  submitted_at    timestamptz NOT NULL DEFAULT now(),
  decided_at      timestamptz,
  created_kitchen_id uuid REFERENCES kitchens(id),    -- set on approval of a kitchen application
  CHECK (status <> 'approved' OR (verified_docs AND verified_location AND verified_contact))
);
-- One live application per person and type.
CREATE UNIQUE INDEX partner_app_one_open ON partner_applications (applicant_id, type)
  WHERE status IN ('submitted','under_review','more_info','approved');
CREATE INDEX partner_app_queue_idx ON partner_applications (type, status, submitted_at);

CREATE TABLE application_documents (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  application_id  uuid NOT NULL REFERENCES partner_applications(id) ON DELETE CASCADE,
  kind            text NOT NULL,                      -- fssai, id_proof, address_proof, kitchen_photo, driving_licence, rc, profile_photo
  storage_key     text NOT NULL,                      -- private object storage; opened only through short-lived signed links
  verified        boolean NOT NULL DEFAULT false
);
CREATE TABLE application_events (                     -- append-only: who did what and when
  id              bigserial PRIMARY KEY,
  application_id  uuid NOT NULL REFERENCES partner_applications(id) ON DELETE CASCADE,
  status          application_status NOT NULL,
  actor_user_id   uuid REFERENCES users(id),
  note            text,
  at              timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE partner_applications ENABLE ROW LEVEL SECURITY;
CREATE POLICY apps_applicant ON partner_applications FOR SELECT USING (applicant_id = app_uid());
CREATE POLICY apps_insert    ON partner_applications FOR INSERT WITH CHECK (applicant_id = app_uid() AND status = 'submitted');
CREATE POLICY apps_admin     ON partner_applications FOR ALL    USING (app_role() = 'admin');
-- Approval runs in one transaction inside the admin API: create kitchen (or delivery_partners row),
-- insert the user_roles grant, write application_events, notify the applicant. Applicants can never write status.

-- ------------------------------------------------------------------ partner document requirements (admin-controlled)
-- Every document is OPTIONAL by default. An admin switches a document to mandatory, now or from a date.
CREATE TABLE document_requirements (
  partner_type    application_type NOT NULL,          -- kitchen | delivery
  doc_key         text NOT NULL,                      -- fssai, aadhaar, pan, driving_licence, rc, insurance, police, photo, bank, ...
  label           text NOT NULL,
  help_text       text,
  applies_to      text NOT NULL DEFAULT 'all' CHECK (applies_to IN ('all','motor_vehicle')),
  min_files       int NOT NULL DEFAULT 1,
  required        boolean NOT NULL DEFAULT false,     -- false = optional (the default)
  required_from   date,                               -- null while required: mandatory immediately
  updated_by      uuid REFERENCES users(id),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (partner_type, doc_key),
  CHECK (required OR required_from IS NULL)
);
CREATE TABLE document_requirement_history (           -- append-only audit of every change
  id              bigserial PRIMARY KEY,
  partner_type    application_type NOT NULL,
  doc_key         text NOT NULL,
  required        boolean NOT NULL,
  required_from   date,
  changed_by      uuid NOT NULL REFERENCES users(id),
  changed_at      timestamptz NOT NULL DEFAULT now()
);
-- A document counts as mandatory when: required AND (required_from IS NULL OR required_from <= current_date).
-- Each application stores which documents were mandatory when it was submitted (form.requirement_snapshot),
-- so later rule changes never make an old application "invalid".
ALTER TABLE document_requirements ENABLE ROW LEVEL SECURITY;
CREATE POLICY docreq_read  ON document_requirements FOR SELECT USING (true);               -- applicants need to see the rules
CREATE POLICY docreq_admin ON document_requirements FOR ALL    USING (app_role() = 'admin');

-- ------------------------------------------------------------------ eligible kitchens: the 20 km rule
-- Every customer-facing kitchen query goes through this function.
CREATE OR REPLACE FUNCTION eligible_kitchens(p_geo geography, p_radius_m int DEFAULT 20000)
RETURNS TABLE (kitchen_id uuid, distance_m int) LANGUAGE sql STABLE AS $$
  SELECT k.id, ST_Distance(kl.geo, p_geo)::int
  FROM kitchens k JOIN kitchen_locations kl ON kl.kitchen_id = k.id
  WHERE k.status = 'active' AND ST_DWithin(kl.geo, p_geo, p_radius_m)
  ORDER BY kl.geo <-> p_geo;
$$;

-- ------------------------------------------------------------------ row level security
-- The API sets these per request after verifying the JWT:
--   SET LOCAL app.user_id = '<uuid>'; SET LOCAL app.role = 'customer'; SET LOCAL app.kitchen_id = '<uuid or empty>';
CREATE FUNCTION app_uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.user_id', true),'')::uuid $$;
CREATE FUNCTION app_role() RETURNS text LANGUAGE sql STABLE AS $$ SELECT current_setting('app.role', true) $$;
CREATE FUNCTION app_kitchen() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.kitchen_id', true),'')::uuid $$;

ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY orders_customer ON orders FOR SELECT USING (app_role()='customer' AND customer_id = app_uid());
CREATE POLICY orders_kitchen  ON orders FOR SELECT USING (app_role() IN ('kitchen_owner','kitchen_staff') AND kitchen_id = app_kitchen());
CREATE POLICY orders_delivery ON orders FOR SELECT USING (app_role()='delivery_partner' AND (
  status='ready' OR EXISTS (SELECT 1 FROM delivery_assignments d WHERE d.order_id = orders.id AND d.partner_id = app_uid())));
CREATE POLICY orders_admin    ON orders FOR ALL    USING (app_role() IN ('admin','support'));

ALTER TABLE addresses ENABLE ROW LEVEL SECURITY;
CREATE POLICY addresses_owner ON addresses FOR ALL USING (app_role()='customer' AND customer_id = app_uid());
-- Delivery partners and kitchens read addresses only through a view that returns `area` before assignment
-- and the full line and point after assignment (see delivery_order_view in the API layer).

ALTER TABLE favourite_dishes ENABLE ROW LEVEL SECURITY;
CREATE POLICY fav_owner ON favourite_dishes FOR ALL USING (customer_id = app_uid());
-- Kitchens get only aggregate counts of favourites, via a SECURITY DEFINER function returning counts per kitchen_dish_id.

ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;
CREATE POLICY subs_owner ON subscriptions FOR ALL USING (app_role()='customer' AND customer_id = app_uid());
CREATE POLICY subs_admin ON subscriptions FOR SELECT USING (app_role() IN ('admin','support'));

ALTER TABLE payments ENABLE ROW LEVEL SECURITY;
CREATE POLICY pay_owner ON payments FOR SELECT USING (app_role()='customer' AND customer_id = app_uid());
CREATE POLICY pay_admin ON payments FOR ALL    USING (app_role()='admin');

ALTER TABLE menus ENABLE ROW LEVEL SECURITY;
CREATE POLICY menus_kitchen_write ON menus FOR ALL USING (kitchen_id = app_kitchen() AND locked_at IS NULL);
CREATE POLICY menus_read ON menus FOR SELECT USING (true);          -- menus are public; personal data is not in them
