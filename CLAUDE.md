# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Gmail 자동 분류 + Google Calendar 일정 등록 시스템.
Mac Mini M4 (16GB) 기준, crontab + Ollama 로컬 LLM으로 동작.
외부 API 의존 없이 로컬에서 완결되는 구조.

## Prerequisites

- macOS (Apple Silicon 권장)
- Python 3 + `google-auth`, `google-auth-oauthlib`, `google-api-python-client`
- [Ollama](https://ollama.com) — 로컬 LLM 서버
- Google Cloud OAuth 2.0 credentials (`credentials.json`)

## Quick Start

```bash
# 1. Ollama 모델 설치
ollama pull qwen3:14b

# 2. Python 의존성
pip3 install google-auth google-auth-oauthlib google-api-python-client

# 3. OAuth 인증
cp credentials.json .credentials/
cp config/accounts.example.json config/accounts.json  # 계정 설정
python3 lib/google_api.py auth --account YOUR_EMAIL

# 4. 실행
bash bin/email-watcher.sh
```

## Commands

```bash
# 메일 분류
bash bin/email-watcher.sh                    # 1회, 최근 30일
bash bin/email-watcher.sh --all              # 전체 미처리
bash bin/email-watcher.sh --all --rounds=5   # 전체, 5라운드
bash bin/email-watcher.sh --repeat           # 미처리 없을 때까지 반복

# 피드백 처리 (외부 시스템이 호출)
bash bin/feedback-processor.sh <큐파일> label <라벨명>
bash bin/feedback-processor.sh <큐파일> delete
bash bin/feedback-processor.sh <큐파일> archive
bash bin/feedback-processor.sh <큐파일> skip
bash bin/feedback-processor.sh <큐파일> calendar
bash bin/feedback-processor.sh --all         # action 설정된 전체 처리

# Google API 직접 호출
python3 lib/google_api.py gmail messages-search --query "in:inbox" --max 20 --account EMAIL
python3 lib/google_api.py gmail labels-modify THREAD_ID --add LABEL --remove INBOX --account EMAIL
python3 lib/google_api.py calendar create CAL_ID --summary TITLE --from START --to END --account EMAIL
```

## Architecture

### 실행 스크립트 (bin/)

| 스크립트 | 트리거 | 역할 |
| --- | --- | --- |
| `email-watcher.sh` | cron 5분 | Phase 1 패턴 매칭 → Phase 2 LLM 분류 |
| `feedback-processor.sh` | 외부 호출 | 사용자 결정 실행 + 메모리 학습 |
| `memory-consolidator.sh` | cron 매일 | 메모리 중복 제거/충돌 감지/최적화 |

### 분류 파이프라인

#### Phase 1: 프로그래밍 패턴 매칭 (LLM 미사용)

`classifier.sh > pre_classify()` — 순수 Python으로 메모리 패턴 매칭.

- 발신자 패턴: `@` 포함 → 이메일 정확 매칭, 없으면 도메인/서브도메인 매칭
- 키워드 규칙: confidence ≥ 0.8, 키워드 3자 이상, 제목에 포함
- 출력: `fast[]` (즉시 라벨+보관) / `need_body[]` (Phase 2로)
- 매칭 0건이면 전체를 Phase 2로 투입

#### Phase 2: LLM 상세 분류

`classifier.sh > classify_emails()` — need_body 스레드를 개별 LLM 호출.

- 스레드 전체 대화 + 메모리 컨텍스트 + 라벨 설명 포함
- 프롬프트 템플릿: `config/prompts/classify-email.txt`
- confidence < 0.6 또는 `needs_user_review=true` → 큐 파일 생성
- 일정 감지 시 캘린더 큐 파일 추가 생성

**멱등성**: `_processed` Gmail 라벨로 처리 완료 표시. `-label:_processed`로 중복 방지.

### 로컬 LLM 설정 (Ollama)

`lib/llm_call.py`가 Ollama REST API 래퍼.

| 환경변수 | 기본값 | 설명 |
| --- | --- | --- |
| `LLM_MODEL` | `qwen3:14b` | Ollama 모델명 |
| `LLM_BASE_URL` | `http://localhost:11434` | Ollama 서버 URL |

호출 흐름: `llm_call()` (common.sh) → 임시 파일 → `python3 lib/llm_call.py` → Ollama `/api/generate`

### 큐 시스템

파일 기반 메시지 큐. DB/API 불필요. 1건 = 1 JSON 파일.

```text
data/queue/
├── classifications/   분류 미결정 (pending-*.json)
├── calendars/         캘린더 미결정 (cal-*.json)
└── labels/            라벨 제안 (label-*.json)
```

외부 시스템(알림 봇 등)은 큐 파일만으로 연동:

1. `data/queue/` 감시 → `decision: null` 파일 발견
2. 사용자에게 질문 → 답변 수신
3. `bash bin/feedback-processor.sh <파일> <action> [인수]` 호출
4. 처리 완료 (Gmail 액션 + 메모리 학습 + 파일 삭제)

큐 파일 예시 (분류):

```json
{
  "id": "pending-abc123",
  "email_id": "19d1eb485a942cb3",
  "account": "your-email@gmail.com",
  "subject": "메일 제목",
  "from": "발신자 <email@example.com>",
  "summary": "AI가 생성한 메일 요약",
  "ai_suggestion": { "label": "광고", "confidence": 0.4, "reason": "분류 사유" },
  "decision": null
}
```

큐 파일 예시 (캘린더):

```json
{
  "id": "cal-abc123",
  "source_email": "메일 제목",
  "account": "your-email@gmail.com",
  "proposal": {
    "type": "deadline",
    "summary": "일정 제목",
    "start": "2026-03-31T18:00:00+09:00",
    "end": "2026-03-31T18:00:00+09:00",
    "location": null
  },
  "confidence": 0.95,
  "decision": null
}
```

### 메모리 시스템

| 파일 | 역할 | 갱신 방식 |
| --- | --- | --- |
| `data/memory/sender-patterns.json` | 발신자 도메인 → 라벨 매핑 | 자동 학습 + 피드백 |
| `data/memory/classification-rules.json` | 키워드 → 라벨 규칙 | 자동 학습 + 피드백 |
| `data/memory/user-corrections.jsonl` | 사용자 수정 이력 | append-only |

학습이 쌓일수록 Phase 1 fast 비율 증가 → LLM 호출 감소.

**커뮤니티 패턴**: 최초 실행 시 `config/community/`에서 `data/memory/`로 자동 병합. 100+ 프리빌트 패턴 (Google, Amazon, 국내 금융 등).

**학습 경로**:

- Phase 2 자동: 분류 시 "제목+발신자만으로 충분" 판단 → `fast_patterns` 반환 → 메모리 저장 → 다음부터 Phase 1 처리
- 사용자 피드백: AI 제안과 다른 라벨 선택 → 오분류 기록 + 패턴 수정 → `user-corrections.jsonl` 기록

### 동시성 제어

`data/.locks/` 디렉토리 기반 파일 락 (`mkdir` 원자적 연산).
`acquire_lock(name, timeout)` / `release_lock(name)`. 60초 이상 stale 락 자동 정리.

## Coding Conventions

- bash + python3 (Google API는 `lib/google_api.py`)
- LLM 호출은 반드시 `llm_call()` 함수 경유 (common.sh)
- 모든 bin/ 스크립트는 `source "$LIB_DIR/common.sh"` 필수
- 에러 처리: `set -euo pipefail`
- 설정값은 `config/`에서 로드 (하드코딩 금지)
- 프롬프트는 `config/prompts/` 템플릿, `{TODAY}` 플레이스홀더 치환
- 메일 삭제는 email_id/thread_id로만 (검색 쿼리 삭제 금지)
- 사용자 메시지는 한국어

## Project Structure

```text
├── bin/                          실행 스크립트
│   ├── email-watcher.sh            메일 분류 (cron 5분)
│   ├── feedback-processor.sh       피드백 처리 (외부 호출)
│   └── memory-consolidator.sh      메모리 최적화 (cron 매일)
├── lib/                          공통 라이브러리
│   ├── common.sh                   경로, 유틸, llm_call(), 락, 메모리 로드
│   ├── classifier.sh               Phase 1 패턴 매칭 + Phase 2 LLM 분류
│   ├── gmail-actions.sh            Gmail API 래핑
│   ├── calendar-actions.sh         캘린더 API 래핑
│   ├── google_api.py               Google API OAuth + Gmail/Calendar 클라이언트
│   └── llm_call.py                 Ollama REST API 래퍼
├── config/                       설정
│   ├── accounts.json               계정 설정 (.gitignore)
│   ├── accounts.example.json       계정 설정 예시
│   ├── community/                  커뮤니티 프리빌트 패턴
│   └── prompts/                    LLM 프롬프트 템플릿
├── data/                         런타임 데이터 (.gitignore)
│   ├── labels.json                 사용자 라벨 정의
│   ├── memory/                     학습 데이터
│   ├── queue/                      피드백 큐 (1건=1파일)
│   └── .locks/                     파일 락
├── logs/                         로그 (.gitignore)
└── .credentials/                 OAuth 인증 (.gitignore)
```

## Cron Setup

```bash
# crontab -e
*/5 * * * * cd /path/to/project && bash bin/email-watcher.sh >> logs/cron.log 2>&1
0 3 * * *   cd /path/to/project && bash bin/memory-consolidator.sh >> logs/cron.log 2>&1
```
