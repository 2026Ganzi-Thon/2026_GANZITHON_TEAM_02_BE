-- =========================================================
-- 아리톤 메에일 MVP 스키마 (Supabase)
-- =========================================================


-- ---------------------------------------------------------
-- 0. 공통 함수
-- ---------------------------------------------------------

-- 한국 시간 기준 "오늘" (DB 기본 UTC라 새벽 기록이 전날로 가는 것 방지)
create or replace function public.kst_today()
returns date
language sql
stable
set search_path = ''
as $$
  select (now() at time zone 'Asia/Seoul')::date;
$$;

-- updated_at 자동 갱신
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;


-- ---------------------------------------------------------
-- 1. profiles (명세서 5. User / Profile)
--    auth.users(카카오 로그인)와 1:1. 가입 시 트리거로 자동 생성.
--    가입 순간엔 값이 없으므로 nickname/region은 nullable,
--    로그인 직후 FE가 온보딩에서 받은 값으로 update.
-- ---------------------------------------------------------
create table public.profiles (
  id                  uuid primary key references auth.users (id) on delete cascade,
  nickname            text check (length(nickname) <= 20),
  region              text check (length(region) <= 100),   -- 예: '경기도 부천시 소사구'
  interests           text[] not null default '{}' check (cardinality(interests) <= 20),
  interest_undecided  boolean not null default false,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create trigger profiles_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- 카카오 로그인으로 auth.users에 행이 생기면 profiles 자동 생성
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id) values (new.id);
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- 이 SQL 실행 전에 이미 가입(테스트 로그인)한 사용자가 있으면 profiles 보충
insert into public.profiles (id)
select id from auth.users
on conflict (id) do nothing;

alter table public.profiles enable row level security;

create policy "profiles: 본인 조회" on public.profiles
  for select to authenticated
  using ((select auth.uid()) = id);

create policy "profiles: 본인 수정" on public.profiles
  for update to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);


-- ---------------------------------------------------------
-- 2. conditions (명세서 6. Condition / Help)
--    하루 1회, 재선택 불가. help_type만 나중에 update 가능.
-- ---------------------------------------------------------
create table public.conditions (
  id          bigint generated always as identity primary key,
  user_id     uuid not null default auth.uid()
                references public.profiles (id) on delete cascade,
  date        date not null default public.kst_today(),
  condition   text not null check (condition in ('OK', 'HARD')),
  help_type   text check (help_type in ('SMALL_GOAL', 'MEMO', 'PROGRAM', 'COUNSELING', 'REST')),
  created_at  timestamptz not null default now(),
  unique (user_id, date),         -- 하루 1회 (중복 insert 시 23505 에러)
  check (help_type is null or condition = 'HARD')   -- 도움 선택은 '힘들어요'일 때만
);

alter table public.conditions enable row level security;

create policy "conditions: 본인 조회" on public.conditions
  for select to authenticated
  using ((select auth.uid()) = user_id);

create policy "conditions: 본인 오늘 것만 등록" on public.conditions
  for insert to authenticated
  with check ((select auth.uid()) = user_id and date = public.kst_today());

create policy "conditions: 본인 오늘 것 도움 선택" on public.conditions
  for update to authenticated
  using ((select auth.uid()) = user_id and date = public.kst_today())
  with check ((select auth.uid()) = user_id and date = public.kst_today());

-- 재선택 불가: update는 help_type 컬럼만 허용
revoke update on public.conditions from anon, authenticated;
grant update (help_type) on public.conditions to authenticated;


-- ---------------------------------------------------------
-- 3. goals + goal_weeks (명세서 7. Goal / AI Plan)
--    draft_id / goal_id 를 하나로 합치고 status로 구분.
-- ---------------------------------------------------------
create table public.goals (
  id           bigint generated always as identity primary key,
  user_id      uuid not null default auth.uid()
                 references public.profiles (id) on delete cascade,
  title        text not null check (length(title) <= 200),
  description  text check (length(description) <= 2000),
  status       text not null default 'DRAFT'
                 check (status in ('DRAFT', 'ACTIVE', 'ENDED')),
  started_at   date,                         -- 확정(ACTIVE) 시점에 채움
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (status <> 'ACTIVE' or started_at is not null)
);

-- 사용자당 활성 목표는 1개
create unique index goals_one_active_per_user
  on public.goals (user_id) where status = 'ACTIVE';

create trigger goals_updated_at
  before update on public.goals
  for each row execute function public.set_updated_at();

alter table public.goals enable row level security;

create policy "goals: 본인 전체" on public.goals
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);


create table public.goal_weeks (
  id           bigint generated always as identity primary key,
  goal_id      bigint not null references public.goals (id) on delete cascade,
  week_number  int not null check (week_number between 1 and 4),
  title        text not null check (length(title) <= 200),
  description  text check (length(description) <= 2000),
  unique (goal_id, week_number)
);

alter table public.goal_weeks enable row level security;

create policy "goal_weeks: 본인 목표 것만" on public.goal_weeks
  for all to authenticated
  using (goal_id in (select id from public.goals where user_id = (select auth.uid())))
  with check (goal_id in (select id from public.goals where user_id = (select auth.uid())));


-- ---------------------------------------------------------
-- 4. daily_records (명세서 1-1 ~ 1-4: 오늘 목표 / 실천 / 쉬어감 / 피드백)
--    오늘 목표 제목·설명, 기록 상태, 피드백을 한 행에.
-- ---------------------------------------------------------
create table public.daily_records (
  id           bigint generated always as identity primary key,
  user_id      uuid not null default auth.uid()
                 references public.profiles (id) on delete cascade,
  goal_id      bigint not null references public.goals (id) on delete cascade,
  date         date not null default public.kst_today(),
  title        text check (length(title) <= 200),      -- 오늘 목표 (수정 가능)
  description  text check (length(description) <= 2000),
  status       text check (status in ('DONE', 'REST')),          -- null = 기록 없음
  feedback     text check (feedback in ('MANAGEABLE', 'BURDENSOME')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (goal_id, date),
  check (feedback is null or status = 'DONE')       -- 피드백은 실천 완료 시에만
);

create trigger daily_records_updated_at
  before update on public.daily_records
  for each row execute function public.set_updated_at();

alter table public.daily_records enable row level security;

create policy "daily_records: 본인 조회" on public.daily_records
  for select to authenticated
  using ((select auth.uid()) = user_id);

create policy "daily_records: 본인 오늘 것 등록" on public.daily_records
  for insert to authenticated
  with check (
    (select auth.uid()) = user_id
    and date = public.kst_today()
    and goal_id in (select id from public.goals where user_id = (select auth.uid()))
  );

create policy "daily_records: 본인 오늘 것 수정" on public.daily_records
  for update to authenticated
  using ((select auth.uid()) = user_id and date = public.kst_today())
  with check (
    (select auth.uid()) = user_id
    and date = public.kst_today()
    and goal_id in (select id from public.goals where user_id = (select auth.uid()))
  );

create policy "daily_records: 본인 오늘 것 삭제" on public.daily_records
  for delete to authenticated
  using ((select auth.uid()) = user_id and date = public.kst_today());


-- ---------------------------------------------------------
-- 5. memos (명세서 9. Memo)
-- ---------------------------------------------------------
create table public.memos (
  id          bigint generated always as identity primary key,
  user_id     uuid not null default auth.uid()
                references public.profiles (id) on delete cascade,
  content     text not null check (length(trim(content)) between 1 and 5000),
  created_at  timestamptz not null default now(),   -- 화면 표시 날짜 기준 (수정해도 유지)
  updated_at  timestamptz not null default now()
);

create index memos_user_created on public.memos (user_id, created_at desc);

create trigger memos_updated_at
  before update on public.memos
  for each row execute function public.set_updated_at();

alter table public.memos enable row level security;

create policy "memos: 본인 전체" on public.memos
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);


-- ---------------------------------------------------------
-- 6. 지원 정보 (명세서 10. Support / Counseling)
--    비로그인 포함 누구나 읽기 전용. 데이터는 SQL Editor / seed.sql로 업로드
--    (SQL Editor는 RLS를 우회하므로 insert 정책 불필요)
-- ---------------------------------------------------------
create table public.support_programs (
  id                  bigint generated always as identity primary key,
  title               text not null,
  description         text,
  operator            text,
  region              text,
  target              text,
  schedule            text,
  place               text,
  cost                text,
  eligibility         text,
  application_method  text,
  official_url        text,
  registered_at       timestamptz not null default now()
);

create index support_programs_region on public.support_programs (region, registered_at desc);

alter table public.support_programs enable row level security;

create policy "support_programs: 누구나 조회" on public.support_programs
  for select to anon, authenticated
  using (true);


create table public.support_organizations (
  id                    bigint generated always as identity primary key,
  name                  text not null,
  description           text,
  region                text,                 -- 명세서엔 없지만 지역 필터용으로 추가
  target                text,
  services              text[] not null default '{}',
  address               text,
  hours                 text,
  phone                 text,
  usage_method          text,
  reservation_required  boolean,              -- 확인 안 된 경우 null
  official_url          text,
  registered_at         timestamptz not null default now()
);

create index support_organizations_region on public.support_organizations (region, registered_at desc);

alter table public.support_organizations enable row level security;

create policy "support_organizations: 누구나 조회" on public.support_organizations
  for select to anon, authenticated
  using (true);


-- ---------------------------------------------------------
-- 6-1. 권한 (Data API 노출)
--   "Automatically expose new tables"를 껐어도 동작하도록 명시적으로 부여.
--   실제 접근 범위는 위 RLS 정책이 결정.
-- ---------------------------------------------------------
grant select, update on public.profiles to authenticated;
grant select, insert on public.conditions to authenticated;
grant update (help_type) on public.conditions to authenticated;
grant select, insert, update, delete on public.goals, public.goal_weeks,
  public.daily_records, public.memos to authenticated;

-- 지원 정보(공개 정보)는 비로그인 포함 누구나 "조회만" 가능
revoke insert, update, delete, truncate on public.support_programs,
  public.support_organizations from authenticated;
grant select on public.support_programs, public.support_organizations to anon, authenticated;


-- ---------------------------------------------------------
-- 7. 홈 통합 조회 RPC (명세서 8. GET /api/home/summary 대체)
--    FE: supabase.rpc('get_home_summary')
--    security invoker → RLS 그대로 적용 (본인 데이터만)
-- ---------------------------------------------------------
create or replace function public.get_home_summary()
returns jsonb
language sql
stable
security invoker
set search_path = public
as $$
  with g as (
    select * from goals
    where user_id = auth.uid() and status = 'ACTIVE'
    limit 1
  )
  select jsonb_build_object(
    'condition',
      (select condition from conditions
        where user_id = auth.uid() and date = kst_today()),
    'today_goal',
      (select jsonb_build_object(
                'title', d.title,
                'description', d.description,
                'record_status', d.status)
         from daily_records d join g on d.goal_id = g.id
        where d.date = kst_today()),
    'goal',
      (select jsonb_build_object(
                'goal_id', g.id,
                'title', g.title,
                'description', g.description,
                'started_at', g.started_at,
                'progress_day', kst_today() - g.started_at + 1,
                'weeks', coalesce((
                   select jsonb_agg(jsonb_build_object(
                            'week_number', w.week_number,
                            'title', w.title,
                            'description', w.description)
                          order by w.week_number)
                     from goal_weeks w where w.goal_id = g.id), '[]'::jsonb))
         from g),
    'daily_records',
      coalesce((select jsonb_agg(jsonb_build_object(
                         'date', d.date,
                         'status', d.status)
                       order by d.date)
                  from daily_records d join g on d.goal_id = g.id), '[]'::jsonb)
  );
$$;

-- ---------------------------------------------------------
-- 8. 함수 실행 권한 정리
--   Postgres는 기본으로 모든 함수 실행을 PUBLIC(=anon 포함)에 허용.
--   트리거 전용 함수는 직접 호출 못 하게 막음.
-- ---------------------------------------------------------
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.set_updated_at() from public, anon, authenticated;
