-- =====================================================================
-- Highway Eat: reference data only (no demo kitchens, users or orders). Run after 003.
-- =====================================================================

insert into public.app_settings (key, value) values
  ('service_radius_km', '20'::jsonb),
  ('platform_commission_pct', '15'::jsonb)
on conflict (key) do nothing;

-- the dish catalogue: types of dish a kitchen can offer
insert into public.dishes (key, name, category, is_veg, is_premium, emoji, base_price_full) values
  ('aloo-gobhi',      'Aloo Gobhi',          'sabzi',   true,  false, '🥔', 110),
  ('bhindi',          'Bhindi Masala',       'sabzi',   true,  false, '🥒', 110),
  ('baingan',         'Baingan Bharta',      'sabzi',   true,  false, '🍆', 110),
  ('mix-veg',         'Mix Veg',             'sabzi',   true,  false, '🥕', 110),
  ('rajma',           'Rajma',               'sabzi',   true,  false, '🫘', 115),
  ('chole',           'Chole',               'sabzi',   true,  false, '🫘', 115),
  ('paneer',          'Paneer Sabzi',        'protein', true,  false, '🧀', 140),
  ('dal-tadka',       'Dal Tadka',           'dal',     true,  false, '🍲', 100),
  ('roti',            'Roti',                'bread',   true,  false, '🫓', 100),
  ('rice',            'Jeera Rice',          'rice',    true,  false, '🍚', 100),
  ('tamatar-chutney', 'Tamatar Chutney',     'side',    true,  false, '🍅', 100),
  ('chicken-curry',   'Chicken Curry',       'protein', false, false, '🍗', 160),
  ('egg-curry',       'Egg Curry',           'protein', false, false, '🥚', 130),
  ('butter-chicken',  'Butter Chicken',      'premium', false, true,  '🍛', 190),
  ('paneer-tikka',    'Paneer Tikka Masala', 'premium', true,  true,  '🍢', 180)
on conflict (key) do nothing;

-- partner documents: EVERY document is optional until an admin switches it on
insert into public.document_requirements (partner_type, doc_key, label, applies_to, min_files) values
  ('kitchen',  'fssai',     'FSSAI licence',                   'all',   1),
  ('kitchen',  'aadhaar',   'Aadhaar Card',                    'all',   1),
  ('kitchen',  'pan',       'PAN Card',                        'all',   1),
  ('kitchen',  'addr',      'Kitchen address proof',           'all',   1),
  ('kitchen',  'gst',       'GST certificate',                 'all',   1),
  ('kitchen',  'bank',      'Cancelled cheque or bank proof',  'all',   1),
  ('kitchen',  'photos',    'Kitchen photos',                  'all',   3),
  ('delivery', 'aadhaar',   'Aadhaar Card',                    'all',   1),
  ('delivery', 'dl',        'Driving Licence',                 'motor', 1),
  ('delivery', 'rc',        'Vehicle registration (RC)',       'motor', 1),
  ('delivery', 'insurance', 'Vehicle insurance',               'motor', 1),
  ('delivery', 'pan',       'PAN Card',                        'all',   1),
  ('delivery', 'police',    'Police verification certificate', 'all',   1),
  ('delivery', 'photo',     'Profile photo',                   'all',   1),
  ('delivery', 'bank',      'Cancelled cheque or bank proof',  'all',   1)
on conflict (partner_type, doc_key) do nothing;

-- NEXT STEP (after you have signed up once in the app with your own email):
--   select public.make_admin('you@example.com');
-- That is the only way to create an admin. Nobody can become admin from the app.
