# Gmail + Calendar 자동화 시스템

**Ollama 로컬 LLM 기반 AI 이메일 자동 분류 솔루션.**

Mac Mini 같은 미니 PC에서 crontab으로 구동. Google API 직접 호출 + Ollama 로컬 LLM으로 AI 판단. 외부 API 의존 없이 로컬에서 완결.

## 요구사항

- **macOS** (Apple Silicon 권장, Mac Mini M4 16GB 기준 개발)
- **[Ollama](https://ollama.com)** — 로컬 LLM 서버
- Python 3.10+, Google Cloud OAuth 인증

## 아키텍처

```text
┌─────────────────────────────────────────────────────────────┐
│  Mac Mini (이 프로젝트)                                      │
│                                                             │
│  ┌─────────────┐    ┌──────────────┐    ┌───────────────┐  │
│  │ email-      │    │ Google API   │    │ Ollama LLM    │  │
│  │ watcher.sh  │───▶│ gmail / cal  │    │ (qwen3:14b)   │  │
│  │ cron 5분    │    │ lib/         │    │ Phase2: 개별  │  │
│  │             │───▶│ google_api.py│    │               │  │
│  └──────┬──────┘    └──────────────┘    └───────────────┘  │
│         │                                                   │
│         │ 미결정 건                                          │
│         ▼                                                   │
│  ┌──────────────┐                                           │
│  │ data/queue/  │ ◀── 1건 = 1 JSON 파일                    │
│  │ classifi../  │                                           │
│  │ calendars/   │                                           │
│  │ labels/      │                                           │
│  └──────┬───────┘                                           │
│         │                                                   │
│         │ 외부 시스템이 큐 읽기 → 사용자에게 질문            │
│         │ 사용자 답변 후 → feedback-processor.sh 호출        │
│         ▼                                                   │
│  ┌──────────────┐    ┌──────────────┐                      │
│  │ feedback-    │───▶│ data/memory/ │ 자동 학습             │
│  │ processor.sh │    │ patterns     │                      │
│  │ (외부 호출)  │    │ rules        │                      │
│  └──────────────┘    │ corrections  │                      │
│                      └──────────────┘                      │
│  ┌──────────────┐           ▲                               │
│  │ memory-      │───────────┘ 매일 최적화                 │
│  │ consolidator │    Ollama LLM                             │
│  │ cron 매일    │                                           │
│  └──────────────┘                                           │
└─────────────────────────────────────────────────────────────┘
         ▲                    │
         │ 큐 파일 읽기        │ feedback-processor.sh 호출
         │                    ▼
┌─────────────────────────────────────────────────────────────┐
│  별도 프로젝트 (알림 봇)                                      │
│                                                             │
│  큐 감지 → 질문 생성 → 카카오톡 전송                        │
│  사용자 답변 → 답변 해석 → feedback-processor 호출           │
└─────────────────────────────────────────────────────────────┘
```

## 처리 흐름

### 1. 메일 분류 (email-watcher.sh, cron 5분)

```text
미처리 스레드 20개 조회 (Gmail API batch)
    ↓
Phase 1: 제목+발신자로 메모리 패턴 매칭 (LLM 미사용, 프로그래밍 방식)
    ↓
fast → 즉시 라벨 + 보관  |  need_body → Phase 2로
    ↓
Phase 2: 본문 포함 개별 LLM 호출 (Ollama)
    ↓
자동 분류 → 라벨 + 보관  |  미결정 → 큐 파일 생성  |  일정 감지 → 캘린더 큐
    ↓
fast_patterns 학습: "이건 제목만 봐도 됐다" → sender-patterns에 저장
    ↓
_processed 라벨로 처리 완료 표시 (멱등)

※ Phase 2에서 학습된 패턴은 다음 실행부터 Phase 1 fast로 처리됨
→ 시간이 지날수록 Phase 2 호출 감소, Phase 1 fast 비율 증가
```

### 2. 피드백 처리 (feedback-processor.sh, 외부 호출)

```bash
# 사용법
bash bin/feedback-processor.sh <큐파일> <명령> [인수]

# 명령:
#   label <라벨명>    라벨 적용 + 보관
#   delete            삭제 (휴지통)
#   archive           라벨 없이 보관만
#   skip              큐에서만 제거 (아무것도 안 함)
#   calendar          캘린더 일정 등록

# 예시
bash bin/feedback-processor.sh data/queue/classifications/pending-abc.json label 광고
bash bin/feedback-processor.sh data/queue/classifications/pending-abc.json delete
bash bin/feedback-processor.sh data/queue/classifications/pending-abc.json archive
bash bin/feedback-processor.sh data/queue/classifications/pending-abc.json skip
bash bin/feedback-processor.sh data/queue/calendars/cal-abc.json calendar
```

AI 제안과 다른 라벨을 지정하면 자동으로 오분류 학습:
- 발신자 패턴 업데이트 (sender-patterns.json)
- 수정 규칙 추가 (classification-rules.json)
- 이력 기록 (user-corrections.jsonl)
- 큐 파일 삭제

### 3. 메모리 통합 (memory-consolidator.sh, cron 매일)

LLM으로 축적된 메모리 분석:
- 중복 패턴 병합, 미사용 패턴 제거
- 규칙 간 충돌 감지, 정확도 리포트

## 큐 파일 인터페이스

외부 시스템(알림 봇 등)은 큐 파일로만 연동합니다. API나 DB 불필요.

### 분류 큐 (data/queue/classifications/*.json)

```json
{
  "id": "pending-19d1eb485a94",
  "created": "2026-03-25 18:58",
  "email_id": "19d1eb485a942cb3",
  "account": "your-email@gmail.com",
  "subject": "미팅일정",
  "from": "홍길동 <example@naver.com>",
  "summary": "부산에서 미팅 교육 일정 조율 요청",
  "ai_suggestion": {
    "label": "광고",
    "confidence": 0.4,
    "reason": "분류 불확실, 사용자 확인 필요"
  },
  "decision": null,
  "user_label": null,
  "user_note": null
}
```

### 캘린더 큐 (data/queue/calendars/*.json)

```json
{
  "id": "cal-19cb1251a6bb",
  "source_email": "사업비 사용실적보고서 제출 안내",
  "account": "your-email@gmail.com",
  "proposal": {
    "type": "deadline",
    "summary": "사업비 사용실적보고서 제출 마감",
    "start": "2026-03-31T18:00:00+09:00",
    "end": "2026-03-31T18:00:00+09:00",
    "location": null
  },
  "confidence": 0.95,
  "decision": null
}
```

### 외부 연동 흐름

```text
1. 큐 디렉토리 감시 (fswatch 또는 polling)
2. decision: null인 파일 발견
3. 사용자에게 보낼 질문 생성
4. 카카오톡 등으로 전송
5. 사용자 답변 수신
6. 답변 해석 → decision, label 결정
7. feedback-processor.sh 호출:
   bash bin/feedback-processor.sh <파일경로> <label|delete|archive|skip|calendar> [인수]
8. 처리 완료 (실행 + 학습 + 큐 파일 삭제)
```

## 로컬 LLM 설정

Ollama REST API 사용. `lib/llm_call.py`가 래퍼.

| 환경변수 | 기본값 | 설명 |
| --- | --- | --- |
| `LLM_MODEL` | `qwen3:14b` | Ollama 모델명 |
| `LLM_BASE_URL` | `http://localhost:11434` | Ollama 서버 URL |

```bash
# Ollama 설치 후 모델 다운로드
ollama pull qwen3:14b

# 환경변수로 모델 변경 가능
LLM_MODEL=llama3:8b bash bin/email-watcher.sh
```

## 디렉토리 구조

```text
├── bin/                          # 실행 스크립트
│   ├── email-watcher.sh          #   메일 분류 (cron 5분)
│   ├── feedback-processor.sh     #   피드백 처리 (외부 호출)
│   └── memory-consolidator.sh    #   메모리 최적화 (cron 매일)
│
├── lib/                          # 공통 라이브러리
│   ├── common.sh                 #   경로, 유틸, 락 함수
│   ├── classifier.sh             #   패턴 매칭 + LLM 프롬프트 + 결과 처리
│   ├── gmail-actions.sh          #   Gmail 검색/라벨 래핑
│   ├── calendar-actions.sh       #   캘린더 래핑
│   ├── google_api.py             #   Google API OAuth 호출
│   └── llm_call.py               #   Ollama REST API 래퍼
│
├── config/                       # 설정
│   ├── accounts.json             #   Gmail 계정 (.gitignore)
│   ├── accounts.example.json     #   계정 설정 예시
│   ├── community/                #   커뮤니티 프리빌트 패턴
│   └── prompts/                  #   LLM 프롬프트 템플릿
│       ├── pre-classify.txt      #     Phase 1 사전 분류
│       ├── classify-email.txt    #     Phase 2 상세 분류
│       └── consolidate-memory.txt#     메모리 통합
│
├── data/                         # 런타임 (.gitignore)
│   ├── labels.json               #   사용자 라벨 정의
│   ├── memory/                   #   학습 데이터
│   │   ├── sender-patterns.json  #     발신자 → 라벨
│   │   ├── classification-rules.json  # 키워드 규칙
│   │   └── user-corrections.jsonl#     수정 이력 (append-only)
│   └── queue/                    #   피드백 큐 (1건 = 1파일)
│       ├── classifications/      #     분류 미결정
│       ├── calendars/            #     캘린더 미결정
│       └── labels/               #     라벨 제안
│
├── logs/                         # 로그 (.gitignore)
└── .credentials/                 # OAuth 인증 (.gitignore)
```

## 명령어

```bash
# 메일 분류 (1회, 최근 30일)
bash bin/email-watcher.sh

# 전체 미처리
bash bin/email-watcher.sh --all

# N라운드 반복
bash bin/email-watcher.sh --rounds=5

# 전체 + 빌 때까지
bash bin/email-watcher.sh --all --repeat

# 피드백 처리
bash bin/feedback-processor.sh <큐파일> <decision> [라벨]

# 메모리 통합
bash bin/memory-consolidator.sh

# Google OAuth 인증
python3 lib/google_api.py auth --account EMAIL
```

## 설치

```bash
# 1. Ollama 설치 (https://ollama.com)
ollama pull qwen3:14b

# 2. Python 의존성
pip3 install google-auth google-auth-oauthlib google-api-python-client

# 3. Google OAuth 설정
cp credentials.json .credentials/
cp config/accounts.example.json config/accounts.json  # 계정 설정 편집
python3 lib/google_api.py auth --account YOUR_EMAIL

# 4. Cron 등록
crontab crontab.txt
```

## 라이선스

MIT
