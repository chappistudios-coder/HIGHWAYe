-- =====================================================================
-- Highway Eat: file storage and realtime. Run after 002_functions.sql.
-- =====================================================================

-- ---------- storage buckets ----------
-- application-docs : PRIVATE. Partner documents (FSSAI, Aadhaar, licence ...). Only the owner and admins can read them.
-- dish-images      : public read. Menu item photos uploaded by kitchens.
-- kitchen-photos   : public read. Kitchen photos uploaded by kitchens.
insert into storage.buckets (id, name, public) values
  ('application-docs', 'application-docs', false),
  ('dish-images', 'dish-images', true),
  ('kitchen-photos', 'kitchen-photos', true)
on conflict (id) do nothing;

-- files live in a folder named after the owner: application-docs/<user id>/..., dish-images/<kitchen id>/...
drop policy if exists "docs upload own" on storage.objects;
create policy "docs upload own" on storage.objects for insert to authenticated
  with check (bucket_id = 'application-docs' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "docs read own or admin" on storage.objects;
create policy "docs read own or admin" on storage.objects for select to authenticated
  using (bucket_id = 'application-docs' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

drop policy if exists "docs delete own" on storage.objects;
create policy "docs delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'application-docs' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "images public read" on storage.objects;
create policy "images public read" on storage.objects for select to anon, authenticated
  using (bucket_id in ('dish-images', 'kitchen-photos'));

drop policy if exists "images kitchen write" on storage.objects;
create policy "images kitchen write" on storage.objects for insert to authenticated
  with check (bucket_id in ('dish-images', 'kitchen-photos')
              and exists (select 1 from public.kitchens k where k.id::text = (storage.foldername(name))[1] and k.owner_id = auth.uid()));

drop policy if exists "images kitchen update" on storage.objects;
create policy "images kitchen update" on storage.objects for update to authenticated
  using (bucket_id in ('dish-images', 'kitchen-photos')
         and exists (select 1 from public.kitchens k where k.id::text = (storage.foldername(name))[1] and k.owner_id = auth.uid()));

drop policy if exists "images kitchen delete" on storage.objects;
create policy "images kitchen delete" on storage.objects for delete to authenticated
  using (bucket_id in ('dish-images', 'kitchen-photos')
         and exists (select 1 from public.kitchens k where k.id::text = (storage.foldername(name))[1] and k.owner_id = auth.uid()));

-- ---------- realtime ----------
-- Every change to these tables is pushed live to the phones allowed to see that row (row level security still applies).
do $$
declare t text;
begin
  foreach t in array array[
    'orders', 'order_status_events', 'delivery_assignments', 'kitchens', 'kitchen_dishes', 'kitchen_capacity',
    'delivery_partners', 'partner_applications', 'application_documents', 'chat_threads', 'chat_messages',
    'notifications', 'document_requirements', 'app_settings', 'favourites', 'addresses', 'activity_log', 'error_log']
  loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
