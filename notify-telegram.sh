#!/bin/bash
# 텔레그램 직접 알림 (OpenClaw Sonnet 세션 없이 직접 호출)
# 사용법: ./notify-telegram.sh "메시지 내용"

CHAT_ID="8298285116"
TOKEN=$(python3 -c "
import json
with open('$HOME/.openclaw/openclaw.json') as f:
    cfg = json.load(f)
print(cfg.get('channels',{}).get('telegram',{}).get('botToken',''))
" 2>/dev/null)

if [ -z "$TOKEN" ]; then
  echo "텔레그램 토큰 없음" >&2
  exit 1
fi

MESSAGE="${1:-}"
curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  -d chat_id="$CHAT_ID" \
  --data-urlencode text="$MESSAGE" \
  -d parse_mode="Markdown" > /dev/null && echo "전송완료" || echo "전송실패"
