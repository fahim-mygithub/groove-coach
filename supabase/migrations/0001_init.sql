-- Groove Coach Schema: Foundations
-- Spec: docs/specs/2026-10-31-course-platform-design.md §2.3

-- -----------------------------------------------------------------------------
-- 1. Profiles & Authorization Helper
-- -----------------------------------------------------------------------------

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'learner' check (role in ('learner', 'author')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- is_author() security definer function
create or replace function public.is_author()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(
    (
      select role = 'author'
      from public.profiles
      where id = auth.uid()
    ),
    false
  );
$$;

-- Trigger to create profile when auth.users is created
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'role', 'learner')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- -----------------------------------------------------------------------------
-- 2. Core Tables
-- -----------------------------------------------------------------------------

create table if not exists public.courses (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  title text not null,
  status text not null default 'draft' check (status in ('draft', 'published')),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.lessons (
  id uuid primary key default gen_random_uuid(),
  course_id uuid not null references public.courses(id) on delete cascade,
  slug text not null,
  title text not null,
  position int not null check (position >= 0),
  status text not null default 'draft' check (status in ('draft', 'published')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (course_id, slug)
);

create table if not exists public.lesson_versions (
  id uuid primary key default gen_random_uuid(),
  lesson_id uuid not null references public.lessons(id) on delete cascade,
  package_version int not null check (package_version >= 1),
  storage_prefix text not null,
  manifest jsonb not null,
  pose_model_sha256 text not null,
  status text not null default 'published' check (status in ('draft', 'published')),
  published_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (lesson_id, package_version)
);

create table if not exists public.attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  lesson_version_id uuid not null references public.lesson_versions(id) on delete cascade,
  segment_id text not null,
  speed numeric not null check (speed > 0),
  mirrored boolean not null,
  passed boolean not null,
  scores jsonb not null,
  created_at timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- 3. Catalog View
-- Published courses -> lessons -> latest published lesson_versions row
-- -----------------------------------------------------------------------------

create or replace view public.catalog with (security_invoker = true) as
with latest_versions as (
  select distinct on (lesson_id)
    id as lesson_version_id,
    lesson_id,
    package_version,
    storage_prefix,
    manifest,
    pose_model_sha256,
    published_at
  from public.lesson_versions
  where status = 'published'
  order by lesson_id, package_version desc
)
select
  c.id as course_id,
  c.slug as course_slug,
  c.title as course_title,
  l.id as lesson_id,
  l.slug as lesson_slug,
  l.title as lesson_title,
  l.position as lesson_position,
  lv.lesson_version_id,
  lv.package_version,
  lv.storage_prefix,
  lv.manifest,
  lv.pose_model_sha256,
  lv.published_at
from public.courses c
join public.lessons l on l.course_id = c.id
join latest_versions lv on lv.lesson_id = l.id
where c.status = 'published'
  and l.status = 'published'
order by c.slug, l.position;

-- -----------------------------------------------------------------------------
-- 4. Row Level Security (RLS)
-- -----------------------------------------------------------------------------

alter table public.profiles enable row level security;
alter table public.courses enable row level security;
alter table public.lessons enable row level security;
alter table public.lesson_versions enable row level security;
alter table public.attempts enable row level security;

-- Profiles policies
create policy "Authenticated users can read own profile"
  on public.profiles for select
  to authenticated
  using (id = auth.uid() or is_author());

create policy "Authenticated users can insert own profile"
  on public.profiles for insert
  to authenticated
  with check (id = auth.uid());

create policy "Authenticated users can update own profile"
  on public.profiles for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- Courses policies
create policy "Authenticated users can select published courses or authors all"
  on public.courses for select
  to authenticated
  using (status = 'published' or is_author());

create policy "Authors can insert courses"
  on public.courses for insert
  to authenticated
  with check (is_author());

create policy "Authors can update courses"
  on public.courses for update
  to authenticated
  using (is_author())
  with check (is_author());

create policy "Authors can delete courses"
  on public.courses for delete
  to authenticated
  using (is_author());

-- Lessons policies
create policy "Authenticated users can select published lessons or authors all"
  on public.lessons for select
  to authenticated
  using (status = 'published' or is_author());

create policy "Authors can insert lessons"
  on public.lessons for insert
  to authenticated
  with check (is_author());

create policy "Authors can update lessons"
  on public.lessons for update
  to authenticated
  using (is_author())
  with check (is_author());

create policy "Authors can delete lessons"
  on public.lessons for delete
  to authenticated
  using (is_author());

-- Lesson versions policies
create policy "Authenticated users can select published lesson_versions or authors all"
  on public.lesson_versions for select
  to authenticated
  using (status = 'published' or is_author());

create policy "Authors can insert lesson_versions"
  on public.lesson_versions for insert
  to authenticated
  with check (is_author());

create policy "Authors can update lesson_versions"
  on public.lesson_versions for update
  to authenticated
  using (is_author())
  with check (is_author());

create policy "Authors can delete lesson_versions"
  on public.lesson_versions for delete
  to authenticated
  using (is_author());

-- Attempts policies (no update or delete)
create policy "Learners can select own attempts"
  on public.attempts for select
  to authenticated
  using (user_id = auth.uid());

create policy "Learners can insert own attempts"
  on public.attempts for insert
  to authenticated
  with check (user_id = auth.uid());

-- Revoke all table access from anon (anon gets nothing)
revoke all on table public.profiles, public.courses, public.lessons, public.lesson_versions, public.attempts from anon;
revoke all on public.catalog from anon;
grant select on public.catalog to authenticated;

-- -----------------------------------------------------------------------------
-- 5. Storage: Bucket & Object Access Policy
-- -----------------------------------------------------------------------------

insert into storage.buckets (id, name, public)
values ('lesson-packages', 'lesson-packages', false)
on conflict (id) do update set public = false;

create policy "Authenticated users can select published lesson package objects"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'lesson-packages'
    and (
      is_author()
      or exists (
        select 1
        from public.lesson_versions lv
        join public.lessons l on l.id = lv.lesson_id
        join public.courses c on c.id = l.course_id
        where c.status = 'published'
          and l.status = 'published'
          and lv.status = 'published'
          and (
            storage.objects.name like (lv.storage_prefix || '%')
            or storage.objects.name like (trim(trailing '/' from lv.storage_prefix) || '/%')
          )
      )
    )
  );
