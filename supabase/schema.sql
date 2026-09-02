-- ============================================================
-- MOREALA (Phase 1) — Full Postgres Schema + RLS
-- Run this in the Supabase SQL editor, top to bottom.
-- ============================================================

-- ---------- USERS ----------
create table users (
  id uuid primary key default gen_random_uuid(),
  auth_id uuid unique references auth.users(id) on delete cascade,
  name text not null,
  email text unique not null,
  plan_tier text default 'free' check (plan_tier in ('free', 'lecturer')),
  scans_used_this_month int default 0,
  created_at timestamptz default now()
);

-- ---------- MODELS (master walkthrough spaces) ----------
create table models (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid references users(id) on delete cascade,
  title text not null,
  is_shared boolean default false,
  campus_location text,
  status text default 'processing' check (status in ('processing', 'ready', 'failed')),
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- ---------- PHOTO POINTS (node graph) ----------
create table photo_points (
  id uuid primary key default gen_random_uuid(),
  model_id uuid references models(id) on delete cascade,
  photo_url_forward text not null,
  photo_url_left text,
  photo_url_right text,
  heading float default 0,
  order_index int not null,
  linked_next_id uuid references photo_points(id),
  linked_prev_id uuid references photo_points(id),
  created_at timestamptz default now()
);

-- ---------- PINS (anchored to 2D photo coordinates) ----------
create table pins (
  id uuid primary key default gen_random_uuid(),
  photo_point_id uuid references photo_points(id) on delete cascade,
  user_id uuid references users(id) on delete cascade,
  x float not null check (x >= 0 and x <= 1),
  y float not null check (y >= 0 and y <= 1),
  note_id uuid,
  created_at timestamptz default now()
);

-- ---------- NOTES (text / audio / flashcard) ----------
create table notes (
  id uuid primary key default gen_random_uuid(),
  pin_id uuid references pins(id) on delete cascade,
  owner_id uuid references users(id) on delete cascade,
  type text check (type in ('text', 'audio', 'flashcard')),
  content jsonb not null,       -- {question, answer} for flashcard, {body} for text
  media_url text,               -- for audio notes, R2 signed URL target
  created_at timestamptz default now()
);

alter table pins add constraint pins_note_id_fkey
  foreign key (note_id) references notes(id) on delete set null;

-- ---------- SM-2 SPACED REPETITION LOGS ----------
create table reviews (
  id uuid primary key default gen_random_uuid(),
  note_id uuid references notes(id) on delete cascade,
  user_id uuid references users(id) on delete cascade,
  next_review_date timestamptz not null default now(),
  ease_factor float default 2.5,
  interval int default 1,
  repetitions int default 0,
  last_reviewed_at timestamptz,
  unique(note_id, user_id)
);

-- ---------- PAYMENTS (M-Pesa Daraja) ----------
create table payments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id) on delete cascade,
  amount numeric not null,
  purpose text check (purpose in ('scan', 'lecturer_monthly', 'lecturer_semester')),
  mpesa_receipt text unique,
  checkout_request_id text unique,   -- Daraja CheckoutRequestID, set at STK push time
  status text not null default 'pending' check (status in ('pending', 'success', 'failed')),
  created_at timestamptz default now()
);

-- ---------- CLASSES ----------
create table classes (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid references users(id) on delete cascade,
  model_id uuid references models(id) on delete cascade,
  class_code text unique not null,
  is_active boolean default true,
  created_at timestamptz default now()
);

create table class_members (
  id uuid primary key default gen_random_uuid(),
  class_id uuid references classes(id) on delete cascade,
  user_id uuid references users(id) on delete cascade,
  joined_at timestamptz default now(),
  unique(class_id, user_id)
);

-- ============================================================
-- INDEXES
-- ============================================================
create index idx_photo_points_model on photo_points(model_id);
create index idx_pins_photo_point on pins(photo_point_id);
create index idx_notes_pin on notes(pin_id);
create index idx_reviews_user_due on reviews(user_id, next_review_date);
create index idx_class_members_class on class_members(class_id);
create index idx_class_members_user on class_members(user_id);
create index idx_classes_code on classes(class_code);

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================
alter table users enable row level security;
alter table models enable row level security;
alter table photo_points enable row level security;
alter table pins enable row level security;
alter table notes enable row level security;
alter table reviews enable row level security;
alter table payments enable row level security;
alter table classes enable row level security;
alter table class_members enable row level security;

-- Helper: map auth.uid() -> internal users.id
create or replace function current_user_id()
returns uuid
language sql stable
as $$
  select id from users where auth_id = auth.uid()
$$;

-- USERS: a user can read/update only their own row
create policy "users_select_own" on users
  for select using (auth_id = auth.uid());
create policy "users_update_own" on users
  for update using (auth_id = auth.uid());
create policy "users_insert_self" on users
  for insert with check (auth_id = auth.uid());

-- MODELS: owner has full access; shared/class-linked models are readable
-- by class members
create policy "models_select" on models
  for select using (
    owner_id = current_user_id()
    or is_shared = true
    or id in (
      select model_id from classes c
      join class_members cm on cm.class_id = c.id
      where cm.user_id = current_user_id()
    )
  );
create policy "models_insert_own" on models
  for insert with check (owner_id = current_user_id());
create policy "models_update_own" on models
  for update using (owner_id = current_user_id());
create policy "models_delete_own" on models
  for delete using (owner_id = current_user_id());

-- PHOTO_POINTS: readable if parent model is readable (mirrors models policy)
create policy "photo_points_select" on photo_points
  for select using (
    model_id in (
      select id from models
      where owner_id = current_user_id()
         or is_shared = true
         or id in (
           select model_id from classes c
           join class_members cm on cm.class_id = c.id
           where cm.user_id = current_user_id()
         )
    )
  );
create policy "photo_points_write_owner" on photo_points
  for all using (
    model_id in (select id from models where owner_id = current_user_id())
  );

-- PINS: a user sees their own pins, plus pins on shared/class models
-- (so classmates' pins are visible on shared study spaces)
create policy "pins_select" on pins
  for select using (
    user_id = current_user_id()
    or photo_point_id in (
      select pp.id from photo_points pp
      join models m on m.id = pp.model_id
      where m.is_shared = true
         or m.id in (
           select model_id from classes c
           join class_members cm on cm.class_id = c.id
           where cm.user_id = current_user_id()
         )
    )
  );
create policy "pins_insert_own" on pins
  for insert with check (user_id = current_user_id());
create policy "pins_update_own" on pins
  for update using (user_id = current_user_id());
create policy "pins_delete_own" on pins
  for delete using (user_id = current_user_id());

-- NOTES: strictly private to the owner (this is the "User A cannot see
-- User B's notes" requirement from the security checklist)
create policy "notes_select_own" on notes
  for select using (owner_id = current_user_id());
create policy "notes_insert_own" on notes
  for insert with check (owner_id = current_user_id());
create policy "notes_update_own" on notes
  for update using (owner_id = current_user_id());
create policy "notes_delete_own" on notes
  for delete using (owner_id = current_user_id());

-- REVIEWS: strictly private (SM-2 progress is personal)
create policy "reviews_all_own" on reviews
  for all using (user_id = current_user_id());

-- PAYMENTS: strictly private; inserts/updates from client are blocked —
-- only the service role (used by the webhook edge function) can write.
create policy "payments_select_own" on payments
  for select using (user_id = current_user_id());
-- Intentionally NO insert/update policy for the anon/authenticated role.
-- The mpesa-webhook edge function uses the service_role key, which
-- bypasses RLS entirely. This is what prevents client-side tier tampering.

-- CLASSES: owner has full access; class code lookups for joining are
-- allowed for any authenticated user (needed to join via code)
create policy "classes_select" on classes
  for select using (true);
create policy "classes_insert_own" on classes
  for insert with check (owner_id = current_user_id());
create policy "classes_update_own" on classes
  for update using (owner_id = current_user_id());

-- CLASS_MEMBERS: a user can see their own memberships and the lecturer
-- can see their class roster
create policy "class_members_select" on class_members
  for select using (
    user_id = current_user_id()
    or class_id in (select id from classes where owner_id = current_user_id())
  );
create policy "class_members_insert_self" on class_members
  for insert with check (user_id = current_user_id());
