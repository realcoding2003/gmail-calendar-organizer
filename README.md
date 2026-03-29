# Gmail + Calendar 자동화 시스템

> Ollama 로컬 LLM 기반 AI 이메일 자동 분류 + 캘린더 일정 등록

Mac Mini 같은 미니 PC에서 crontab으로 구동하는 개인용 이메일 자동화 시스템입니다.
Google API 직접 호출 + Ollama 로컬 LLM으로 동작하며, 외부 API 의존 없이 로컬에서 완결됩니다.

## 주요 기능

- **2단계 분류 파이프라인** — Phase 1 패턴 매칭(즉시) + Phase 2 LLM 분류(정밀)
- **자동 학습** — 사용할수록 Phase 1 fast 비율 증가, LLM 호출 감소
- **캘린더 자동 등록** — 이메일에서 일정 감지 시 Google Calendar에 자동 제안
- **파일 기반 큐** — 외부 시스템(알림 봇 등)과 JSON 파일만으로 연동, DB/API 불필요
- **커뮤니티 패턴** — 100+ 프리빌트 발신자 패턴으로 즉시 시작
- **완전 로컬** — 모든 AI 처리가 로컬 LLM으로 동작, 데이터가 외부로 나가지 않음

## 요구사항

- macOS (Apple Silicon 권장, Mac Mini M4 16GB 기준 개발)
- [Ollama](https://ollama.com) — 로컬 LLM 서버
- Python 3.10+
- Google Cloud OAuth 2.0 credentials

## 설치

```bash
# 1. 저장소 클론
git clone https://github.com/OKAI-crew/gmail-calendar-organizer.git
cd gmail-calendar-organizer

# 2. Ollama 모델 설치
ollama pull phi4

# 3. Python 의존성
pip3 install google-auth google-auth-oauthlib google-api-python-client

# 4. Google OAuth 설정
cp credentials.json .credentials/
cp config/accounts.example.json config/accounts.json  # 계정 설정 편집
python3 lib/google_api.py auth --account YOUR_EMAIL

# 5. Cron 등록
crontab crontab.txt
```

> **Google Cloud 설정**: [Google Cloud Console](https://console.cloud.google.com/)에서 Gmail API와 Calendar API를 활성화하고, OAuth 2.0 클라이언트 ID를 생성하여 `credentials.json`을 다운로드하세요.

## 사용법

```bash
# 메일 분류 (1회, 최근 30일)
bash bin/email-watcher.sh

# 전체 미처리 메일
bash bin/email-watcher.sh --all

# N라운드 반복
bash bin/email-watcher.sh --rounds=5

# 미처리 없을 때까지 반복
bash bin/email-watcher.sh --all --repeat

# 피드백 처리
bash bin/feedback-processor.sh <큐파일> label <라벨명>
bash bin/feedback-processor.sh <큐파일> delete
bash bin/feedback-processor.sh <큐파일> archive
bash bin/feedback-processor.sh <큐파일> skip
bash bin/feedback-processor.sh <큐파일> calendar

# 메모리 통합 (수동 실행)
bash bin/memory-consolidator.sh
```

## 아키텍처

```text
┌─────────────────────────────────────────────────────────────┐
│  Mac Mini (이 프로젝트)                                      │
│                                                             │
│  ┌─────────────┐    ┌──────────────┐    ┌───────────────┐  │
│  │ email-      │    │ Google API   │    │ Ollama LLM    │  │
│  │ watcher.sh  │───▶│ gmail / cal  │    │ (phi4)    │  │
│  │ cron 5분    │    │ lib/         │    │ Phase2: 개별  │  │
│  │             │───▶│ google_api.py│    │               │  │
│  └──────┬──────┘    └──────────────┘    └───────────────┘  │
│         │                                                   │
│         ▼                                                   │
│  ┌──────────────┐    ┌──────────────┐                      │
│  │ data/queue/  │    │ data/memory/ │ 자동 학습             │
│  │ 1건=1 JSON   │    │ patterns     │                      │
│  └──────┬───────┘    │ rules        │                      │
│         │            │ corrections  │                      │
│         ▼            └──────────────┘                      │
│  ┌──────────────┐           ▲                               │
│  │ feedback-    │───────────┘                               │
│  │ processor.sh │ 사용자 결정 실행 + 메모리 학습            │
│  └──────────────┘                                           │
└─────────────────────────────────────────────────────────────┘
```

### 처리 흐름

```text
미처리 스레드 조회 (Gmail API batch)
    ↓
Phase 1: 메모리 패턴 매칭 (LLM 미사용, 즉시 처리)
  ├─ fast → 라벨 + 보관
  └─ need_body → Phase 2로
    ↓
Phase 2: 본문 포함 LLM 분류 (Ollama)
  ├─ 자동 분류 → 라벨 + 보관
  ├─ 미결정 → 큐 파일 생성 (사용자 확인)
  └─ 일정 감지 → 캘린더 큐 생성
    ↓
학습: fast_patterns → 다음부터 Phase 1에서 처리
```

자세한 아키텍처 문서는 [docs/architecture.md](docs/architecture.md)를 참고하세요.

## 설정

### LLM 모델

환경변수로 Ollama 모델을 변경할 수 있습니다.

| 환경변수 | 기본값 | 설명 |
| --- | --- | --- |
| `LLM_MODEL` | `phi4` | Ollama 모델명 |
| `LLM_BASE_URL` | `http://localhost:11434` | Ollama 서버 URL |

```bash
# 다른 모델로 실행
LLM_MODEL=phi4-mini bash bin/email-watcher.sh
```

#### 테스트된 모델 후보군

Mac Mini M4 16GB 기준으로 테스트한 결과입니다.

| 모델 | 파라미터 | 크기 | 16GB 체감 속도 | 비고 |
| --- | --- | --- | --- | --- |
| **`phi4`** | 14B | 9.1GB | 보통 | **현재 기본값.** 추론 성능 우수, 분류 품질 좋음 |
| `phi4-mini` | 3.8B | 2.5GB | 빠름 | 가볍고 빠르지만 한국어 분류 품질 열세 |
| `qwen3:8b` | 8B | 5.2GB | 쾌적 | 한국어 우수, 속도와 품질의 균형 |
| `qwen3:14b` | 14B | 9.3GB | 느림 | 한국어 최상, 16GB에서 메모리 부족 발생 가능 |
| `gpt-oss:20b` | 20B | 13GB | 매우 느림 | 16GB에서 CPU 오프로딩으로 실사용 어려움 |

### 계정 설정

`config/accounts.json`에서 Gmail 계정을 관리합니다. 예시는 `config/accounts.example.json`을 참고하세요.

### 라벨 설정

`data/labels.json`에서 분류 라벨과 설명을 정의합니다. 시스템이 라벨 설명을 참고하여 분류 정확도를 높입니다.

## 큐 파일 인터페이스

외부 시스템(알림 봇 등)은 큐 파일만으로 연동합니다. API나 DB 불필요.

```text
data/queue/
├── classifications/   분류 미결정 (pending-*.json)
├── calendars/         캘린더 미결정 (cal-*.json)
└── labels/            라벨 제안 (label-*.json)
```

연동 흐름:

1. `data/queue/` 디렉토리 감시 (fswatch 또는 polling)
2. `decision: null`인 파일 발견 → 사용자에게 질문
3. 사용자 답변 수신 → `feedback-processor.sh` 호출
4. 처리 완료 (Gmail 액션 + 메모리 학습 + 큐 파일 삭제)

큐 파일 구조 등 상세 내용은 [docs/architecture.md](docs/architecture.md)를 참고하세요.

## 프로젝트 구조

```text
├── bin/                          실행 스크립트
│   ├── email-watcher.sh            메일 분류 (cron 5분)
│   ├── feedback-processor.sh       피드백 처리 (외부 호출)
│   └── memory-consolidator.sh      메모리 최적화 (cron 매일)
├── lib/                          공통 라이브러리
│   ├── common.sh                   경로, 유틸, llm_call(), 락
│   ├── classifier.sh               Phase 1 패턴 매칭 + Phase 2 LLM 분류
│   ├── gmail-actions.sh            Gmail API 래핑
│   ├── calendar-actions.sh         캘린더 API 래핑
│   ├── google_api.py               Google API OAuth 클라이언트
│   └── llm_call.py                 Ollama REST API 래퍼
├── config/                       설정
│   ├── accounts.example.json       계정 설정 예시
│   ├── community/                  커뮤니티 프리빌트 패턴
│   └── prompts/                    LLM 프롬프트 템플릿
├── data/                         런타임 데이터 (.gitignore)
├── docs/                         문서
│   └── architecture.md             상세 아키텍처
├── logs/                         로그 (.gitignore)
└── .credentials/                 OAuth 인증 (.gitignore)
```

## 기여하기

기여를 환영합니다! 다음 가이드를 따라주세요.

### 이슈

- 버그 리포트나 기능 제안은 [Issues](https://github.com/OKAI-crew/gmail-calendar-organizer/issues)에 등록해주세요.
- 이슈 작성 시 재현 절차, 기대 동작, 실제 동작을 명확히 기술해주세요.

### Pull Request

1. 저장소를 Fork 합니다.
2. 기능 브랜치를 생성합니다. (`git checkout -b feat/my-feature`)
3. 변경사항을 커밋합니다. (Conventional Commits 형식 권장)
4. 브랜치를 Push 합니다. (`git push origin feat/my-feature`)
5. Pull Request를 생성합니다.

### 커밋 컨벤션

[Conventional Commits](https://www.conventionalcommits.org/) 형식을 사용합니다.

```text
feat(scope): 새 기능 추가
fix(scope): 버그 수정
refactor(scope): 리팩토링
docs(scope): 문서 수정
```

### 코딩 규칙

- 스크립트: bash + python3
- 모든 bin/ 스크립트는 `source "$LIB_DIR/common.sh"` 필수
- 에러 처리: `set -euo pipefail`
- 설정값은 `config/`에서 로드 (하드코딩 금지)
- LLM 호출은 `llm_call()` 함수 경유
- 사용자 메시지는 한국어

## 라이선스

이 프로젝트는 [MIT License](LICENSE)에 따라 배포됩니다.
