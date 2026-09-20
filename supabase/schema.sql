-- Phase 0 foundation for the Padlet MVP.
-- Review this migration before running it in Supabase SQL Editor.
-- No service_role key or other secret belongs in the frontend.

create extension if not exists pgcrypto;

create table if not exists public.boards (
  id uuid primary key default gen_random_uuid(),
  legacy_id text unique,
  name text not null,
  description text not null default '',
  theme text not null default 'theme-pastel',
  current_view text not null default 'wall',
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.board_members (
  board_id uuid not null references public.boards(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('teacher', 'student')),
  created_at timestamptz not null default now(),
  primary key (board_id, user_id)
);

create table if not exists public.sections (
  id uuid primary key default gen_random_uuid(),
  legacy_id text,
  board_id uuid not null references public.boards(id) on delete cascade,
  title text not null,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (board_id, legacy_id)
);

create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  legacy_id text,
  board_id uuid not null references public.boards(id) on delete cascade,
  section_id uuid references public.sections(id) on delete set null,
  author_user_id uuid not null references auth.users(id) on delete restrict,
  student_number integer,
  title text not null,
  content text not null default '',
  color text not null default 'yellow',
  image_url text not null default '',
  link_url text not null default '',
  pinned boolean not null default false,
  canvas_x numeric not null default 100,
  canvas_y numeric not null default 100,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_edited_by uuid references auth.users(id) on delete set null,
  unique (board_id, legacy_id)
);

create table if not exists public.post_moderation (
  post_id uuid primary key references public.posts(id) on delete cascade,
  is_hidden boolean not null default false,
  hidden_by uuid references auth.users(id) on delete set null,
  hidden_at timestamptz,
  updated_at timestamptz not null default now()
);

create index if not exists sections_board_id_idx on public.sections(board_id);
create index if not exists posts_board_id_created_at_idx on public.posts(board_id, created_at desc);
create index if not exists posts_author_user_id_idx on public.posts(author_user_id);
create index if not exists post_moderation_hidden_idx on public.post_moderation(is_hidden);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists boards_set_updated_at on public.boards;
create trigger boards_set_updated_at
before update on public.boards
for each row execute function public.set_updated_at();

drop trigger if exists sections_set_updated_at on public.sections;
create trigger sections_set_updated_at
before update on public.sections
for each row execute function public.set_updated_at();

drop trigger if exists posts_set_updated_at on public.posts;
create trigger posts_set_updated_at
before update on public.posts
for each row execute function public.set_updated_at();

drop trigger if exists post_moderation_set_updated_at on public.post_moderation;
create trigger post_moderation_set_updated_at
before update on public.post_moderation
for each row execute function public.set_updated_at();

create or replace function public.is_board_member(target_board_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.board_members
    where board_id = target_board_id
      and user_id = auth.uid()
  );
$$;

create or replace function public.is_board_teacher(target_board_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.board_members
    where board_id = target_board_id
      and user_id = auth.uid()
      and role = 'teacher'
  );
$$;

create or replace function public.create_board_with_owner(
  board_name text,
  board_description text default '',
  board_theme text default 'theme-pastel',
  board_view text default 'wall'
)
returns public.boards
language plpgsql
security definer
set search_path = public
as $$
declare
  new_board public.boards;
begin
  if auth.uid() is null then
    raise exception 'authentication required';
  end if;
  if nullif(trim(board_name), '') is null then
    raise exception 'board name is required';
  end if;

  insert into public.boards (name, description, theme, current_view, created_by)
  values (
    trim(board_name),
    coalesce(board_description, ''),
    coalesce(nullif(board_theme, ''), 'theme-pastel'),
    coalesce(nullif(board_view, ''), 'wall'),
    auth.uid()
  )
  returning * into new_board;

  insert into public.board_members (board_id, user_id, role)
  values (new_board.id, auth.uid(), 'teacher');

  return new_board;
end;
$$;

create or replace function public.join_board_as_student(target_board_id uuid)
returns public.board_members
language plpgsql
security definer
set search_path = public
as $$
declare
  membership public.board_members;
begin
  if auth.uid() is null then
    raise exception 'authentication required';
  end if;
  if not exists (select 1 from public.boards where id = target_board_id) then
    raise exception 'board not found';
  end if;

  insert into public.board_members (board_id, user_id, role)
  values (target_board_id, auth.uid(), 'student')
  on conflict (board_id, user_id) do nothing;

  select * into membership
  from public.board_members
  where board_id = target_board_id
    and user_id = auth.uid();
  return membership;
end;
$$;

create or replace function public.join_board_by_legacy_id(target_legacy_id text)
returns public.board_members
language plpgsql
security definer
set search_path = public
as $$
declare
  target_board_id uuid;
begin
  select id into target_board_id
  from public.boards
  where legacy_id = target_legacy_id;
  if target_board_id is null then
    raise exception 'board not found';
  end if;
  return public.join_board_as_student(target_board_id);
end;
$$;

revoke all on function public.create_board_with_owner(text, text, text, text) from public;
grant execute on function public.create_board_with_owner(text, text, text, text) to authenticated;
revoke all on function public.join_board_as_student(uuid) from public;
grant execute on function public.join_board_as_student(uuid) to authenticated;
revoke all on function public.join_board_by_legacy_id(text) from public;
grant execute on function public.join_board_by_legacy_id(text) to authenticated;

alter table public.boards enable row level security;
alter table public.board_members enable row level security;
alter table public.sections enable row level security;
alter table public.posts enable row level security;
alter table public.post_moderation enable row level security;

grant select on public.boards to authenticated;
grant select on public.board_members to authenticated;
grant select, insert, update, delete on public.posts to authenticated;
grant select on public.sections to authenticated;
grant select, insert, update on public.post_moderation to authenticated;

drop policy if exists boards_member_select on public.boards;
create policy boards_member_select
on public.boards for select to authenticated
using (public.is_board_member(id));

drop policy if exists boards_create_own on public.boards;
create policy boards_create_own
on public.boards for insert to authenticated
with check (created_by = auth.uid());

drop policy if exists boards_teacher_update on public.boards;
create policy boards_teacher_update
on public.boards for update to authenticated
using (public.is_board_teacher(id))
with check (public.is_board_teacher(id));

drop policy if exists boards_teacher_delete on public.boards;
create policy boards_teacher_delete
on public.boards for delete to authenticated
using (public.is_board_teacher(id));

drop policy if exists board_members_self_select on public.board_members;
create policy board_members_self_select
on public.board_members for select to authenticated
using (user_id = auth.uid() or public.is_board_teacher(board_id));

drop policy if exists board_members_teacher_manage on public.board_members;
create policy board_members_teacher_manage
on public.board_members for all to authenticated
using (public.is_board_teacher(board_id))
with check (public.is_board_teacher(board_id));

drop policy if exists sections_member_select on public.sections;
create policy sections_member_select
on public.sections for select to authenticated
using (public.is_board_member(board_id));

drop policy if exists sections_teacher_insert on public.sections;
create policy sections_teacher_insert
on public.sections for insert to authenticated
with check (public.is_board_teacher(board_id));

drop policy if exists sections_teacher_update on public.sections;
create policy sections_teacher_update
on public.sections for update to authenticated
using (public.is_board_teacher(board_id))
with check (public.is_board_teacher(board_id));

drop policy if exists sections_teacher_delete on public.sections;
create policy sections_teacher_delete
on public.sections for delete to authenticated
using (public.is_board_teacher(board_id));

drop policy if exists posts_member_select on public.posts;
create policy posts_member_select
on public.posts for select to authenticated
using (public.is_board_member(board_id));

drop policy if exists posts_member_insert on public.posts;
create policy posts_member_insert
on public.posts for insert to authenticated
with check (
  public.is_board_member(board_id)
  and author_user_id = auth.uid()
);

drop policy if exists posts_author_or_teacher_update on public.posts;
create policy posts_author_or_teacher_update
on public.posts for update to authenticated
using (
  author_user_id = auth.uid()
  or public.is_board_teacher(board_id)
)
with check (
  author_user_id = auth.uid()
  or public.is_board_teacher(board_id)
);

drop policy if exists posts_author_or_teacher_delete on public.posts;
create policy posts_author_or_teacher_delete
on public.posts for delete to authenticated
using (
  author_user_id = auth.uid()
  or public.is_board_teacher(board_id)
);

drop policy if exists moderation_member_select on public.post_moderation;
create policy moderation_member_select
on public.post_moderation for select to authenticated
using (
  exists (
    select 1
    from public.posts
    where posts.id = post_moderation.post_id
      and public.is_board_member(posts.board_id)
  )
);

drop policy if exists moderation_teacher_insert on public.post_moderation;
create policy moderation_teacher_insert
on public.post_moderation for insert to authenticated
with check (
  exists (
    select 1
    from public.posts
    where posts.id = post_moderation.post_id
      and public.is_board_teacher(posts.board_id)
  )
);

drop policy if exists moderation_teacher_update on public.post_moderation;
create policy moderation_teacher_update
on public.post_moderation for update to authenticated
using (
  exists (
    select 1
    from public.posts
    where posts.id = post_moderation.post_id
      and public.is_board_teacher(posts.board_id)
  )
)
with check (
  exists (
    select 1
    from public.posts
    where posts.id = post_moderation.post_id
      and public.is_board_teacher(posts.board_id)
  )
);

-- Phase 1-C: publish posts changes only. This is intentionally idempotent.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1
       from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'posts'
     ) then
    alter publication supabase_realtime add table public.posts;
  end if;
end;
$$;
