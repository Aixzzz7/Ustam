-- =====================================================================
-- Ustam marketplace: accounts, master profiles, orders (jobs), chat.
-- Run after 001_schema.sql. Uses Supabase Auth (auth.users / auth.uid()),
-- Storage (bucket "avatars") and Realtime.
-- =====================================================================

-- ---------- accounts ----------
create table if not exists profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  role       text not null check (role in ('client', 'master')),
  name       text not null,
  email      text not null,
  phone      text,
  telegram   text,
  created_at timestamptz not null default now()
);

-- ---------- registered masters (public when published) ----------
create table if not exists master_profiles (
  id               text primary key default ('m-' || replace(gen_random_uuid()::text, '-', '')),
  user_id          uuid not null unique references profiles(id) on delete cascade,
  name             text not null,
  title            text not null default '',
  bio              text not null default '',
  type             text not null default 'private' check (type in ('private', 'center')),
  category_ids     text[] not null default '{}',
  service_ids      text[] not null default '{}',
  prices           jsonb not null default '[]',   -- [{serviceId, priceFrom, priceTo}]
  districts        text[] not null default '{}',
  lat              double precision,
  lng              double precision,
  location_label   text,
  workshop_address text,
  experience_years int not null default 0,
  response_time    text not null default '',
  phone            text not null default '',
  telegram         text,
  photo_url        text,
  published        boolean not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

-- ---------- orders ----------
create table if not exists jobs (
  id             text primary key default ('job-' || replace(gen_random_uuid()::text, '-', '')),
  master_id      text not null,               -- master_profiles.id or OLX master id
  master_name    text not null,
  master_user_id uuid references profiles(id) on delete set null,  -- set for registered masters
  client_id      uuid references profiles(id) on delete set null,
  client_name    text not null default '',
  client_phone   text,
  category_id    text references categories(id),
  service_ids    text[] not null default '{}',
  title          text not null default '',
  description    text not null default '',
  district       text,
  address        text not null default '',
  lat            double precision,
  lng            double precision,
  scheduled_at   timestamptz,
  visit_type     text not null default 'home' check (visit_type in ('home', 'workshop')),
  estimate_from  int not null default 0,
  estimate_to    int,
  price          int,
  parts_cost     int not null default 0,
  payment_method text check (payment_method in ('cash', 'card', 'transfer')),
  paid           boolean not null default false,
  status         text not null default 'new' check (status in ('new', 'accepted', 'in_progress', 'done', 'cancelled')),
  source         text not null default 'platform' check (source in ('platform', 'manual')),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  completed_at   timestamptz
);
create index if not exists jobs_master_idx on jobs(master_user_id);
create index if not exists jobs_client_idx on jobs(client_id);

-- ---------- chat ----------
create table if not exists conversations (
  id              text primary key default ('c-' || replace(gen_random_uuid()::text, '-', '')),
  client_id       uuid not null references profiles(id) on delete cascade,
  client_name     text not null,
  master_user_id  uuid not null references profiles(id) on delete cascade,
  master_id       text not null references master_profiles(id) on delete cascade,
  master_name     text not null,
  job_id          text references jobs(id) on delete set null,
  last_message    text not null default '',
  last_message_at timestamptz not null default now(),
  unread_for      uuid[] not null default '{}',
  unique (client_id, master_id)
);

create table if not exists messages (
  id              text primary key default ('msg-' || replace(gen_random_uuid()::text, '-', '')),
  conversation_id text not null references conversations(id) on delete cascade,
  sender_id       uuid not null references profiles(id) on delete cascade,
  body            text not null check (length(body) between 1 and 4000),
  created_at      timestamptz not null default now()
);
create index if not exists messages_conv_idx on messages(conversation_id, created_at);

-- Keep conversation preview + unread flags up to date on every new message
create or replace function on_new_message() returns trigger language plpgsql security definer as $$
declare c conversations;
begin
  select * into c from conversations where id = new.conversation_id;
  update conversations set
    last_message = new.body,
    last_message_at = new.created_at,
    unread_for = array(select distinct unnest(array_remove(unread_for, new.sender_id) ||
                 case when new.sender_id = c.client_id then c.master_user_id else c.client_id end))
  where id = new.conversation_id;
  return new;
end $$;
drop trigger if exists messages_after_insert on messages;
create trigger messages_after_insert after insert on messages for each row execute function on_new_message();

-- Mark a conversation as read by the current user
create or replace function mark_read(conv text) returns void language sql security definer as $$
  update conversations set unread_for = array_remove(unread_for, auth.uid())
  where id = conv and auth.uid() in (client_id, master_user_id);
$$;

-- ---------- Row Level Security ----------
alter table profiles        enable row level security;
alter table master_profiles enable row level security;
alter table jobs            enable row level security;
alter table conversations   enable row level security;
alter table messages        enable row level security;

-- profiles: you see and edit only yourself (public master info lives in master_profiles)
create policy "own profile read"   on profiles for select using (id = auth.uid());
create policy "own profile insert" on profiles for insert with check (id = auth.uid());
create policy "own profile update" on profiles for update using (id = auth.uid());

-- master profiles: published ones are public; only the owner edits
create policy "published masters are public" on master_profiles for select using (published or user_id = auth.uid());
create policy "owner inserts"  on master_profiles for insert with check (user_id = auth.uid());
create policy "owner updates"  on master_profiles for update using (user_id = auth.uid());

-- jobs: visible to its client and its master; clients create platform jobs, masters create manual ones
create policy "job parties read"   on jobs for select using (auth.uid() in (client_id, master_user_id));
create policy "client creates job" on jobs for insert with check (client_id = auth.uid() or master_user_id = auth.uid());
create policy "parties update job" on jobs for update using (auth.uid() in (client_id, master_user_id));
create policy "master deletes manual job" on jobs for delete using (master_user_id = auth.uid() and source = 'manual');

-- chat: only the two participants
create policy "participants read conv"  on conversations for select using (auth.uid() in (client_id, master_user_id));
create policy "client opens conv"       on conversations for insert with check (client_id = auth.uid());
create policy "participants update conv" on conversations for update using (auth.uid() in (client_id, master_user_id));
create policy "participants read msgs" on messages for select using (
  exists (select 1 from conversations c where c.id = conversation_id and auth.uid() in (c.client_id, c.master_user_id)));
create policy "participants send msgs" on messages for insert with check (
  sender_id = auth.uid() and exists (select 1 from conversations c where c.id = conversation_id and auth.uid() in (c.client_id, c.master_user_id)));

-- ---------- Realtime ----------
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table messages, conversations, jobs, master_profiles;
  end if;
end $$;

-- ---------- Storage: profile photos ----------
do $$ begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets (id, name, public) values ('avatars', 'avatars', true) on conflict (id) do nothing;
    create policy "avatar public read" on storage.objects for select using (bucket_id = 'avatars');
    create policy "avatar owner write" on storage.objects for insert with check (bucket_id = 'avatars' and auth.uid()::text = (storage.foldername(name))[1]);
    create policy "avatar owner update" on storage.objects for update using (bucket_id = 'avatars' and auth.uid()::text = (storage.foldername(name))[1]);
  end if;
end $$;
