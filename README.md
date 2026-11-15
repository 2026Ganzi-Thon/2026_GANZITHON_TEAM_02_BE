# 메에일 (Meail) — Backend

> 2026 간지톤 TEAM 02 · 백엔드 저장소

하루하루 작은 실천을 쌓아 100일 목표를 이루도록 돕는 서비스 **메에일**의 백엔드입니다.
오늘의 컨디션에 맞춰 목표 분량을 조절하고, 양 모양 기록판에 실천을 기록하며,
지역의 지원 프로그램·상담기관 정보를 함께 제공합니다.

<br>

## 🛠 기술 스택

| 구분 | 사용 기술 |
| --- | --- |
| Backend (BaaS) | **Supabase** |
| Database | PostgreSQL (Supabase) |
| Auth | Supabase Auth — 카카오 로그인 |
| API | Supabase Data API (PostgREST) · RPC |
| 보안 | Row Level Security (RLS) |
| Frontend 연동 | `@supabase/supabase-js` (React + TypeScript) |

<br>

## 🏗 아키텍처

```
┌──────────────┐   supabase-js    ┌───────────────────────────────┐
│   Frontend   │ ───────────────▶ │           Supabase            │
│ React + TS   │   (anon key)     │                               │
└──────────────┘                  │  Auth (Kakao)                 │
                                  │    └─ 가입 시 profiles 자동 생성 │
                                  │  Data API ─▶ PostgreSQL + RLS │
                                  │  RPC: get_home_summary()      │
                                  └───────────────────────────────┘
```

별도 API 서버 없이 Supabase를 백엔드로 사용합니다.
FE는 `supabase-js`로 테이블에 직접 접근하고, **접근 권한은 DB의 RLS 정책이 강제**합니다.

<br>

## 🗂 데이터베이스 구조

| 테이블 | 설명 | 접근 권한 |
| --- | --- | --- |
| `profiles` | 닉네임, 지역, 관심 분야 (`auth.users`와 1:1) | 본인만 조회·수정 |
| `conditions` | 오늘의 컨디션(`OK`/`HARD`)과 필요한 도움 | 본인만 · 하루 1회 |
| `goals` | 100일 목표 (`DRAFT` → `ACTIVE` → `ENDED`) | 본인만 |
| `goal_weeks` | 목표별 1~4주차 계획 | 본인 목표만 |
| `daily_records` | 오늘의 목표, 실천/쉬어감 기록, 난이도 피드백 | 본인만 · 오늘 것만 수정 |
| `memos` | 그날의 마음 메모 | 본인만 |
| `support_programs` | 지역 지원 프로그램 | 누구나 조회 |
| `support_organizations` | 상담·지원 기관 | 누구나 조회 |

### 관계

```
auth.users ─1:1─ profiles ─┬─ conditions      (1:N, 하루 1개)
                           ├─ memos           (1:N)
                           └─ goals ─┬─ goal_weeks     (1:4)
                                     └─ daily_records  (1:N, 하루 1개)
```

<br>

## 🔒 보안 및 데이터 규칙

- **RLS 전 테이블 적용** — 개인 데이터는 `auth.uid()` 기준으로 본인 것만 접근 가능
- **한국 시간 기준 하루** — `kst_today()` 함수로 날짜 판정 (UTC 새벽 기록이 전날로 저장되는 문제 방지)
- **하루 1회 제약** — 컨디션·일별 기록은 `unique(user_id, date)` / `unique(goal_id, date)`
- **과거 기록 보호** — 컨디션·일별 기록은 오늘 날짜만 등록·수정 가능
- **컨디션 재선택 불가** — 컬럼 단위 권한으로 `help_type`만 수정 허용
- **활성 목표 1개** — 부분 unique 인덱스로 사용자당 `ACTIVE` 목표 1개 보장
- **입력값 검증** — enum 값 `CHECK` 제약, 텍스트 길이 제한
- **트리거 함수 보호** — 내부용 함수는 외부 호출 불가

<br>

## ⚙️ 주요 기능 (DB 레벨)

| 기능 | 구현 |
| --- | --- |
| 카카오 가입 시 프로필 생성 | `on_auth_user_created` 트리거 → `handle_new_user()` |
| 홈 대시보드 통합 조회 | `get_home_summary()` RPC — 컨디션·오늘 목표·진행 일수·기록판·4주 계획을 한 번에 반환 |
| 수정 시각 자동 기록 | `set_updated_at()` 트리거 |

<br>

## 🚀 재현 방법

1. [Supabase](https://supabase.com)에서 새 프로젝트 생성 (Region: Seoul)
2. Dashboard → **SQL Editor** → [`supabase/schema.sql`](./supabase/schema.sql) 전체 실행
3. Dashboard → **Authentication → Providers → Kakao** 활성화 후 카카오 REST API 키 입력
4. 지원 정보 데이터 업로드: **Table Editor → Import data from CSV**

<br>

## 💻 Frontend 연동

```bash
npm install @supabase/supabase-js
```

```ts
// .env
VITE_SUPABASE_URL=
VITE_SUPABASE_ANON_KEY=
```

```ts
import { createClient } from '@supabase/supabase-js'

export const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_ANON_KEY
)

// 홈 화면
const { data } = await supabase.rpc('get_home_summary')
```

> - `profiles`는 로그인 시 자동 생성되므로 `update`로만 저장합니다.
> - `conditions`는 `insert`로 저장하고, 도움 선택(`help_type`)만 `update`합니다.

<br>

## 📁 디렉토리 구조

```
.
├── README.md
└── supabase/
    └── schema.sql      # 테이블 · RLS · 트리거 · RPC 전체 정의
```
