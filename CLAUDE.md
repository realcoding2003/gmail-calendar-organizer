# Gmail + Calendar 자동화

Mac Mini에서 crontab으로 구동하는 이메일 자동 분류 + 캘린더 일정 등록 시스템.
Google API 직접 호출 + Claude Code CLI 기반.

## 핵심 구조

- `bin/email-watcher.sh` — cron 5분, 메일 분류 (Phase 1 일괄 → Phase 2 개별)
- `bin/feedback-processor.sh` — 외부 호출, 사용자 결정 실행 + 메모리 학습
- `bin/memory-consolidator.sh` — cron 주 1회, Claude Opus로 메모리 최적화

## 핵심 명령어

```bash
# 메일 분류
bash bin/email-watcher.sh                    # 1회, 최근 30일
bash bin/email-watcher.sh --all              # 전체 미처리
bash bin/email-watcher.sh --all --rounds=5   # 전체, 5라운드

# 피드백 처리 (외부 시스템이 호출)
bash bin/feedback-processor.sh <큐파일> label <라벨명>   # 라벨 적용 + 보관
bash bin/feedback-processor.sh <큐파일> delete            # 삭제
bash bin/feedback-processor.sh <큐파일> archive           # 보관만
bash bin/feedback-processor.sh <큐파일> skip              # 큐에서만 제거
bash bin/feedback-processor.sh <큐파일> calendar          # 캘린더 등록
bash bin/feedback-processor.sh --all                      # action 설정된 전체 처리

# Google API
python3 lib/google_api.py gmail messages-search --query "in:inbox" --max 20 --account EMAIL
python3 lib/google_api.py gmail labels-modify THREAD_ID --add LABEL --remove INBOX --account EMAIL
python3 lib/google_api.py calendar create CAL_ID --summary TITLE --from START --to END --account EMAIL
python3 lib/google_api.py auth --account EMAIL

# Claude CLI (Sonnet, 도구 사용 금지)
claude --print --model sonnet --allowed-tools "" -- "프롬프트"
```

## 큐 시스템 (1건 = 1 JSON 파일)

```
data/queue/
├── classifications/   분류 미결정 (pending-*.json)
├── calendars/         캘린더 미결정 (cal-*.json)
└── labels/            라벨 제안 (label-*.json)
```

### 외부 연동 방법

외부 시스템(알림 봇 등)은 큐 파일만으로 연동. API/DB 불필요.

```
1. data/queue/ 디렉토리 감시
2. decision: null인 파일 발견 → 사용자에게 질문
3. 사용자 답변 수신
4. feedback-processor.sh 호출:
   bash bin/feedback-processor.sh <파일경로> <label|delete|archive|skip|calendar> [인수]
5. 처리 완료 (라벨/삭제/캘린더 + 메모리 학습 + 파일 삭제)
```

### 큐 파일 구조 (분류)

```json
{
  "id": "pending-abc123",
  "email_id": "19d1eb485a942cb3",
  "account": "your-email@gmail.com",
  "subject": "메일 제목",
  "from": "발신자 <email@example.com>",
  "summary": "AI가 생성한 메일 요약",
  "ai_suggestion": {
    "label": "광고",
    "confidence": 0.4,
    "reason": "분류 사유"
  },
  "decision": null
}
```

### 큐 파일 구조 (캘린더)

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

## 메모리 시스템

- `data/memory/sender-patterns.json` — 발신자 도메인 → 라벨 매핑 (자동 학습)
- `data/memory/classification-rules.json` — 키워드 기반 규칙
- `data/memory/user-corrections.jsonl` — 사용자 수정 이력 (append-only)

메모리는 분류 프롬프트에 컨텍스트로 주입. 학습이 쌓일수록 Phase 1 fast 비율이 올라감.

### 학습 흐름

```
사용자 결정 → feedback-processor.sh
  → sender-patterns.json에 발신자 패턴 추가/업데이트
  → classification-rules.json에 오분류 수정 규칙 추가
  → user-corrections.jsonl에 이력 기록
  → 다음 watcher 실행 시 프롬프트에 반영
```

## Claude CLI 모델 사용

| 용도 | 모델 | 호출 빈도 |
| --- | --- | --- |
| Phase 1 사전 분류 | Sonnet | 5분마다 |
| Phase 2 상세 분류 | Sonnet | 미결정 건만 |
| 메모리 통합 | Opus | 주 1회 |

## 코딩 규칙

- bash + python3 (Google API는 lib/google_api.py로 호출)
- 모든 bin/ 스크립트는 `source "$LIB_DIR/common.sh"` 필수
- 에러 처리: `set -euo pipefail`
- 설정값은 config/에서 로드 (하드코딩 금지)
- 프롬프트는 config/prompts/ 템플릿 사용
- 메일 삭제는 반드시 email_id/thread_id로만 (검색 쿼리 삭제 금지)
- 한국어 사용자 메시지

## 디렉토리 구조

```
├── bin/                          실행 스크립트
│   ├── email-watcher.sh            메일 분류 (cron 5분)
│   ├── feedback-processor.sh       피드백 처리 (외부 호출)
│   └── memory-consolidator.sh      메모리 최적화 (cron 주 1회)
├── lib/                          공통 라이브러리
│   ├── common.sh                   경로, 유틸
│   ├── classifier.sh               Claude 프롬프트 + 결과 처리
│   ├── gmail-actions.sh            Gmail 래핑
│   ├── calendar-actions.sh         캘린더 래핑
│   └── google_api.py               Google API OAuth
├── config/                       설정
│   ├── accounts.json               계정 (enabled 플래그)
│   ├── accounts.example.json        계정 설정 예시
│   └── prompts/                    Claude 프롬프트 템플릿
├── data/                         런타임 (.gitignore)
│   ├── labels.json                 사용자 라벨 정의 (대화로 추가)
│   ├── memory/                     학습 데이터
│   └── queue/                      피드백 큐 (1건=1파일)
│       ├── classifications/
│       ├── calendars/
│       └── labels/
├── logs/                         로그 (.gitignore)
└── .credentials/                 OAuth 인증 (.gitignore)
```
