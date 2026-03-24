#!/bin/bash
# 5분마다 실행 - 새 메일 감지 → Claude 분류 → 로그 저장
# 긴급 건만 텔레그램 즉시 알림

set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
STATE_FILE="$SCRIPTS/email-watcher-state.json"
LOG_DIR="$SCRIPTS/logs"
LOG_FILE="$LOG_DIR/email-$(date +%Y%m%d).jsonl"
ACCOUNTS=("kevinpark@webace.co.kr" "contact@okyc.kr")

mkdir -p "$LOG_DIR"

# 마지막 체크 시간
if [ -f "$STATE_FILE" ]; then
  LAST_CHECK=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('last_check',''))" 2>/dev/null || echo "")
else
  LAST_CHECK=$(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u --date='5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
fi

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NOW_KST=$(date '+%Y-%m-%d %H:%M')

for acct in "${ACCOUNTS[@]}"; do
  # newer_than으로 최근 6분 메일만 (5분 cron + 1분 여유)
  QUERY="in:inbox newer_than:6m"

  NEW_MAILS=$(gog gmail messages search "$QUERY" --max 20 --account "$acct" --json 2>/dev/null || echo '{"messages":[]}')
  MSG_COUNT=$(echo "$NEW_MAILS" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('messages',[])))" 2>/dev/null || echo 0)
  [ "$MSG_COUNT" -eq 0 ] && continue

  # 스레드별 답장 여부 확인 + 일정 확정 스레드 추출
  SCHEDULE_THREADS=""
  NEW_MAILS=$(echo "$NEW_MAILS" | python3 -c "
import json, sys, subprocess

data = json.load(sys.stdin)
messages = data.get('messages', [])
filtered = []
schedule_threads = []

for msg in messages:
    thread_id = msg.get('threadId', '')
    if not thread_id:
        filtered.append(msg)
        continue
    r = subprocess.run(
        ['gog','gmail','messages','search', f'thread:{thread_id}',
         '--max','10','--account','$acct','--json'],
        capture_output=True, text=True)
    if r.returncode != 0:
        filtered.append(msg)
        continue
    thread_msgs = json.loads(r.stdout).get('messages', [])
    has_sent = any('SENT' in m.get('labelIds', []) for m in thread_msgs)
    if has_sent:
        # 답장한 스레드 → 일정 관련 키워드 있으면 캘린더 후보
        keywords = ['일정','약속','미팅','meeting','날짜','시간','오전','오후','시에','요일']
        full_text = ' '.join([m.get('snippet','') + m.get('subject','') for m in thread_msgs])
        if any(k in full_text for k in keywords):
            schedule_threads.append(json.dumps({
                'thread_id': thread_id,
                'messages': thread_msgs
            }, ensure_ascii=False))
    else:
        filtered.append(msg)

# 일정 후보 출력 (stderr로)
for t in schedule_threads:
    print(f'SCHEDULE:{t}', file=sys.stderr)

data['messages'] = filtered
print(json.dumps(data, ensure_ascii=False))
" 2>/tmp/email-watcher-schedule.tmp || echo "$NEW_MAILS")

  # 일정 확정 스레드 → Claude로 캘린더 등록
  if [ -s /tmp/email-watcher-schedule.tmp ]; then
    while IFS= read -r line; do
      [[ "$line" != SCHEDULE:* ]] && continue
      THREAD_DATA="${line#SCHEDULE:}"

      CAL_RESULT=$(claude --print --allowed-tools "" -- "아래 이메일 스레드에서 확정된 약속/일정을 추출해줘. JSON만.

{
  \"has_schedule\": true/false,
  \"summary\": \"일정 제목\",
  \"start\": \"2026-03-25T14:00:00+09:00\",
  \"end\": \"2026-03-25T15:00:00+09:00\",
  \"location\": \"장소 (없으면 빈 문자열)\"
}

- 명확한 날짜/시간이 없으면 has_schedule: false
- 종료시간 불명확하면 시작+1시간

스레드:
$THREAD_DATA" 2>/dev/null || echo '{"has_schedule":false}')

      python3 -c "
import json, subprocess, sys
raw = '$CAL_RESULT'
# 파일에서 읽기
import os
" 2>/dev/null

      # JSON 파싱 후 캘린더 등록
      echo "$CAL_RESULT" | python3 -c "
import json, sys, subprocess
raw = sys.stdin.read()
start = raw.find('{'); end = raw.rfind('}') + 1
if start == -1: sys.exit(0)
data = json.loads(raw[start:end])
if not data.get('has_schedule'): sys.exit(0)

summary = data.get('summary','일정')
start_t = data.get('start','')
end_t = data.get('end','')
location = data.get('location','')
if not start_t: sys.exit(0)

# 오키씨 공식 캘린더에 등록
cmd = ['gog','calendar','create',
       'c_ed143b7a18da74192bf446fa7ccefff11a232e9f68de3c60ac604e85924c591b@group.calendar.google.com',
       '--summary', summary,
       '--from', start_t,
       '--to', end_t,
       '--account', 'kevinpark@webace.co.kr',
       '--force']
if location:
    cmd.extend(['--location', location])

r = subprocess.run(cmd, capture_output=True, text=True)
if r.returncode == 0:
    print(f'CALENDAR_ADDED:{summary} ({start_t[:16]})')
" 2>/dev/null | while IFS= read -r cal_line; do
        if [[ "$cal_line" == CALENDAR_ADDED:* ]]; then
          INFO="${cal_line#CALENDAR_ADDED:}"
          bash "$SCRIPTS/notify-telegram.sh" "📅 캘린더 자동 등록: $INFO" 2>/dev/null || true
          # 로그에도 기록
          echo "{\"title\":\"캘린더 등록: $INFO\",\"from\":\"이메일 스레드\",\"label\":\"캘린더\",\"action\":\"자동 등록\",\"urgency\":\"normal\",\"time\":\"$NOW_KST\",\"account\":\"$acct\"}" >> "$LOG_FILE"
        fi
      done
    done < /tmp/email-watcher-schedule.tmp
    rm -f /tmp/email-watcher-schedule.tmp
  fi

  MSG_COUNT=$(echo "$NEW_MAILS" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('messages',[])))" 2>/dev/null || echo 0)
  [ "$MSG_COUNT" -eq 0 ] && continue

  # Claude로 분류 + 중요도 판단
  RESULT=$(claude --print --allowed-tools "" -- "새 메일 분류. JSON만 출력.

{
  \"actions\": [{\"id\":\"id\",\"account\":\"이메일\",\"label\":\"라벨\",\"archive\":true}],
  \"log\": [{\"title\":\"제목\",\"from\":\"발신자\",\"label\":\"라벨\",\"action\":\"처리내용\",\"urgency\":\"high/normal/none\"}],
  \"urgent\": [\"긴급 알림 텍스트\"]
}

라벨 규칙:
- SNS알림 → 소셜 archive:true urgency:none
- 광고/뉴스레터 → 광고 archive:true urgency:none
- 결제/청구/세금 → 금융-결제 archive:true urgency:none
- 보안알림(긴급) → 보안 archive:false urgency:high
- 보안알림(일반) → 보안 archive:true urgency:none
- 정부/R&D(기한임박) → 정부-R&D archive:false urgency:high
- 정부/R&D(일반) → 정부-R&D archive:false urgency:normal
- 보험 → 보험 archive:false urgency:normal
- 개발/테크 정보성 → 개발-테크 archive:true urgency:none
- 도메인/호스팅(만료경고) → 도메인-호스팅 archive:false urgency:high
- 확인필요(계약,서명,기한) → 확인필요 archive:false urgency:high
- 업무/개인 중요 → 분류안함 archive:false urgency:normal
- 일반광고 → 광고 archive:true urgency:none

계정: $acct
$NEW_MAILS" 2>/dev/null || echo '{"actions":[],"log":[],"urgent":[]}')

  # 라벨링/보관 실행
  echo "$RESULT" | python3 -c "
import json, sys, subprocess
raw = sys.stdin.read()
start = raw.find('{'); end = raw.rfind('}') + 1
if start == -1: sys.exit(0)
data = json.loads(raw[start:end])
for a in data.get('actions', []):
    mid, ac, label = a.get('id',''), a.get('account',''), a.get('label')
    if not mid: continue
    cmd = ['gog','gmail','labels','modify', mid,'--account', ac,'--force']
    if label: cmd.extend(['--add', label])
    if a.get('archive'): cmd.extend(['--remove','INBOX'])
    subprocess.run(cmd, capture_output=True)
" 2>/dev/null

  # 로그 파일에 저장 (none 제외, normal/high만)
  echo "$RESULT" | python3 -c "
import json, sys

raw = sys.stdin.read()
start = raw.find('{'); end = raw.rfind('}') + 1
if start == -1: sys.exit(0)
data = json.loads(raw[start:end])

log_entries = [l for l in data.get('log', []) if l.get('urgency') in ('normal','high')]
if not log_entries: sys.exit(0)

import os
log_file = '$LOG_FILE'
with open(log_file, 'a') as f:
    for entry in log_entries:
        entry['time'] = '$NOW_KST'
        entry['account'] = '$acct'
        f.write(json.dumps(entry, ensure_ascii=False) + '\n')
" 2>/dev/null

  # 긴급 건만 즉시 텔레그램
  echo "$RESULT" | python3 -c "
import json, sys
raw = sys.stdin.read()
start = raw.find('{'); end = raw.rfind('}') + 1
if start == -1: sys.exit(0)
data = json.loads(raw[start:end])
for u in data.get('urgent', []):
    print(u)
" 2>/dev/null | while IFS= read -r line; do
    [ -n "$line" ] && bash "$SCRIPTS/notify-telegram.sh" "🚨 *긴급:* $line" 2>/dev/null || true
  done

done

# 상태 저장
python3 -c "import json; json.dump({'last_check':'$NOW'}, open('$STATE_FILE','w'))" 2>/dev/null
exit 0
