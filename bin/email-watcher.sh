#!/bin/bash
# 5분마다 cron 실행 - 미처리 스레드 20개 처리
# "_processed" 라벨 없는 스레드만 대상 (멱등, 날짜 제한 없음)
# 스레드 단위 처리: 주고받은 메일을 한 번에 그룹핑
#
# Phase 1: 메모리 패턴 매칭 (발신자+제목) → fast/need_body
# Phase 2: need_body만 본문 포함 개별 LLM 호출
# 1배치(20 스레드) 처리 후 종료, 나머지는 다음 cron에서

set -euo pipefail

# Ctrl+C 시 자식 프로세스 포함 종료
trap 'kill 0; exit 1' INT TERM

SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPTS/lib/common.sh"
source "$SCRIPTS/lib/classifier.sh"
source "$SCRIPTS/lib/gmail-actions.sh"

BATCH_SIZE=10
MAX_ROUNDS=1
DATE_FILTER="newer_than:30d"
ACCOUNT_FILTER=""

# 옵션 파싱
for arg in "$@"; do
  case "$arg" in
    --all)        DATE_FILTER="" ;;
    --repeat)     MAX_ROUNDS=999 ;;
    --rounds=*)   MAX_ROUNDS="${arg#--rounds=}" ;;
    --account=*)  ACCOUNT_FILTER="${arg#--account=}" ;;
  esac
done

if [ -z "$DATE_FILTER" ]; then
  echo "모드: 전체 미처리 | 반복: ${MAX_ROUNDS}회"
else
  echo "모드: 최근 30일 | 반복: ${MAX_ROUNDS}회"
fi

# 경과 시간 (초)
elapsed() {
  local start="$1"
  local now=$(date +%s)
  echo "$((now - start))초"
}

# 스레드 상세 조회 (전체 메시지 포함)
fetch_thread_detail() {
  local tid="$1"
  local acct="$2"

  python3 -c "
import json, sys, os
sys.path.insert(0, '$LIB_DIR')
from google_api import get_auth, GmailClient

auth = get_auth('$acct', '$PROJECT_ROOT')
client = GmailClient(auth)
thread = client.service.users().threads().get(userId='me', id='$tid', format='full').execute()
messages = []
for msg in thread.get('messages', []):
    headers = {h['name']: h['value'] for h in msg.get('payload', {}).get('headers', [])}
    labels = msg.get('labelIds', [])
    is_sent = 'SENT' in labels
    body = client._extract_body(msg.get('payload', {}))
    if len(body) > 800: body = body[:800] + '...'
    messages.append({
        'id': msg['id'], 'threadId': '$tid',
        'subject': headers.get('Subject', ''), 'from': headers.get('From', ''),
        'to': headers.get('To', ''), 'date': headers.get('Date', ''),
        'snippet': msg.get('snippet', ''), 'body': body,
        'labelIds': labels, 'is_sent': is_sent
    })
print(json.dumps({'thread_id': '$tid', 'messages': messages}, ensure_ascii=False))
" 2>/dev/null
}

# === 메인 ===

TOTAL_START=$(date +%s)

ACCOUNTS=()
while IFS= read -r line; do ACCOUNTS+=("$line"); done < <(load_accounts)

ROUND=1
while [ "$ROUND" -le "$MAX_ROUNDS" ]; do

[ "$MAX_ROUNDS" -gt 1 ] && echo "" && echo "===== 라운드 ${ROUND}/${MAX_ROUNDS} ====="

ROUND_EMPTY=true

for acct in "${ACCOUNTS[@]}"; do
  # --account 필터
  if [ -n "$ACCOUNT_FILTER" ] && [ "$acct" != "$ACCOUNT_FILTER" ]; then continue; fi
  ensure_processed_label "$acct"

  # 스레드 20개 가져오기
  T0=$(date +%s)
  THREAD_LIST=$(search_threads "in:inbox -label:${PROCESSED_LABEL} -in:trash -in:spam -in:drafts ${DATE_FILTER}" "$acct" "$BATCH_SIZE")
  THREAD_COUNT=$(count_threads "$THREAD_LIST")
  [ "$THREAD_COUNT" -eq 0 ] && { echo "[$acct] 미처리 스레드 없음"; continue; }

  ROUND_EMPTY=false
  echo "[$acct] 미처리 스레드: ${THREAD_COUNT}건 (검색: $(elapsed $T0))"

  # 스레드 → messages 형태로 변환 (Phase 1용)
  MAIL_LIST=$(echo "$THREAD_LIST" | python3 -c "
import json, sys
threads = json.load(sys.stdin).get('threads', [])
messages = []
for t in threads:
    messages.append({
        'id': t['id'],
        'subject': t.get('subject', ''),
        'from': t.get('from', ''),
        'date': t.get('date', ''),
        'snippet': t.get('snippet', '')
    })
print(json.dumps({'messages': messages}, ensure_ascii=False))
" 2>/dev/null)

  # ============================================
  # Phase 1: 메모리 패턴 매칭 (발신자+제목, LLM 미사용)
  # ============================================
  T1=$(date +%s)
  echo "  Phase 1: 메모리 패턴 매칭..."
  PRE_RESULT=$(pre_classify "$MAIL_LIST" "$acct") || true
  echo "  Phase 1 매칭: $(elapsed $T1)"

  NEED_BODY_IDS=""
  FAST_IDS=""
  TOTAL_FAST=0

  T1_APPLY=$(date +%s)
  while IFS= read -r line; do
    if [[ "$line" == FAST:* ]]; then
      echo "  $line"
    elif [[ "$line" == NEED_BODY:* ]]; then
      NEED_BODY_IDS+="${line#NEED_BODY:} "
    elif [[ "$line" == FAST_DONE:* ]]; then
      TOTAL_FAST="${line#FAST_DONE:}"
      echo "  → 즉시 분류: ${TOTAL_FAST}건 (라벨 적용: $(elapsed $T1_APPLY))"
    fi
  done < <(process_pre_classify_result "$PRE_RESULT" "$acct")

  # 매칭 결과가 비어있으면 전체를 Phase 2로 투입
  if [ "$TOTAL_FAST" -eq 0 ] && [ -z "$(echo "$NEED_BODY_IDS" | tr -d ' ')" ]; then
    echo "  매칭 없음 → 전체 ${THREAD_COUNT}건 Phase 2로 처리"
    NEED_BODY_IDS=$(echo "$MAIL_LIST" | python3 -c "
import json, sys
for m in json.load(sys.stdin).get('messages', []):
    print(m['id'])
" 2>/dev/null | tr '\n' ' ')
  fi

  # fast 처리된 스레드 _processed 표시 (need_body에 없는 것 = fast로 처리된 것)
  echo "$MAIL_LIST" | python3 -c "
import json, sys
need = set('$NEED_BODY_IDS'.split())
for m in json.load(sys.stdin).get('messages', []):
    if m['id'] not in need:
        print(m['id'])
" 2>/dev/null | while IFS= read -r tid; do
    mark_processed "$tid" "$acct"
  done

  # ============================================
  # Phase 2: 상세 분류 (스레드 본문 포함, 개별)
  # ============================================
  TOTAL_AI=0

  if [ -n "$NEED_BODY_IDS" ]; then
    NEED_COUNT=$(echo "$NEED_BODY_IDS" | wc -w | tr -d ' ')
    echo "  Phase 2: 상세 분류 ${NEED_COUNT}건 (본문 포함)"

    for tid in $NEED_BODY_IDS; do
      T2=$(date +%s)
      SUBJ=$(echo "$MAIL_LIST" | python3 -c "
import json,sys
for m in json.load(sys.stdin).get('messages',[]):
    if m['id']=='$tid': print(m.get('subject','')[:60]); break
" 2>/dev/null)

      THREAD_DETAIL=$(fetch_thread_detail "$tid" "$acct")
      [ -z "$THREAD_DETAIL" ] && { mark_processed "$tid" "$acct"; continue; }

      RESULT=$(classify_emails "$THREAD_DETAIL" "$acct") || true
      process_classification_result "$RESULT" "$acct" || true

      mark_processed "$tid" "$acct"
      TOTAL_AI=$((TOTAL_AI + 1))
      echo "    → $SUBJ ($(elapsed $T2))"
    done
  fi

  echo "[$acct] 완료 — 패스트:${TOTAL_FAST} AI:${TOTAL_AI} (총: $(elapsed $TOTAL_START))"
done

# 처리할 게 없었으면 조기 종료
if $ROUND_EMPTY; then
  [ "$MAX_ROUNDS" -gt 1 ] && echo "미처리 메일 없음. 종료."
  break
fi

ROUND=$((ROUND + 1))
[ "$ROUND" -le "$MAX_ROUNDS" ] && sleep 2

done  # while ROUND

exit 0
