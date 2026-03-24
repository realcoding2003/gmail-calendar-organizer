#!/bin/bash
# 3시간마다: 로그 읽고 Claude Code CLI로 요약 → 텔레그램
# OpenClaw 불필요, 비용 0

set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="$SCRIPTS/logs/email-$(date +%Y%m%d).jsonl"

# 로그 없거나 비어있으면 종료
[ ! -f "$LOG_FILE" ] && exit 0
[ ! -s "$LOG_FILE" ] && exit 0

LOG_CONTENT=$(cat "$LOG_FILE")

# Claude Code CLI로 요약 생성
SUMMARY=$(claude --print --allowed-tools "" -- "아래 이메일 처리 로그(JSONL)를 읽고 텔레그램 메시지 형식으로 요약해줘.
마크다운 테이블 쓰지 마. 간결하게.

형식:
📬 메일 처리 요약 (최근 3시간)

🔴 확인 필요:
• [시간] 제목 (발신자)

📋 자동 처리: n건
• 광고 n건, 금융-결제 n건 등

처리할 건이 없으면 아무것도 출력하지 마.

로그:
$LOG_CONTENT" 2>/dev/null)

# 내용 있을 때만 전송
if [ -n "$SUMMARY" ]; then
  bash "$SCRIPTS/notify-telegram.sh" "$SUMMARY" 2>/dev/null && \
    # 전송 후 로그 초기화
    > "$LOG_FILE"
fi
