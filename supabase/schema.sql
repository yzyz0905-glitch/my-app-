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
  display_order numeric,
  wall_display_order numeric,
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

alter table public.posts add column if not exists display_order numeric;
alter table public.posts add column if not exists wall_display_order numeric;

create unique index if not exists posts_board_id_id_uidx on public.posts(board_id, id);

create table if not exists public.post_likes (
  board_id uuid not null references public.boards(id) on delete cascade,
  post_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id),
  foreign key (board_id, post_id) references public.posts(board_id, id) on delete cascade
);

create table if not exists public.post_comments (
  id uuid primary key default gen_random_uuid(),
  board_id uuid not null references public.boards(id) on delete cascade,
  post_id uuid not null,
  author_user_id uuid not null references auth.users(id) on delete cascade,
  author_label text not null,
  content text not null check (char_length(trim(content)) > 0),
  created_at timestamptz not null default now(),
  foreign key (board_id, post_id) references public.posts(board_id, id) on delete cascade
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
create index if not exists post_likes_board_id_idx on public.post_likes(board_id);
create index if not exists post_comments_board_id_created_at_idx on public.post_comments(board_id, created_at);
create index if not exists post_comments_post_id_idx on public.post_comments(post_id);
create index if not exists post_moderation_hidden_idx on public.post_moderation(is_hidden);

alter table public.post_comments replica identity full;

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

create or replace function public.set_post_moderation_state()
returns trigger
language plpgsql
as $$
begin
  if new.is_hidden then
    new.hidden_by = auth.uid();
    new.hidden_at = now();
  else
    new.hidden_by = null;
    new.hidden_at = null;
  end if;
  return new;
end;
$$;

drop trigger if exists post_moderation_set_state on public.post_moderation;
create trigger post_moderation_set_state
before insert or update on public.post_moderation
for each row execute function public.set_post_moderation_state();

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

create or replace function public.reorder_board_wall_posts(
  target_board_id uuid,
  ordered_post_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  locked_board_id uuid;
  expected_post_count integer;
  updated_post_count integer;
begin
  if auth.uid() is null then
    raise exception 'authentication required';
  end if;
  if not public.is_board_teacher(target_board_id) then
    raise exception 'board teacher role required';
  end if;

  select id into locked_board_id
  from public.boards
  where id = target_board_id
  for update;
  if locked_board_id is null then
    raise exception 'board not found';
  end if;

  perform id
  from public.posts
  where board_id = target_board_id
  for update;

  select count(*) into expected_post_count
  from public.posts
  where board_id = target_board_id;

  if ordered_post_ids is null
     or cardinality(ordered_post_ids) <> expected_post_count then
    raise exception 'post list does not match board';
  end if;
  if (
    select count(distinct requested.post_id)
    from unnest(ordered_post_ids) as requested(post_id)
  ) <> cardinality(ordered_post_ids) then
    raise exception 'post list contains duplicates or null values';
  end if;
  if exists (
    select 1
    from unnest(ordered_post_ids) as requested(post_id)
    where not exists (
      select 1
      from public.posts
      where id = requested.post_id
        and board_id = target_board_id
    )
  ) then
    raise exception 'post does not belong to board';
  end if;
  if exists (
    select 1
    from unnest(ordered_post_ids) with ordinality as ordered(post_id, ordinality)
    join public.posts as current_post on current_post.id = ordered.post_id
    where current_post.board_id = target_board_id
      and current_post.pinned
      and exists (
        select 1
        from unnest(ordered_post_ids) with ordinality as preceding(preceding_post_id, ordinality)
        join public.posts as preceding_post on preceding_post.id = preceding.preceding_post_id
        where preceding.ordinality < ordered.ordinality
          and preceding_post.board_id = target_board_id
          and not preceding_post.pinned
      )
  ) then
    raise exception 'pinned posts must precede regular posts';
  end if;

  update public.posts as post
  set wall_display_order = (ordered.ordinality - 1)::numeric
  from unnest(ordered_post_ids) with ordinality as ordered(post_id, ordinality)
  where post.id = ordered.post_id
    and post.board_id = target_board_id;
  get diagnostics updated_post_count = row_count;
  if updated_post_count <> expected_post_count then
    raise exception 'not all posts were reordered';
  end if;
end;
$$;

create or replace function public.reorder_board_sections(
  target_board_id uuid,
  ordered_section_ids uuid[]
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  locked_board_id uuid;
  expected_section_count integer;
begin
  if auth.uid() is null then
    raise exception 'authentication required';
  end if;
  if not public.is_board_teacher(target_board_id) then
    raise exception 'board teacher role required';
  end if;

  select id into locked_board_id
  from public.boards
  where id = target_board_id
  for update;
  if locked_board_id is null then
    raise exception 'board not found';
  end if;

  select count(*) into expected_section_count
  from public.sections
  where board_id = target_board_id;

  if ordered_section_ids is null
     or cardinality(ordered_section_ids) <> expected_section_count then
    raise exception 'section list does not match board';
  end if;
  if (
    select count(distinct requested.section_id)
    from unnest(ordered_section_ids) as requested(section_id)
  ) <> cardinality(ordered_section_ids) then
    raise exception 'section list contains duplicates or null values';
  end if;
  if exists (
    select 1
    from unnest(ordered_section_ids) as requested(section_id)
    where not exists (
      select 1
      from public.sections
      where id = requested.section_id
        and board_id = target_board_id
    )
  ) then
    raise exception 'section does not belong to board';
  end if;

  update public.sections as section
  set sort_order = (ordered.ordinality - 1)::integer
  from unnest(ordered_section_ids) with ordinality as ordered(section_id, ordinality)
  where section.id = ordered.section_id
    and section.board_id = target_board_id;
end;
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
revoke all on function public.reorder_board_sections(uuid, uuid[]) from public;
grant execute on function public.reorder_board_sections(uuid, uuid[]) to authenticated;
revoke all on function public.reorder_board_wall_posts(uuid, uuid[]) from public;
grant execute on function public.reorder_board_wall_posts(uuid, uuid[]) to authenticated;

alter table public.boards enable row level security;
alter table public.board_members enable row level security;
alter table public.sections enable row level security;
alter table public.posts enable row level security;
alter table public.post_likes enable row level security;
alter table public.post_comments enable row level security;
alter table public.post_moderation enable row level security;

grant select on public.boards to authenticated;
grant select on public.board_members to authenticated;
grant select, insert, update, delete on public.posts to authenticated;
grant select on public.sections to authenticated;
grant select, insert, delete on public.post_likes to authenticated;
grant select, insert, update, delete on public.post_comments to authenticated;
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

drop policy if exists post_likes_member_select on public.post_likes;
create policy post_likes_member_select
on public.post_likes for select to authenticated
using (public.is_board_member(board_id));

drop policy if exists post_likes_self_insert on public.post_likes;
create policy post_likes_self_insert
on public.post_likes for insert to authenticated
with check (
  user_id = auth.uid()
  and public.is_board_member(board_id)
);

drop policy if exists post_likes_self_delete on public.post_likes;
create policy post_likes_self_delete
on public.post_likes for delete to authenticated
using (
  user_id = auth.uid()
  and public.is_board_member(board_id)
);

drop policy if exists post_comments_member_select on public.post_comments;
create policy post_comments_member_select
on public.post_comments for select to authenticated
using (public.is_board_member(board_id));

drop policy if exists post_comments_member_insert on public.post_comments;
create policy post_comments_member_insert
on public.post_comments for insert to authenticated
with check (
  author_user_id = auth.uid()
  and public.is_board_member(board_id)
);

drop policy if exists post_comments_author_update on public.post_comments;
create policy post_comments_author_update
on public.post_comments for update to authenticated
using (
  author_user_id = auth.uid()
  and public.is_board_member(board_id)
)
with check (
  author_user_id = auth.uid()
  and public.is_board_member(board_id)
);

drop policy if exists post_comments_author_delete on public.post_comments;
create policy post_comments_author_delete
on public.post_comments for delete to authenticated
using (
  author_user_id = auth.uid()
  and public.is_board_member(board_id)
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

-- Publish board data changes. This is intentionally idempotent.
do $$
declare
  realtime_table text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach realtime_table in array array['posts', 'post_comments', 'post_likes', 'post_moderation'] loop
      if not exists (
        select 1
        from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename = realtime_table
      ) then
        execute format('alter publication supabase_realtime add table public.%I', realtime_table);
      end if;
    end loop;
  end if;
end;
$$;
