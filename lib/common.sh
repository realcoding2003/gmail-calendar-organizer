#!/bin/bash
# 공통 변수, 경로, 유틸 함수
# 모든 bin/ 스크립트에서 source 하여 사용

set -euo pipefail

# === 경로 설정 ===
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$PROJECT_ROOT/bin"
LIB_DIR="$PROJECT_ROOT/lib"
CONFIG_DIR="$PROJECT_ROOT/config"
DATA_DIR="$PROJECT_ROOT/data"
LOG_DIR="$PROJECT_ROOT/logs"
PROMPTS_DIR="$CONFIG_DIR/prompts"

CREDENTIALS_DIR="$PROJECT_ROOT/.credentials"

MEMORY_DIR="$DATA_DIR/memory"
QUEUE_DIR="$DATA_DIR/queue"
STATE_FILE="$DATA_DIR/state.json"

# === 디렉토리 보장 ===
mkdir -p "$LOG_DIR" "$MEMORY_DIR" "$QUEUE_DIR"

# === 계정 로드 ===
load_accounts() {
  python3 -c "
import json
with open('$CONFIG_DIR/accounts.json') as f:
    data = json.load(f)
for a in data['accounts']:
    if a.get('enabled', True) is False: continue
    print(a['email'])
" 2>/dev/null
}

get_calendar_id() {
  local acct="$1"
  python3 -c "
import json
with open('$CONFIG_DIR/accounts.json') as f:
    data = json.load(f)
for a in data['accounts']:
    if a['email'] == '$acct':
        print(a.get('calendar_id', 'primary'))
        break
" 2>/dev/null || echo "primary"
}

get_primary_account() {
  python3 -c "
import json
with open('$CONFIG_DIR/accounts.json') as f:
    data = json.load(f)
for a in data['accounts']:
    if a.get('primary'):
        print(a['email'])
        break
" 2>/dev/null
}

# === 날짜/시간 ===
NOW_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NOW_KST=$(date '+%Y-%m-%d %H:%M')
TODAY=$(date +%Y%m%d)

# === 로그 파일 ===
EMAIL_LOG="$LOG_DIR/email-${TODAY}.jsonl"
ACTIONS_LOG="$LOG_DIR/actions-${TODAY}.jsonl"

# === 로깅 함수 ===
log_email() {
  # 사용법: log_email '{"title":"...", "from":"...", ...}'
  local entry="$1"
  echo "$entry" | python3 -c "
import json, sys
entry = json.loads(sys.stdin.read())
entry.setdefault('time', '$NOW_KST')
print(json.dumps(entry, ensure_ascii=False))
" >> "$EMAIL_LOG" 2>/dev/null
}

log_action() {
  # 사용법: log_action "label" "msg123" "금융-결제" "success"
  local type="$1" id="$2" detail="$3" result="$4"
  echo "{\"time\":\"$NOW_KST\",\"type\":\"$type\",\"id\":\"$id\",\"detail\":\"$detail\",\"result\":\"$result\"}" >> "$ACTIONS_LOG"
}

# === 처리완료 라벨 ===
PROCESSED_LABEL="_processed"
GOOGLE_API="python3 $LIB_DIR/google_api.py"

ensure_processed_label() {
  local acct="$1"
  $GOOGLE_API gmail labels-create "$PROCESSED_LABEL" --account "$acct" --hidden >/dev/null 2>&1 || true
}

mark_processed() {
  local msg_id="$1"
  local acct="$2"
  $GOOGLE_API gmail labels-modify "$msg_id" --add "$PROCESSED_LABEL" --account "$acct" >/dev/null 2>&1 || true
}

# === 파일 락 (동시 접근 방지) ===
LOCK_DIR="$DATA_DIR/.locks"
mkdir -p "$LOCK_DIR" 2>/dev/null || true

acquire_lock() {
  local name="$1"
  local timeout="${2:-30}"
  local lockfile="$LOCK_DIR/${name}.lock"
  local waited=0

  while ! mkdir "$lockfile" 2>/dev/null; do
    # 락 파일이 60초 이상 되면 stale로 간주하고 제거
    if [ -d "$lockfile" ]; then
      local age=$(( $(date +%s) - $(stat -f %m "$lockfile" 2>/dev/null || echo 0) ))
      if [ "$age" -gt 60 ]; then
        rmdir "$lockfile" 2>/dev/null || true
        continue
      fi
    fi
    sleep 1
    waited=$((waited + 1))
    if [ "$waited" -ge "$timeout" ]; then
      echo "WARN: 락 획득 실패 ($name), 타임아웃 ${timeout}초" >&2
      return 1
    fi
  done
  return 0
}

release_lock() {
  local name="$1"
  rmdir "$LOCK_DIR/${name}.lock" 2>/dev/null || true
}

# === 피드백 큐 함수 ===
add_to_queue() {
  local queue_type="$1"  # classifications, calendars, labels
  local item_json="$2"
  local queue_file="$QUEUE_DIR/pending-${queue_type}.json"

  python3 -c "
import json, sys

item = json.loads('''$item_json''')

try:
    with open('$queue_file') as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {'pending': []}

data['pending'].append(item)

with open('$queue_file', 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
" 2>/dev/null
}

# === 메모리 로드 ===
load_memory_context() {
  # 학습된 규칙 + 최근 수정 사항을 텍스트로 반환
  python3 -c "
import json, sys

# 학습된 분류 규칙 (자주 적용된 순 상위 30개)
rules_text = ''
try:
    with open('$MEMORY_DIR/classification-rules.json') as f:
        data = json.load(f)
    rules = sorted(data.get('rules', []), key=lambda r: r.get('applied_count', 0), reverse=True)[:30]
    for r in rules:
        p = r.get('pattern', {})
        a = r.get('action', {})
        parts = []
        if p.get('from_contains'): parts.append(f\"from:{p['from_contains']}\")
        if p.get('subject_contains'): parts.append(f\"subject:{p['subject_contains']}\")
        if parts:
            rules_text += f\"- {' '.join(parts)} → {a.get('label','')} archive:{a.get('archive',False)}\n\"
except:
    pass

# 최근 사용자 수정 (최근 20건)
corrections_text = ''
try:
    import collections
    lines = open('$MEMORY_DIR/user-corrections.jsonl').readlines()[-20:]
    for line in lines:
        c = json.loads(line.strip())
        if c.get('type') == 'classification':
            corrections_text += f\"- 주의: {c.get('reason','')} ({c.get('original_label','')} → {c.get('corrected_label','')})\n\"
except:
    pass

# 발신자 패턴
sender_text = ''
try:
    with open('$MEMORY_DIR/sender-patterns.json') as f:
        patterns = json.load(f).get('patterns', {})
    for sender, info in sorted(patterns.items(), key=lambda x: x[1].get('count',0), reverse=True)[:20]:
        sender_text += f\"- {sender} → {info['label']} archive:{info.get('archive',False)}\n\"
except:
    pass

output = ''
if rules_text:
    output += f'=== 학습된 분류 규칙 ===\n{rules_text}\n'
if sender_text:
    output += f'=== 발신자 패턴 ===\n{sender_text}\n'
if corrections_text:
    output += f'=== 최근 사용자 수정 (이 패턴을 반영해) ===\n{corrections_text}\n'

print(output)
" 2>/dev/null || echo ""
}

# === JSON 파싱 헬퍼 ===
extract_json() {
  # stdin에서 첫 번째 JSON 객체를 추출
  python3 -c "
import sys
raw = sys.stdin.read()
start = raw.find('{')
end = raw.rfind('}') + 1
if start == -1 or end == 0:
    sys.exit(1)
print(raw[start:end])
" 2>/dev/null
}

# === 라벨 로드 ===
load_label_descriptions() {
  python3 -c "
import json
with open('$CONFIG_DIR/labels.json') as f:
    data = json.load(f)
for label in data.get('labels', []):
    name = label['name']
    desc = label.get('description', '')
    archive = label.get('default_archive', False)
    print(f'- {name}: {desc} (archive:{archive})')
" 2>/dev/null || echo ""
}
