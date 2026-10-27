-- ============================================================
-- Sales Page Produk Digital — schema.sql (idempotent, jalankan di SQL Editor)
-- ============================================================
create extension if not exists pgcrypto;

-- ── Profil staf (role owner / admin) ──
create table if not exists public.profiles(
  id uuid primary key references auth.users(id) on delete cascade,
  nama text, role text not null default 'admin' check (role in ('owner','admin')),
  created_at timestamptz not null default now());
alter table public.profiles enable row level security;

create or replace function public.is_staff() returns boolean language sql stable security definer set search_path=public as
$$ select exists(select 1 from profiles where id=auth.uid()) $$;
create or replace function public.is_owner() returns boolean language sql stable security definer set search_path=public as
$$ select exists(select 1 from profiles where id=auth.uid() and role='owner') $$;

drop policy if exists "profil sendiri/owner" on public.profiles;
create policy "profil sendiri/owner" on public.profiles for select using (id=auth.uid() or public.is_owner());
drop policy if exists "owner kelola profil" on public.profiles;
create policy "owner kelola profil" on public.profiles for all using (public.is_owner()) with check (public.is_owner());

create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin insert into profiles(id,nama,role) values(new.id,new.raw_user_meta_data->>'nama','admin') on conflict do nothing; return new; end; $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- ── Konten publik (baca: semua yang aktif; tulis: owner) ──
create table if not exists public.products(
  id uuid primary key default gen_random_uuid(), name text not null, tagline text, description text,
  price numeric not null check (price>=0), discount_price numeric check (discount_price>=0),
  features jsonb not null default '[]', images text[] not null default '{}',
  is_active boolean not null default true, sort_order int not null default 0, created_at timestamptz default now());
create table if not exists public.bonuses(
  id uuid primary key default gen_random_uuid(), title text not null, description text, value_label text,
  deadline timestamptz, is_active boolean not null default true, sort_order int not null default 0);
create table if not exists public.testimonials(
  id uuid primary key default gen_random_uuid(), name text not null, rating smallint not null default 5 check (rating between 1 and 5),
  short_text text, full_text text, screenshot_url text, is_active boolean not null default true, sort_order int not null default 0);
create table if not exists public.faqs(
  id uuid primary key default gen_random_uuid(), question text not null, answer text not null,
  is_active boolean not null default true, sort_order int not null default 0);
create table if not exists public.site_settings(key text primary key, value text);

do $$ declare t text; begin
  foreach t in array array['products','bonuses','testimonials','faqs'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "baca aktif" on public.%I', t);
    execute format('create policy "baca aktif" on public.%I for select using (is_active or public.is_staff())', t);
    execute format('drop policy if exists "owner tulis" on public.%I', t);
    execute format('create policy "owner tulis" on public.%I for all using (public.is_owner()) with check (public.is_owner())', t);
  end loop; end $$;
alter table public.site_settings enable row level security;
drop policy if exists "baca settings" on public.site_settings;
create policy "baca settings" on public.site_settings for select using (true);
drop policy if exists "owner tulis settings" on public.site_settings;
create policy "owner tulis settings" on public.site_settings for all using (public.is_owner()) with check (public.is_owner());

-- ── Pesanan (anon TIDAK punya akses langsung; insert lewat RPC) ──
create table if not exists public.orders(
  id uuid primary key default gen_random_uuid(),
  order_code text unique not null default ('ORD-'||upper(substr(md5(gen_random_uuid()::text),1,6))),
  buyer_name text not null check (length(buyer_name) between 2 and 100),
  buyer_whatsapp text not null check (buyer_whatsapp ~ '^[0-9+]{8,16}$'),
  buyer_email text, product_id uuid references public.products(id) on delete restrict,
  price_paid numeric not null, payment_status text not null default 'menunggu'
    check (payment_status in ('menunggu','bukti_diunggah','lunas','ditolak')),
  payment_proof_path text, notes text, created_at timestamptz not null default now(), paid_at timestamptz);
alter table public.orders enable row level security;
drop policy if exists "staf baca order" on public.orders;
create policy "staf baca order" on public.orders for select using (public.is_staff());
drop policy if exists "staf ubah status" on public.orders;
create policy "staf ubah status" on public.orders for update using (public.is_staff()) with check (public.is_staff());
drop policy if exists "owner hapus order" on public.orders;
create policy "owner hapus order" on public.orders for delete using (public.is_owner());

-- Admin/CS hanya boleh mengubah status bayar (kolom lain dikembalikan)
create or replace function public.orders_guard() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if not public.is_owner() then
    new.order_code:=old.order_code; new.buyer_name:=old.buyer_name; new.buyer_whatsapp:=old.buyer_whatsapp;
    new.buyer_email:=old.buyer_email; new.product_id:=old.product_id; new.price_paid:=old.price_paid;
    new.payment_proof_path:=old.payment_proof_path; new.notes:=old.notes; new.created_at:=old.created_at;
  end if;
  if new.payment_status='lunas' and old.payment_status<>'lunas' then new.paid_at:=now(); end if;
  return new; end; $$;
drop trigger if exists trg_orders_guard on public.orders;
create trigger trg_orders_guard before update on public.orders for each row execute function public.orders_guard();

create table if not exists public.page_views(
  id bigint generated always as identity primary key, visited_at timestamptz not null default now(), session_id text);
alter table public.page_views enable row level security;
drop policy if exists "staf baca views" on public.page_views;
create policy "staf baca views" on public.page_views for select using (public.is_staff());

-- ── RPC untuk pembeli (tanpa akun) ──
create or replace function public.create_order(p_name text,p_wa text,p_email text,p_product uuid)
returns text language plpgsql security definer set search_path=public as $$
declare v_price numeric; v_code text;
begin
  select coalesce(discount_price,price) into v_price from products where id=p_product and is_active;
  if v_price is null then raise exception 'Produk tidak tersedia'; end if;
  insert into orders(buyer_name,buyer_whatsapp,buyer_email,product_id,price_paid)
  values(trim(p_name),regexp_replace(p_wa,'[^0-9+]','','g'),nullif(trim(p_email),''),p_product,v_price) returning order_code into v_code;
  return v_code; end; $$;

create or replace function public.attach_proof(p_code text,p_path text) returns boolean
language plpgsql security definer set search_path=public as $$
begin
  update orders set payment_proof_path=p_path,payment_status='bukti_diunggah'
   where order_code=p_code and payment_status in ('menunggu','ditolak','bukti_diunggah');
  return found; end; $$;

create or replace function public.track_visit(p_session text) returns void
language sql security definer set search_path=public as $$ insert into page_views(session_id) values(left(p_session,64)) $$;

create or replace function public.daily_stats(p_days int default 14)
returns table(day date, visitors bigint, orders bigint, paid bigint) language plpgsql security definer set search_path=public as $$
begin
  if not is_staff() then raise exception 'Tidak diizinkan'; end if;
  return query select d::date,
    (select count(distinct session_id) from page_views where visited_at::date=d::date),
    (select count(*) from orders where created_at::date=d::date),
    (select count(*) from orders where created_at::date=d::date and payment_status='lunas')
  from generate_series(current_date-(p_days-1),current_date,'1 day') d; end; $$;

grant execute on function public.create_order,public.attach_proof,public.track_visit to anon,authenticated;
grant execute on function public.daily_stats to authenticated;

-- ── Storage ──
insert into storage.buckets(id,name,public) values('payment-proofs','payment-proofs',false),('public-assets','public-assets',true) on conflict do nothing;
drop policy if exists "anon unggah bukti" on storage.objects;
create policy "anon unggah bukti" on storage.objects for insert with check (bucket_id='payment-proofs');
drop policy if exists "staf baca bukti" on storage.objects;
create policy "staf baca bukti" on storage.objects for select using (bucket_id='payment-proofs' and public.is_staff());
drop policy if exists "owner kelola aset" on storage.objects;
create policy "owner kelola aset" on storage.objects for all using (bucket_id='public-assets' and public.is_owner()) with check (bucket_id='public-assets' and public.is_owner());
drop policy if exists "aset publik" on storage.objects;
create policy "aset publik" on storage.objects for select using (bucket_id='public-assets');

-- ── Realtime untuk daftar pesanan ──
do $$ begin alter publication supabase_realtime add table public.orders; exception when others then null; end $$;

-- ── Data awal ──
insert into public.site_settings(key,value) values
 ('brand','Sales Page'),('whatsapp','6281234567890'),
 ('payment_info','BCA 1234567890 a.n. Nama Anda\nQRIS / e-wallet: hubungi CS'),
 ('hero_headline','Kuasai Skill & Monetisasi Produk Digital Anda'),
 ('hero_sub','Template, modul, dan bonus lengkap — langsung bisa dipakai hari ini.'),
 ('problem','Bingung mulai dari mana? Modal terbatas? Takut tidak laku? Halaman ini jawabannya.')
on conflict do nothing;
insert into public.products(id,name,tagline,price,discount_price,features,images) values
 ('11111111-1111-1111-1111-111111111111','Masterclass Creator Pro','Paket lengkap akses selamanya',499000,149000,
  '["Modul video 10 sesi","150+ template siap pakai","Grup komunitas","Update gratis"]','{}')
on conflict do nothing;
insert into public.bonuses(id,title,description,value_label,deadline) values
 ('22222222-2222-2222-2222-222222222222','Template Canva 100+','Siap edit','Rp 199.000',now()+interval '7 days') on conflict do nothing;
insert into public.testimonials(id,name,rating,short_text,full_text) values
 ('33333333-3333-3333-3333-333333333333','Amanda S.',5,'Isinya daging semua!','Isinya daging semua, langsung bisa dipraktikkan dan hasilnya terasa.') on conflict do nothing;
insert into public.faqs(id,question,answer) values
 ('44444444-4444-4444-4444-444444444441','Bagaimana cara akses produknya?','Setelah pembayaran dikonfirmasi, link akses dikirim via WhatsApp/email.'),
 ('44444444-4444-4444-4444-444444444442','Format file-nya apa?','Video MP4, dokumen PDF, dan template Canva/Notion.') on conflict do nothing;

-- Jadikan akun pertama sebagai OWNER (ganti email, jalankan setelah akun dibuat di Authentication → Users):
-- update public.profiles set role='owner' where id=(select id from auth.users where email='EMAIL_ANDA');
