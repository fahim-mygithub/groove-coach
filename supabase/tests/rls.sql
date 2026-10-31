-- Groove Coach RLS Test Suite
-- Spec: docs/specs/2026-10-31-course-platform-design.md §2.3
-- Checks:
--   1. anon reads nothing
--   2. a learner reads published rows only
--   3. a learner cannot write lessons
--   4. a learner sees only their own attempts, cannot update or delete attempts
--   5. an author can write
--   6. storage select policy: learner reads published prefixes, author reads all

begin;
create extension if not exists pgtap;

select plan(28);

-- -----------------------------------------------------------------------------
-- Setup helper for switching roles and JWT claims
-- -----------------------------------------------------------------------------
create schema if not exists tests;

create or replace function tests.authenticate_as(user_id uuid, user_role text default 'authenticated')
returns void
language plpgsql
as $$
begin
  if user_id is null then
    set local role anon;
    perform set_config('request.jwt.claim.sub', '', true);
    perform set_config('request.jwt.claim.role', 'anon', true);
    perform set_config('request.jwt.claims', '{"role": "anon"}', true);
  else
    set local role authenticated;
    perform set_config('request.jwt.claim.sub', user_id::text, true);
    perform set_config('request.jwt.claim.role', user_role, true);
    perform set_config('request.jwt.claims', json_build_object('sub', user_id::text, 'role', user_role)::text, true);
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- Seed Test Data (as superuser / postgres)
-- -----------------------------------------------------------------------------
reset role;

-- Create test users in auth.users if auth schema exists
insert into auth.users (id, aud, role, email)
values
  ('11111111-1111-1111-1111-111111111111', 'authenticated', 'authenticated', 'learner1@example.com'),
  ('22222222-2222-2222-2222-222222222222', 'authenticated', 'authenticated', 'learner2@example.com'),
  ('33333333-3333-3333-3333-333333333333', 'authenticated', 'authenticated', 'author@example.com')
on conflict (id) do nothing;

-- Ensure profiles exist with proper roles
insert into public.profiles (id, role)
values
  ('11111111-1111-1111-1111-111111111111', 'learner'),
  ('22222222-2222-2222-2222-222222222222', 'learner'),
  ('33333333-3333-3333-3333-333333333333', 'author')
on conflict (id) do update set role = excluded.role;

-- Seed courses
insert into public.courses (id, slug, title, status, created_by)
values
  ('a0000000-0000-0000-0000-000000000001', 'bollywood-basics', 'Bollywood Basics', 'published', '33333333-3333-3333-3333-333333333333'),
  ('a0000000-0000-0000-0000-000000000002', 'hiphop-basics', 'Hip Hop Basics', 'draft', '33333333-3333-3333-3333-333333333333')
on conflict (id) do nothing;

-- Seed lessons
insert into public.lessons (id, course_id, slug, title, position, status)
values
  ('b0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'img4941-routine', 'Routine 1', 1, 'published'),
  ('b0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001', 'secret-routine', 'Draft Routine', 2, 'draft'),
  ('b0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000002', 'hiphop-lesson-1', 'Hiphop 1', 1, 'published')
on conflict (id) do nothing;

-- Seed lesson versions
insert into public.lesson_versions (id, lesson_id, package_version, storage_prefix, manifest, pose_model_sha256, status)
values
  ('c0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', 1, 'bollywood-basics/img4941-routine/v1/', '{"title": "v1"}'::jsonb, '5134a3aa', 'published'),
  ('c0000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000001', 2, 'bollywood-basics/img4941-routine/v2/', '{"title": "v2"}'::jsonb, '5134a3aa', 'draft')
on conflict (id) do nothing;

-- Seed attempts
insert into public.attempts (id, user_id, lesson_version_id, segment_id, speed, mirrored, passed, scores)
values
  ('d0000000-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'c0000000-0000-0000-0000-000000000001', 'A', 0.7, false, true, '{"score": 85}'::jsonb),
  ('d0000000-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'c0000000-0000-0000-0000-000000000001', 'A', 0.7, false, false, '{"score": 60}'::jsonb)
on conflict (id) do nothing;

-- Seed storage objects
insert into storage.objects (id, bucket_id, name, owner)
values
  ('e0000000-0000-0000-0000-000000000001', 'lesson-packages', 'bollywood-basics/img4941-routine/v1/manifest.json', '33333333-3333-3333-3333-333333333333'),
  ('e0000000-0000-0000-0000-000000000002', 'lesson-packages', 'bollywood-basics/img4941-routine/v2/manifest.json', '33333333-3333-3333-3333-333333333333')
on conflict (id) do nothing;

-- -----------------------------------------------------------------------------
-- 1. Anon reads nothing
-- -----------------------------------------------------------------------------
select tests.authenticate_as(null);

select is_empty('select * from public.courses', 'anon cannot read courses');
select is_empty('select * from public.lessons', 'anon cannot read lessons');
select is_empty('select * from public.lesson_versions', 'anon cannot read lesson_versions');
select is_empty('select * from public.attempts', 'anon cannot read attempts');
select is_empty('select * from public.profiles', 'anon cannot read profiles');
select is_empty('select * from public.catalog', 'anon cannot read catalog');
select is_empty('select * from storage.objects where bucket_id = ''lesson-packages''', 'anon cannot read storage objects');

-- -----------------------------------------------------------------------------
-- 2. Learner reads published rows only
-- -----------------------------------------------------------------------------
select tests.authenticate_as('11111111-1111-1111-1111-111111111111'::uuid);

select results_eq(
  'select slug from public.courses order by slug',
  ARRAY['bollywood-basics']::text[],
  'learner reads published courses only'
);

select results_eq(
  'select slug from public.lessons order by slug',
  ARRAY['img4941-routine']::text[],
  'learner reads published lessons only'
);

select results_eq(
  'select package_version from public.lesson_versions order by package_version',
  ARRAY[1]::integer[],
  'learner reads published lesson_versions only'
);

select results_eq(
  'select course_slug, lesson_slug, package_version from public.catalog',
  'select ''bollywood-basics''::text, ''img4941-routine''::text, 1::integer',
  'learner reads published rows from catalog'
);

select results_eq(
  'select name from storage.objects where bucket_id = ''lesson-packages'' order by name',
  ARRAY['bollywood-basics/img4941-routine/v1/manifest.json']::text[],
  'learner reads published storage objects only'
);

-- -----------------------------------------------------------------------------
-- 3. Learner cannot write lessons
-- -----------------------------------------------------------------------------
select throws_ok(
  'insert into public.courses (slug, title, status) values (''bad-course'', ''Bad'', ''published'')',
  '42501',
  NULL,
  'learner cannot insert course'
);

select results_eq(
  'update public.courses set title = ''hacked'' where slug = ''bollywood-basics'' returning slug',
  '{}'::text[],
  'learner cannot update course'
);

select results_eq(
  'delete from public.courses where slug = ''bollywood-basics'' returning slug',
  '{}'::text[],
  'learner cannot delete course'
);

select throws_ok(
  'insert into public.lessons (course_id, slug, title, position, status) values (''a0000000-0000-0000-0000-000000000001'', ''bad-lesson'', ''Bad'', 10, ''published'')',
  '42501',
  NULL,
  'learner cannot insert lesson'
);

select throws_ok(
  'insert into public.lesson_versions (lesson_id, package_version, storage_prefix, manifest, pose_model_sha256) values (''b0000000-0000-0000-0000-000000000001'', 99, ''bad/'', ''{}''::jsonb, ''abc'')',
  '42501',
  NULL,
  'learner cannot insert lesson_version'
);

-- -----------------------------------------------------------------------------
-- 4. Learner sees only their own attempts, cannot update or delete attempts
-- -----------------------------------------------------------------------------
select results_eq(
  'select user_id from public.attempts',
  ARRAY['11111111-1111-1111-1111-111111111111']::uuid[],
  'learner 1 sees only own attempts'
);

select lives_ok(
  'insert into public.attempts (user_id, lesson_version_id, segment_id, speed, mirrored, passed, scores) values (''11111111-1111-1111-1111-111111111111'', ''c0000000-0000-0000-0000-000000000001'', ''B'', 0.8, false, true, ''{}''::jsonb)',
  'learner 1 can insert own attempt'
);

select throws_ok(
  'insert into public.attempts (user_id, lesson_version_id, segment_id, speed, mirrored, passed, scores) values (''22222222-2222-2222-2222-222222222222'', ''c0000000-0000-0000-0000-000000000001'', ''B'', 0.8, false, true, ''{}''::jsonb)',
  '42501',
  NULL,
  'learner cannot insert attempt for another user'
);

select results_eq(
  'update public.attempts set passed = false where user_id = ''11111111-1111-1111-1111-111111111111'' returning id',
  '{}'::uuid[],
  'learner cannot update attempt'
);

select results_eq(
  'delete from public.attempts where user_id = ''11111111-1111-1111-1111-111111111111'' returning id',
  '{}'::uuid[],
  'learner cannot delete attempt'
);

-- -----------------------------------------------------------------------------
-- 5. Author can write & read drafts
-- -----------------------------------------------------------------------------
select tests.authenticate_as('33333333-3333-3333-3333-333333333333'::uuid);

select results_eq(
  'select count(*)::integer from public.courses',
  ARRAY[2]::integer[],
  'author sees all courses (draft + published)'
);

select lives_ok(
  'insert into public.courses (slug, title, status) values (''author-course'', ''Author Course'', ''draft'')',
  'author can insert course'
);

select lives_ok(
  'insert into public.lessons (course_id, slug, title, position, status) values ((select id from public.courses where slug = ''author-course''), ''author-lesson'', ''Author Lesson'', 1, ''draft'')',
  'author can insert lesson'
);

select lives_ok(
  'insert into public.lesson_versions (lesson_id, package_version, storage_prefix, manifest, pose_model_sha256, status) values ((select id from public.lessons where slug = ''author-lesson''), 1, ''author-course/author-lesson/v1/'', ''{}''::jsonb, ''sha256-test'', ''draft'')',
  'author can insert lesson_version'
);

select lives_ok(
  'update public.courses set title = ''Updated Title'' where slug = ''author-course''',
  'author can update course'
);

select results_eq(
  'select count(*)::integer from storage.objects where bucket_id = ''lesson-packages''',
  ARRAY[2]::integer[],
  'author can see all storage objects including drafts'
);

-- -----------------------------------------------------------------------------
-- Finish pgTAP plan
-- -----------------------------------------------------------------------------
select * from finish();
rollback;
