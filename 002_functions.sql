-- =====================================================================
-- Highway Eat: server-side functions. Run after 001_schema.sql.
-- Every important rule is enforced HERE (capacity, radius, prices, who may change an order status),
-- never trusted from the browser. Browsers call these through supabase.rpc().
-- =====================================================================

-- ---------- internal helpers (not callable from the browser) ----------
create or replace function public.notify_user(p_user uuid, p_title text, p_body text, p_kind text default 'account')
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.notifications (user_id, title, body, kind) values (p_user, p_title, p_body, p_kind);
end $$;

create or replace function public.log_activity(p_action text, p_entity text, p_entity_id text, p_meta jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.activity_log (actor_id, action, entity, entity_id, meta) values (auth.uid(), p_action, p_entity, p_entity_id, coalesce(p_meta, '{}'));
end $$;

create or replace function public.short_name(p_name text) returns text
language sql immutable as $$
  select split_part(p_name, ' ', 1) ||
         case when split_part(p_name, ' ', 2) <> '' then ' ' || left(split_part(p_name, ' ', 2), 1) || '.' else '' end
$$;

-- ---------- ORDERS ----------
create or replace function public.place_order(
  p_kitchen uuid, p_lines jsonb, p_address jsonb, p_pay text default 'cod', p_id uuid default gen_random_uuid())
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  k public.kitchens%rowtype;
  kd public.kitchen_dishes%rowtype;
  r record;
  v_lat double precision; v_lng double precision; v_radius double precision; v_dist double precision;
  v_units numeric := 0; v_total int := 0; v_price int;
  v_name text; v_phone text; v_public text; v_pay text;
begin
  if v_uid is null then raise exception 'Please log in first'; end if;
  if not public.has_role('customer') then raise exception 'Only customers can place orders'; end if;
  select * into k from public.kitchens where id = p_kitchen and status = 'active';
  if not found then raise exception 'This kitchen is not available'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Your cart is empty';
  end if;

  v_lat := nullif(p_address ->> 'lat', '')::double precision;
  v_lng := nullif(p_address ->> 'lng', '')::double precision;
  if v_lat is null or v_lng is null then raise exception 'We need a delivery location'; end if;
  select coalesce((select (value #>> '{}')::double precision from public.app_settings where key = 'service_radius_km'), 20) into v_radius;
  v_dist := public.haversine_km(k.lat, k.lng, v_lat, v_lng);
  if v_dist > v_radius then
    raise exception 'This address is outside the % km service area', v_radius;
  end if;

  -- price and size every line from the kitchen's own menu (the browser's prices are never trusted)
  for r in
    select x.did, x.size, sum(x.qty)::int as qty
    from jsonb_to_recordset(p_lines) as x(did text, size text, qty int)
    group by x.did, x.size
  loop
    if r.size is null or r.size not in ('half', 'full') then raise exception 'Choose half or full tiffin'; end if;
    if r.qty is null or r.qty < 1 or r.qty > 10 then raise exception 'Quantity must be between 1 and 10'; end if;
    select * into kd from public.kitchen_dishes where kitchen_id = p_kitchen and dish_key = r.did and is_active;
    if not found then raise exception 'This kitchen does not make %', r.did; end if;
    if kd.status = 'unavailable' then raise exception '% is not available today', r.did; end if;
    v_price := case when r.size = 'half' then kd.price_half else kd.price_full end;
    v_total := v_total + v_price * r.qty;
    v_units := v_units + (case when r.size = 'half' then 0.5 else 1 end) * r.qty;
  end loop;
  if v_units = 0 then raise exception 'Your cart is empty'; end if;

  -- reserve capacity atomically: zero rows updated means the kitchen is full
  insert into public.kitchen_capacity (kitchen_id, service_date, capacity, used)
  values (p_kitchen, public.today_ist(), k.default_capacity, 0)
  on conflict (kitchen_id, service_date) do nothing;
  update public.kitchen_capacity set used = used + v_units
  where kitchen_id = p_kitchen and service_date = public.today_ist() and capacity - used >= v_units;
  if not found then raise exception 'Not enough capacity left at this kitchen today'; end if;

  select full_name, phone into v_name, v_phone from public.profiles where id = v_uid;
  v_public := 'HE-' || upper(substr(replace(p_id::text, '-', ''), 1, 6));
  v_pay := case when p_pay in ('cod', 'upi') then p_pay else 'cod' end;

  insert into public.orders (id, public_id, customer_id, customer_label, kitchen_id, address_area, distance_km, eta_min,
                             units, subtotal, total, commission, payment_method)
  values (p_id, v_public, v_uid, public.short_name(v_name), p_kitchen, coalesce(nullif(p_address ->> 'area', ''), 'Your area'),
          round(v_dist::numeric, 2), k.avg_prep_min + round(v_dist * 3)::int, v_units, v_total, v_total,
          round(v_total * k.commission_pct / 100.0)::int, v_pay);

  insert into public.order_private (order_id, customer_name, phone, address_text, lat, lng)
  values (p_id, v_name, v_phone, coalesce(p_address ->> 'text', ''), v_lat, v_lng);

  for r in
    select x.did, x.size, sum(x.qty)::int as qty
    from jsonb_to_recordset(p_lines) as x(did text, size text, qty int)
    group by x.did, x.size
  loop
    select * into kd from public.kitchen_dishes where kitchen_id = p_kitchen and dish_key = r.did;
    insert into public.order_lines (order_id, dish_key, size, qty, unit_price)
    values (p_id, r.did, r.size, r.qty, case when r.size = 'half' then kd.price_half else kd.price_full end);
  end loop;

  -- what gets packed: the chosen mains, plus the kitchen's best dal, roti and rice
  insert into public.order_items (order_id, dish_key, role, qty)
  select p_id, dish_key, 'main', sum(qty)::int from public.order_lines where order_id = p_id group by dish_key;
  insert into public.order_items (order_id, dish_key, role, qty)
  select p_id, s.dish_key, s.category,
         case when s.category = 'bread' then t.rotis else t.n end
  from (select coalesce(sum(qty), 0)::int as n,
               coalesce(sum(qty * case when size = 'half' then 2 else 4 end), 0)::int as rotis
        from public.order_lines where order_id = p_id) t,
       (select distinct on (d.category) k2.dish_key, d.category
        from public.kitchen_dishes k2 join public.dishes d on d.key = k2.dish_key
        where k2.kitchen_id = p_kitchen and k2.is_active and k2.status <> 'unavailable'
          and d.category in ('dal', 'bread', 'rice')
        order by d.category, k2.rating_avg desc, k2.dish_key) s
  where not exists (select 1 from public.order_lines l where l.order_id = p_id and l.dish_key = s.dish_key);

  insert into public.order_status_events (order_id, status, actor_id) values (p_id, 'confirmed', v_uid);
  perform public.notify_user(k.owner_id, 'New order ' || v_public, 'Total ' || v_total || ' rupees. Open Today to accept it.', 'orders');
  perform public.log_activity('order.placed', 'order', v_public, jsonb_build_object('kitchen', p_kitchen, 'total', v_total, 'units', v_units));
  return p_id;
end $$;

create or replace function public.order_advance(p_order uuid, p_action text) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  o public.orders%rowtype;
  v_who text; v_from text; v_to text; v_pname text; v_online boolean; v_payout int;
begin
  if v_uid is null then raise exception 'Please log in first'; end if;
  perform set_config('app.system', '1', true);
  select * into o from public.orders where id = p_order for update;
  if not found then raise exception 'Order not found'; end if;

  if    p_action = 'accept'  then v_who := 'kitchen'; v_from := 'confirmed'; v_to := 'accepted';
  elsif p_action = 'prepare' then v_who := 'kitchen'; v_from := 'accepted';  v_to := 'preparing';
  elsif p_action = 'ready'   then v_who := 'kitchen'; v_from := 'preparing'; v_to := 'ready';
  elsif p_action = 'claim'   then v_who := 'rider';   v_from := 'ready';     v_to := 'assigned';
  elsif p_action = 'pickup'  then v_who := 'rider';   v_from := 'assigned';  v_to := 'picked';
  elsif p_action = 'go'      then v_who := 'rider';   v_from := 'picked';    v_to := 'out';
  elsif p_action = 'deliver' then v_who := 'rider';   v_from := 'out';       v_to := 'delivered';
  else raise exception 'Unknown action';
  end if;

  if v_who = 'kitchen' then
    if not public.owns_kitchen(o.kitchen_id) then raise exception 'This is not your order'; end if;
  else
    if not public.has_role('delivery_partner') then raise exception 'Only delivery partners can do this'; end if;
    if p_action <> 'claim' and not public.is_assigned_rider(o.id) then raise exception 'This is not your delivery'; end if;
  end if;
  if o.status <> v_from then raise exception 'The order is "%" now, so that cannot be done', o.status; end if;

  if p_action = 'claim' then
    select display_name, online into v_pname, v_online from public.delivery_partners where user_id = v_uid;
    if not found or not v_online then raise exception 'Go online first'; end if;
    v_payout := 25 + round(6 * o.distance_km)::int;
    insert into public.delivery_assignments (order_id, partner_id, partner_name, payout) values (o.id, v_uid, v_pname, v_payout);
  elsif p_action = 'pickup' then
    update public.delivery_assignments set picked_at = now() where order_id = o.id;
  elsif p_action = 'deliver' then
    update public.delivery_assignments set delivered_at = now() where order_id = o.id returning payout into v_payout;
    update public.delivery_partners set earned_total = earned_total + coalesce(v_payout, 0), deliveries = deliveries + 1 where user_id = v_uid;
    update public.kitchen_dishes kd set times_ordered = kd.times_ordered + l.q
      from (select dish_key, sum(qty)::int as q from public.order_lines where order_id = o.id group by dish_key) l
      where kd.kitchen_id = o.kitchen_id and kd.dish_key = l.dish_key;
    update public.favourites f set times_ordered = f.times_ordered + 1
      from public.kitchen_dishes kd
      where f.kitchen_dish_id = kd.id and kd.kitchen_id = o.kitchen_id and f.customer_id = o.customer_id
        and kd.dish_key in (select dish_key from public.order_lines where order_id = o.id);
    update public.orders set payment_status = 'paid' where id = o.id and payment_method = 'cod';
  end if;

  update public.orders set status = v_to, updated_at = now() where id = o.id;
  insert into public.order_status_events (order_id, status, actor_id) values (o.id, v_to, v_uid);

  if v_to = 'accepted'  then perform public.notify_user(o.customer_id, o.public_id || ': Kitchen accepted', 'Your tiffin is being prepared.', 'orders'); end if;
  if v_to = 'assigned'  then perform public.notify_user(o.customer_id, o.public_id || ': Delivery partner assigned', 'A partner is on the way to collect your tiffin.', 'orders'); end if;
  if v_to = 'out'       then perform public.notify_user(o.customer_id, o.public_id || ': Out for delivery', 'Your tiffin is on its way.', 'orders'); end if;
  if v_to = 'delivered' then perform public.notify_user(o.customer_id, o.public_id || ': Delivered', 'Please rate your tiffin.', 'orders'); end if;
  perform public.log_activity('order.' || p_action, 'order', o.public_id, jsonb_build_object('to', v_to));
  return v_to;
end $$;

create or replace function public.order_cancel(p_order uuid) returns void
language plpgsql security definer set search_path = public as $$
declare o public.orders%rowtype; v_owner uuid;
begin
  select * into o from public.orders where id = p_order and customer_id = auth.uid() for update;
  if not found then raise exception 'Not permitted'; end if;
  if o.status <> 'confirmed' then raise exception 'The kitchen has already accepted this order'; end if;
  update public.orders set status = 'cancelled', updated_at = now() where id = o.id;
  update public.kitchen_capacity set used = greatest(0, used - o.units)
   where kitchen_id = o.kitchen_id and service_date = (o.created_at at time zone 'Asia/Kolkata')::date;
  insert into public.order_status_events (order_id, status, actor_id) values (o.id, 'cancelled', auth.uid());
  select owner_id into v_owner from public.kitchens where id = o.kitchen_id;
  perform public.notify_user(v_owner, o.public_id || ' was cancelled', 'The customer cancelled before you accepted.', 'orders');
  perform public.log_activity('order.cancelled', 'order', o.public_id);
end $$;

create or replace function public.order_rate(p_order uuid, p_overall int, p_kitchen int default null, p_dishes jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
declare o public.orders%rowtype; d record; v_kd uuid; v_stars int;
begin
  perform set_config('app.system', '1', true);
  select * into o from public.orders where id = p_order and customer_id = auth.uid() for update;
  if not found then raise exception 'Not permitted'; end if;
  if o.status <> 'delivered' then raise exception 'You can rate after delivery'; end if;
  if o.rated then raise exception 'This order is already rated'; end if;
  if p_overall is null or p_overall not between 1 and 5 then raise exception 'Give an overall rating from 1 to 5'; end if;
  insert into public.ratings (order_id, customer_id, target, stars) values (o.id, auth.uid(), 'order', p_overall);
  if p_kitchen between 1 and 5 then
    insert into public.ratings (order_id, customer_id, target, stars) values (o.id, auth.uid(), 'kitchen', p_kitchen);
    update public.kitchens set rating_avg = round(((rating_avg * rating_count) + p_kitchen) / (rating_count + 1), 2), rating_count = rating_count + 1
     where id = o.kitchen_id;
  end if;
  for d in select key, value from jsonb_each_text(coalesce(p_dishes, '{}'::jsonb)) loop
    v_stars := nullif(d.value, '')::int;
    if v_stars between 1 and 5 then
      select id into v_kd from public.kitchen_dishes where kitchen_id = o.kitchen_id and dish_key = d.key;
      if v_kd is not null then
        insert into public.ratings (order_id, customer_id, target, kitchen_dish_id, stars) values (o.id, auth.uid(), 'dish', v_kd, v_stars);
        update public.kitchen_dishes set rating_avg = round(((rating_avg * rating_count) + v_stars) / (rating_count + 1), 2), rating_count = rating_count + 1
         where id = v_kd;
        update public.favourites set my_rating = v_stars where customer_id = auth.uid() and kitchen_dish_id = v_kd;
      end if;
    end if;
  end loop;
  update public.orders set rated = true where id = o.id;
end $$;

-- ---------- MY TASTE ----------
create or replace function public.toggle_favourite(p_kd uuid) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Please log in first'; end if;
  if not exists (select 1 from public.kitchen_dishes where id = p_kd) then raise exception 'Dish not found'; end if;
  if exists (select 1 from public.favourites where customer_id = auth.uid() and kitchen_dish_id = p_kd) then
    delete from public.favourites where customer_id = auth.uid() and kitchen_dish_id = p_kd;
    return false;
  end if;
  insert into public.favourites (customer_id, kitchen_dish_id) values (auth.uid(), p_kd);
  return true;
end $$;

create or replace function public.set_favourite_rating(p_kd uuid, p_stars int) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_stars not between 1 and 5 then raise exception 'Rating must be 1 to 5'; end if;
  update public.favourites set my_rating = p_stars where customer_id = auth.uid() and kitchen_dish_id = p_kd;
end $$;

-- ---------- PARTNER APPLICATIONS ----------
create or replace function public.submit_application(p_type text, p_form jsonb, p_docs jsonb default '[]')
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_id uuid := gen_random_uuid(); v_pub text;
  req record; v_n int; v_motor boolean; v_snap jsonb := '{}'; v_mand boolean; v_fssai text; dk text;
  v_main boolean := false;
begin
  if v_uid is null then raise exception 'Please log in first'; end if;
  if p_type not in ('kitchen', 'delivery') then raise exception 'Unknown application type'; end if;
  if exists (select 1 from public.partner_applications
             where applicant_id = v_uid and type = p_type and status in ('submitted', 'under_review', 'more_info', 'approved')) then
    raise exception 'You already have an application in progress';
  end if;
  if coalesce(trim(p_form ->> 'name'), '') = '' then raise exception 'Enter your name'; end if;
  if regexp_replace(coalesce(p_form ->> 'phone', ''), '\D', '', 'g') !~ '^\d{10}$' then raise exception 'Enter a 10-digit mobile number'; end if;
  if coalesce(p_form ->> 'email', '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a valid email address'; end if;
  if nullif(p_form ->> 'lat', '') is null or nullif(p_form ->> 'lng', '') is null then raise exception 'Choose a location'; end if;

  if p_type = 'kitchen' then
    if coalesce(trim(p_form ->> 'kitchenName'), '') = '' then raise exception 'Enter your kitchen name'; end if;
    if coalesce(trim(p_form ->> 'address'), '') = '' then raise exception 'Enter the kitchen address'; end if;
    if coalesce(p_form ->> 'diet', '') not in ('veg', 'both') then raise exception 'Choose veg or non-veg'; end if;
    if jsonb_typeof(p_form -> 'dishes') <> 'array' or jsonb_array_length(p_form -> 'dishes') = 0 then raise exception 'Choose at least one dish'; end if;
    for dk in select jsonb_array_elements_text(p_form -> 'dishes') loop
      if not exists (select 1 from public.dishes where key = dk) then raise exception 'Unknown dish %', dk; end if;
      if exists (select 1 from public.dishes where key = dk and category in ('sabzi', 'protein', 'premium')) then v_main := true; end if;
    end loop;
    if not v_main then raise exception 'Include at least one main dish such as a sabzi or protein'; end if;
    if coalesce((p_form ->> 'capacity')::numeric, 0) not between 1 and 500 then raise exception 'Capacity must be between 1 and 500'; end if;
    v_fssai := regexp_replace(coalesce(p_form ->> 'fssaiNo', ''), '\s', '', 'g');
    if v_fssai <> '' and v_fssai !~ '^\d{14}$' then raise exception 'An FSSAI licence number has 14 digits'; end if;
  else
    if coalesce(p_form ->> 'vehicle', '') not in ('Bicycle', 'Bike', 'Scooter', 'Electric scooter') then raise exception 'Choose a vehicle type'; end if;
  end if;
  v_motor := p_type = 'delivery' and coalesce(p_form ->> 'vehicle', '') <> 'Bicycle';

  -- documents are optional unless an admin has made them mandatory
  for req in select * from public.document_requirements where partner_type = p_type loop
    v_mand := req.required and (req.required_from is null or req.required_from <= public.today_ist());
    v_snap := v_snap || jsonb_build_object(req.doc_key, v_mand);
    if v_mand and (req.applies_to = 'all' or v_motor) then
      select count(*) into v_n from jsonb_to_recordset(p_docs) as x(key text, name text, path text) where x.key = req.doc_key;
      if v_n < req.min_files then raise exception 'Please upload: %', req.label; end if;
      if req.doc_key = 'fssai' and p_type = 'kitchen' and v_fssai = '' then raise exception 'Enter the FSSAI licence number'; end if;
    end if;
  end loop;
  if exists (select 1 from jsonb_to_recordset(p_docs) as x(key text, name text, path text)
             where x.path is null or x.path not like v_uid::text || '/%') then
    raise exception 'Invalid document upload';
  end if;

  v_pub := case when p_type = 'kitchen' then 'KA-' else 'DA-' end || upper(substr(replace(v_id::text, '-', ''), 1, 6));
  insert into public.partner_applications (id, public_id, type, applicant_id, form, req_snapshot)
  values (v_id, v_pub, p_type, v_uid, p_form, v_snap);
  insert into public.application_documents (application_id, doc_key, file_name, storage_path)
  select v_id, x.key, x.name, x.path from jsonb_to_recordset(p_docs) as x(key text, name text, path text);
  insert into public.application_events (application_id, status, actor_id) values (v_id, 'submitted', v_uid);
  perform public.notify_user(v_uid, 'Application submitted',
    'We received your ' || p_type || ' partner application (' || v_pub || '). You will not get partner access until it is verified.', 'account');
  perform public.log_activity('application.submitted', 'application', v_pub, jsonb_build_object('type', p_type));
  return v_id;
end $$;

create or replace function public.review_application(p_id uuid, p_action text, p_text text default null, p_key text default null)
returns text language plpgsql security definer set search_path = public as $$
declare
  a public.partner_applications%rowtype; v_uid uuid := auth.uid(); v_k uuid; v_name text;
begin
  if not public.is_admin() then raise exception 'Not permitted'; end if;
  perform set_config('app.system', '1', true);
  select * into a from public.partner_applications where id = p_id for update;
  if not found then raise exception 'Application not found'; end if;

  if p_action = 'review' then
    if a.status = 'submitted' then
      update public.partner_applications set status = 'under_review', reviewed_by = v_uid where id = a.id;
      insert into public.application_events (application_id, status, actor_id) values (a.id, 'under_review', v_uid);
    end if;
    return 'under_review';
  end if;
  if p_action = 'verify' then
    if p_key = 'docs' then update public.partner_applications set verified_docs = not verified_docs where id = a.id;
    elsif p_key = 'location' then update public.partner_applications set verified_location = not verified_location where id = a.id;
    elsif p_key = 'contact' then update public.partner_applications set verified_contact = not verified_contact where id = a.id;
    else raise exception 'Unknown check';
    end if;
    return a.status;
  end if;
  if a.status in ('approved', 'rejected') then raise exception 'This application already has a decision'; end if;

  if p_action = 'approve' then
    if a.status <> 'under_review' then raise exception 'Review the application before accepting it'; end if;
    if not (a.verified_docs and a.verified_location and a.verified_contact) then
      raise exception 'Verify documents, location and contact first';
    end if;
    if a.type = 'kitchen' then
      insert into public.kitchens (owner_id, name, area, address, lat, lng, diet, default_capacity, hours_open, hours_close, from_application)
      values (a.applicant_id, a.form ->> 'kitchenName', a.form ->> 'area', a.form ->> 'address',
              (a.form ->> 'lat')::double precision, (a.form ->> 'lng')::double precision,
              case when a.form ->> 'diet' = 'veg' then 'veg' else 'both' end,
              (a.form ->> 'capacity')::numeric, a.form ->> 'hoursOpen', a.form ->> 'hoursClose', a.id)
      returning id into v_k;
      insert into public.kitchen_dishes (kitchen_id, dish_key, price_full, price_half)
      select v_k, d.key, d.base_price_full, (round(d.base_price_full * 0.62 / 5) * 5)::int
      from public.dishes d where d.key in (select jsonb_array_elements_text(a.form -> 'dishes'));
      insert into public.user_roles (user_id, role, granted_by) values (a.applicant_id, 'kitchen_partner', v_uid) on conflict do nothing;
    else
      select full_name into v_name from public.profiles where id = a.applicant_id;
      insert into public.delivery_partners (user_id, display_name, vehicle, lat, lng, from_application)
      values (a.applicant_id, public.short_name(v_name), a.form ->> 'vehicle',
              (a.form ->> 'lat')::double precision, (a.form ->> 'lng')::double precision, a.id)
      on conflict (user_id) do nothing;
      v_k := a.applicant_id;
      insert into public.user_roles (user_id, role, granted_by) values (a.applicant_id, 'delivery_partner', v_uid) on conflict do nothing;
    end if;
    update public.partner_applications set status = 'approved', decided_at = now(), reviewed_by = v_uid, grant_ref = v_k where id = a.id;
    insert into public.application_events (application_id, status, actor_id) values (a.id, 'approved', v_uid);
    perform public.notify_user(a.applicant_id, 'Application approved',
      'Log in again and open your ' || case when a.type = 'kitchen' then 'Kitchen' else 'Delivery Partner' end || ' dashboard from the menu.', 'account');
    perform public.log_activity('application.approved', 'application', a.public_id);
    return 'approved';
  end if;

  if p_action = 'reject' then
    if coalesce(trim(p_text), '') = '' then raise exception 'Add a reason for the rejection'; end if;
    update public.partner_applications set status = 'rejected', decision_note = trim(p_text), decided_at = now(), reviewed_by = v_uid where id = a.id;
    insert into public.application_events (application_id, status, actor_id, note) values (a.id, 'rejected', v_uid, trim(p_text));
    perform public.notify_user(a.applicant_id, 'Application not approved', 'Reason: ' || trim(p_text), 'account');
    perform public.log_activity('application.rejected', 'application', a.public_id);
    return 'rejected';
  end if;

  if p_action = 'info' then
    if coalesce(trim(p_text), '') = '' then raise exception 'Say what information you need'; end if;
    update public.partner_applications set status = 'more_info', decision_note = trim(p_text), reviewed_by = v_uid where id = a.id;
    insert into public.application_events (application_id, status, actor_id, note) values (a.id, 'more_info', v_uid, trim(p_text));
    perform public.notify_user(a.applicant_id, 'More information needed', trim(p_text), 'account');
    return 'more_info';
  end if;
  raise exception 'Unknown action';
end $$;

create or replace function public.respond_application(p_id uuid, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare a public.partner_applications%rowtype;
begin
  select * into a from public.partner_applications where id = p_id and applicant_id = auth.uid() for update;
  if not found then raise exception 'Not permitted'; end if;
  if a.status <> 'more_info' then raise exception 'Nothing is waiting for your reply'; end if;
  if coalesce(trim(p_text), '') = '' then raise exception 'Write your reply first'; end if;
  update public.partner_applications set status = 'under_review' where id = a.id;
  insert into public.application_events (application_id, status, actor_id, note) values (a.id, 'under_review', auth.uid(), trim(p_text));
end $$;

create or replace function public.add_application_documents(p_id uuid, p_docs jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare a public.partner_applications%rowtype;
begin
  select * into a from public.partner_applications where id = p_id and applicant_id = auth.uid();
  if not found then raise exception 'Not permitted'; end if;
  if a.status not in ('submitted', 'under_review', 'more_info') then raise exception 'This application is closed'; end if;
  if exists (select 1 from jsonb_to_recordset(p_docs) as x(key text, name text, path text)
             where x.path is null or x.path not like auth.uid()::text || '/%') then raise exception 'Invalid document upload'; end if;
  insert into public.application_documents (application_id, doc_key, file_name, storage_path)
  select a.id, x.key, x.name, x.path from jsonb_to_recordset(p_docs) as x(key text, name text, path text);
end $$;

create or replace function public.set_document_requirement(p_type text, p_key text, p_required boolean, p_from date default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not permitted'; end if;
  update public.document_requirements
     set required = p_required, required_from = case when p_required then p_from else null end,
         updated_by = auth.uid(), updated_at = now()
   where partner_type = p_type and doc_key = p_key;
  if not found then raise exception 'Unknown document'; end if;
  perform public.log_activity('docreq.changed', 'document_requirement', p_type || ':' || p_key,
                              jsonb_build_object('required', p_required, 'from', p_from));
end $$;

create or replace function public.reset_document_requirements(p_type text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not permitted'; end if;
  update public.document_requirements set required = false, required_from = null, updated_by = auth.uid(), updated_at = now()
   where partner_type = p_type;
  perform public.log_activity('docreq.reset', 'document_requirement', p_type);
end $$;

-- ---------- RECEPTION CHAT ----------
create or replace function public.chat_send(p_text text, p_role text default 'customer', p_ctx text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_text text := trim(coalesce(p_text, '')); v_auto text; t text;
  v_o record;
begin
  if v_uid is null then raise exception 'Please log in first'; end if;
  if v_text = '' then raise exception 'Write a message first'; end if;
  if char_length(v_text) > 800 then raise exception 'Please keep messages under 800 characters'; end if;
  if p_role not in ('customer', 'kitchen', 'delivery') then raise exception 'Unknown role'; end if;
  if p_role = 'kitchen' and not public.has_role('kitchen_partner') then raise exception 'Not permitted'; end if;
  if p_role = 'delivery' and not public.has_role('delivery_partner') then raise exception 'Not permitted'; end if;

  insert into public.chat_threads (user_id, role, status, unread_admin, updated_at)
  values (v_uid, p_role, 'open', 1, now())
  on conflict (user_id) do update
    set role = excluded.role, status = 'open', unread_admin = public.chat_threads.unread_admin + 1, updated_at = now();
  insert into public.chat_messages (thread_user_id, sender, body, ctx) values (v_uid, 'user', v_text, nullif(p_ctx, ''));

  t := lower(v_text);
  if t like '%talk to a person%' then
    v_auto := 'I have asked a person from reception to join. They will reply here.';
  elsif p_role = 'customer' and (t like '%where%' or t like '%track%' or t like '%order%' or t like '%late%') then
    select public_id, status, eta_min into v_o from public.orders where customer_id = v_uid and status <> 'cancelled' order by created_at desc limit 1;
    if v_o.public_id is null then v_auto := 'You have no orders yet. When you place one, I can tell you exactly where it is.';
    else v_auto := 'Your latest order ' || v_o.public_id || ' is "' || v_o.status || '". You can follow it live on the Orders tab.';
    end if;
  elsif t like '%refund%' or t like '%payment%' or t like '%charged%' then
    v_auto := 'I have flagged this for our payments team. A person from reception will reply here, usually within a few minutes.';
    perform public.log_activity('chat.payment_issue', 'chat', v_uid::text, jsonb_build_object('text', left(v_text, 140)));
  else
    v_auto := 'Thanks, I have passed this to reception. A person will reply here shortly.';
  end if;
  insert into public.chat_messages (thread_user_id, sender, body) values (v_uid, 'auto', v_auto);
end $$;

create or replace function public.chat_reply(p_user uuid, p_text text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not permitted'; end if;
  if coalesce(trim(p_text), '') = '' then raise exception 'Write a reply first'; end if;
  if not exists (select 1 from public.chat_threads where user_id = p_user) then raise exception 'No such chat'; end if;
  insert into public.chat_messages (thread_user_id, sender, body) values (p_user, 'reception', trim(p_text));
  update public.chat_threads set unread_user = unread_user + 1, unread_admin = 0, status = 'open', updated_at = now() where user_id = p_user;
  perform public.notify_user(p_user, 'Reception replied', left(trim(p_text), 80), 'orders');
end $$;

create or replace function public.chat_resolve(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not permitted'; end if;
  update public.chat_threads set status = 'resolved', unread_user = unread_user + 1, updated_at = now() where user_id = p_user;
  insert into public.chat_messages (thread_user_id, sender, body) values (p_user, 'auto', 'This chat was marked resolved. Message again any time.');
end $$;

create or replace function public.chat_read_user() returns void
language sql security definer set search_path = public as $$
  update public.chat_threads set unread_user = 0 where user_id = auth.uid()
$$;
create or replace function public.chat_open_admin(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not permitted'; end if;
  update public.chat_threads set unread_admin = 0 where user_id = p_user;
end $$;

create or replace function public.mark_notifications_read() returns void
language sql security definer set search_path = public as $$
  update public.notifications set read = true where user_id = auth.uid() and not read
$$;

-- ---------- ADMIN ----------
create or replace function public.set_service_radius(p_km numeric) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not permitted'; end if;
  if p_km < 1 or p_km > 50 then raise exception 'Radius must be between 1 and 50 km'; end if;
  insert into public.app_settings (key, value) values ('service_radius_km', to_jsonb(p_km))
  on conflict (key) do update set value = excluded.value;
  perform public.log_activity('settings.radius', 'setting', 'service_radius_km', jsonb_build_object('km', p_km));
end $$;

create or replace function public.admin_set_kitchen(p_kitchen uuid, p_status text default null, p_commission int default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not permitted'; end if;
  perform set_config('app.system', '1', true);
  update public.kitchens set status = coalesce(p_status, status), commission_pct = coalesce(p_commission, commission_pct) where id = p_kitchen;
  perform public.log_activity('kitchen.admin_update', 'kitchen', p_kitchen::text, jsonb_build_object('status', p_status, 'commission', p_commission));
end $$;

create or replace function public.admin_stats() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Not permitted'; end if;
  return jsonb_build_object(
    'orders_total', (select count(*) from public.orders),
    'orders_today', (select count(*) from public.orders where (created_at at time zone 'Asia/Kolkata')::date = public.today_ist() and status <> 'cancelled'),
    'gmv_today', coalesce((select sum(total) from public.orders where (created_at at time zone 'Asia/Kolkata')::date = public.today_ist() and status <> 'cancelled'), 0),
    'kitchens_active', (select count(*) from public.kitchens where status = 'active'),
    'riders_online', (select count(*) from public.delivery_partners where online),
    'applications_pending', (select count(*) from public.partner_applications where status in ('submitted', 'under_review', 'more_info')),
    'chats_unread', coalesce((select sum(unread_admin) from public.chat_threads), 0),
    'errors_24h', (select count(*) from public.error_log where at > now() - interval '24 hours'));
end $$;

create or replace function public.client_log(p_message text, p_stack text default null, p_context jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  insert into public.error_log (user_id, source, message, stack, context)
  values (auth.uid(), 'client', left(coalesce(p_message, 'unknown'), 500), left(p_stack, 2000), coalesce(p_context, '{}'));
end $$;

-- run by the project owner in the SQL editor ONLY (the browser can never call this)
create or replace function public.make_admin(p_email text) returns text
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  select id into v_id from auth.users where lower(email) = lower(trim(p_email));
  if v_id is null then raise exception 'No user with email %. Sign up in the app first, then run this again.', p_email; end if;
  insert into public.user_roles (user_id, role) values (v_id, 'admin') on conflict do nothing;
  return 'ADMIN role granted to ' || p_email;
end $$;

-- ---------- who may call what ----------
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig, p.proname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if f.proname in ('place_order','order_advance','order_cancel','order_rate','toggle_favourite','set_favourite_rating',
                     'submit_application','review_application','respond_application','add_application_documents',
                     'set_document_requirement','reset_document_requirements','chat_send','chat_reply','chat_resolve',
                     'chat_read_user','chat_open_admin','mark_notifications_read','set_service_radius','admin_set_kitchen',
                     'admin_stats','client_log') then
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
    -- helpers used inside security rules and triggers
    if f.proname in ('haversine_km','today_ist','has_role','is_admin','owns_kitchen','is_assigned_rider','is_online_rider','is_system','short_name') then
      execute format('grant execute on function %s to anon, authenticated', f.sig);
    end if;
  end loop;
end $$;
