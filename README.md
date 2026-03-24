# gmail-organizer

Gmail 자동 분류 스크립트. Claude Code CLI(Max20 구독)로 처리 — API 비용 0.

## 스크립트

| 파일 | 역할 | 실행 주기 |
|------|------|-----------|
| `email-watcher.sh` | 새 메일 감지 → Claude 분류 → 로그 저장 | 5분마다 |
| `email-organizer.sh` | 전체 받은편지함 정리 (규칙 + Claude) | 6시간마다 |
| `email-log-summary.sh` | 로그 요약 → 텔레그램 | 3시간마다 |
| `notify-telegram.sh` | 텔레그램 Bot API 직접 전송 | 내부 유틸 |

## 요구사항

- [gog CLI](https://gogcli.sh) + Gmail OAuth 인증
- [Claude Code CLI](https://claude.ai/code) + Max20 구독
- Telegram Bot Token

## 설치

```bash
# 1. 환경변수 설정
cp .env.example .env
vi .env

# 2. Gmail 라벨 생성
for label in "광고" "금융-결제" "보안" "정부-R&D" "보험" "개발-테크" "도메인-호스팅" "확인필요" "소셜"; do
  gog gmail labels create "$label" --account YOUR_EMAIL --force
done

# 3. crontab 등록
crontab -e
```

## Crontab

```cron
PATH=/opt/homebrew/bin:/Users/YOUR_USER/.local/bin:/usr/bin:/bin
HOME=/Users/YOUR_USER

# 새 메일 감지 + 분류 (5분마다)
*/5 * * * * bash /path/to/email-watcher.sh >> /path/to/logs/cron.log 2>&1

# 로그 요약 → 텔레그램 (3시간마다)
0 */3 * * * bash /path/to/email-log-summary.sh >> /path/to/logs/cron.log 2>&1

# 전체 정리 (6시간마다)
0 */6 * * * bash /path/to/email-organizer.sh >> /path/to/logs/cron.log 2>&1
```

## 자동 생성 라벨

```
광고         뉴스레터/마케팅
금융-결제    결제/청구/세금계산서
보안         보안 알림
정부-R&D     정부/지원사업
보험         보험 관련
개발-테크    개발 정보성
도메인-호스팅 도메인/호스팅
확인필요     액션/기한 필요
소셜         SNS 알림
```

## 흐름

```
cron 5분
  └── email-watcher.sh
        ├── 새 메일 없음 → 즉시 종료 (비용 0)
        ├── 새 메일 있음 → Claude Code CLI 분류
        │     ├── 라벨링/보관 실행
        │     ├── 중요 건 → logs/email-YYYYMMDD.jsonl
        │     └── 긴급 건 → 텔레그램 즉시 🚨
        └── 답장한 스레드에서 일정 감지 → 캘린더 등록

cron 3시간
  └── email-log-summary.sh
        ├── 로그 없음 → 종료
        └── 로그 있음 → Claude 요약 → 텔레그램 → 로그 초기화
```
