#!/bin/bash
# Gmail API 래핑 함수 (python3 lib/google_api.py 기반)
# email-watcher.sh에서 source하여 사용

GOOGLE_API="python3 $LIB_DIR/google_api.py"

# === 스레드 검색 ===
search_threads() {
  local query="$1"
  local acct="$2"
  local max="${3:-50}"

  $GOOGLE_API gmail threads-search --query "$query" --max "$max" --account "$acct" 2>/dev/null || echo '{"threads":[]}'
}

# === 스레드 수 카운트 ===
count_threads() {
  local json_data="$1"
  echo "$json_data" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('threads',[])))" 2>/dev/null || echo 0
}
