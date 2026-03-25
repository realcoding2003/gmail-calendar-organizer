#!/bin/bash
# 피드백 처리기 - 명확한 명령 기반 실행 + 메모리 자동 학습
#
# 사용법:
#   bash feedback-processor.sh <큐파일> <명령> [인수]
#
# 명령:
#   label <라벨명>    라벨 적용 + 보관 (INBOX 제거)
#   delete            Gmail 휴지통으로 이동
#   archive           라벨 없이 보관만 (INBOX 제거)
#   skip              아무것도 안 함 (큐 파일만 제거)
#   calendar          캘린더 일정 등록
#
# 예시:
#   bash feedback-processor.sh data/queue/classifications/pending-abc.json label 광고
#   bash feedback-processor.sh data/queue/classifications/pending-abc.json delete
#   bash feedback-processor.sh data/queue/classifications/pending-abc.json archive
#   bash feedback-processor.sh data/queue/classifications/pending-abc.json skip
#   bash feedback-processor.sh data/queue/calendars/cal-abc.json calendar
#
# AI 제안과 다른 라벨 지정 시 → 오분류로 기록 + 발신자 패턴 학습
#
# 일괄 처리 (action이 설정된 파일만):
#   bash feedback-processor.sh --all

set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPTS/lib/common.sh"

FEEDBACK_LOG="$LOG_DIR/feedback-${TODAY}.jsonl"

# 단일 건 처리
if [ "${1:-}" != "--all" ] && [ -n "${1:-}" ]; then
  QUEUE_FILE="$1"
  ACTION="${2:-}"
  ACTION_ARG="${3:-}"

  if [ ! -f "$QUEUE_FILE" ]; then
    echo "파일 없음: $QUEUE_FILE"
    exit 1
  fi

  if [ -z "$ACTION" ]; then
    echo "사용법: feedback-processor.sh <큐파일> <label|delete|archive|skip|calendar> [인수]"
    echo ""
    echo "명령:"
    echo "  label <라벨명>    라벨 적용 + 보관"
    echo "  delete            삭제 (휴지통)"
    echo "  archive           라벨 없이 보관"
    echo "  skip              큐에서만 제거"
    echo "  calendar          캘린더 등록"
    exit 1
  fi

  # 큐 파일에 action 설정
  python3 -c "
import json
with open('$QUEUE_FILE') as f:
    item = json.load(f)
item['action'] = '$ACTION'
item['action_arg'] = '$ACTION_ARG' if '$ACTION_ARG' else None
with open('$QUEUE_FILE', 'w') as f:
    json.dump(item, f, ensure_ascii=False, indent=2)
"
fi

# 처리 로직
python3 -c "
import json, sys, os, re, glob
sys.path.insert(0, '$LIB_DIR')
from google_api import get_auth, GmailClient, CalendarClient

queue_dir = '$QUEUE_DIR'
memory_dir = '$MEMORY_DIR'
config_dir = '$CONFIG_DIR'
data_dir = '$DATA_DIR'
feedback_log = '$FEEDBACK_LOG'
now_kst = '$NOW_KST'
project_root = '$PROJECT_ROOT'

def extract_email(sender):
    match = re.search(r'<([^>]+)>', sender)
    return match.group(1) if match else sender.strip()

def extract_domain(email):
    parts = email.split('@')
    return parts[1] if len(parts) == 2 else email

clients = {}
def get_client(acct):
    if acct not in clients:
        clients[acct] = GmailClient(get_auth(acct, project_root))
    return clients[acct]

def load_json(path, default):
    try:
        with open(path) as f: return json.load(f)
    except: return default

def save_json(path, data):
    with open(path, 'w') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)

# 메모리 로드
patterns = load_json(os.path.join(memory_dir, 'sender-patterns.json'),
    {'version': 1, 'last_updated': None, 'patterns': {}})
rules = load_json(os.path.join(memory_dir, 'classification-rules.json'),
    {'version': 1, 'last_updated': None, 'rules': [], 'label_descriptions': {}})

memory_changed = False
total = 0

# ============================================
# 분류 큐 처리 (data/queue/classifications/*.json)
# ============================================
for fpath in sorted(glob.glob(os.path.join(queue_dir, 'classifications', '*.json'))):
    with open(fpath) as f:
        item = json.load(f)

    action = item.get('action')
    if action is None:
        continue

    email_id = item.get('email_id', '')
    acct = item.get('account', '')
    sender_raw = item.get('from', '')
    sender_email = extract_email(sender_raw)
    sender_domain = extract_domain(sender_email)
    subject = item.get('subject', '')
    ai_label = item.get('ai_suggestion', {}).get('label', '')
    action_arg = item.get('action_arg', '')

    # --- 명령 실행 ---
    final_label = None

    if action == 'label' and action_arg:
        final_label = action_arg
        try:
            client = get_client(acct)
            client.modify_labels([email_id], add_labels=[final_label, '_processed'], remove_labels=['INBOX'])
            print(f'  라벨: {final_label} <- {subject[:40]}')
        except Exception as e:
            print(f'  실패: {subject[:40]} - {e}')

    elif action == 'delete':
        try:
            client = get_client(acct)
            client.service.users().threads().trash(userId='me', id=email_id).execute()
            print(f'  삭제: {subject[:40]}')
        except Exception as e:
            print(f'  삭제실패: {subject[:40]} - {e}')

    elif action == 'archive':
        try:
            client = get_client(acct)
            client.modify_labels([email_id], add_labels=['_processed'], remove_labels=['INBOX'])
            print(f'  보관: {subject[:40]}')
        except Exception as e:
            print(f'  보관실패: {subject[:40]} - {e}')

    elif action == 'skip':
        print(f'  스킵: {subject[:40]}')

    # --- 학습 ---
    if action == 'label' and final_label:
        key = sender_domain or sender_email

        # AI 제안과 다르면 오분류 기록
        is_correction = ai_label and final_label != ai_label

        if key:
            existing = patterns['patterns'].get(key)
            if existing:
                existing['count'] = existing.get('count', 0) + 1
                existing['label'] = final_label
                existing['last_seen'] = now_kst[:10]
            else:
                patterns['patterns'][key] = {
                    'label': final_label, 'archive': True,
                    'count': 1, 'last_seen': now_kst[:10],
                    'note': f'피드백: {sender_raw[:30]}'
                }
            memory_changed = True

        # 오분류 → 규칙 추가
        if is_correction:
            rules['rules'].append({
                'id': f'rule-fb-{len(rules[\"rules\"])+1:03d}',
                'pattern': {'from_contains': sender_domain, 'subject_contains': None},
                'action': {'label': final_label, 'archive': True},
                'confidence': 0.85, 'source': 'user_correction',
                'created': now_kst[:10], 'applied_count': 0,
                'note': f'{ai_label} -> {final_label}'
            })
            memory_changed = True
            print(f'  학습: {sender_domain} {ai_label} -> {final_label}')

    # 이력 기록
    with open(os.path.join(memory_dir, 'user-corrections.jsonl'), 'a') as f:
        f.write(json.dumps({
            'time': now_kst, 'action': action, 'label': final_label,
            'sender': sender_email, 'domain': sender_domain,
            'subject': subject[:60], 'ai_label': ai_label,
            'is_correction': action == 'label' and ai_label and final_label != ai_label
        }, ensure_ascii=False) + '\n')

    # 피드백 로그
    with open(feedback_log, 'a') as f:
        f.write(json.dumps({
            'time': now_kst, 'id': item.get('id', ''),
            'action': action, 'label': final_label,
            'ai_label': ai_label, 'sender': sender_domain
        }, ensure_ascii=False) + '\n')

    os.remove(fpath)
    total += 1

# ============================================
# 캘린더 큐 처리 (data/queue/calendars/*.json)
# ============================================
for fpath in sorted(glob.glob(os.path.join(queue_dir, 'calendars', '*.json'))):
    with open(fpath) as f:
        item = json.load(f)

    action = item.get('action')
    if action is None:
        continue

    proposal = item.get('proposal', {})
    acct = item.get('account', '')

    if action == 'calendar':
        try:
            with open(os.path.join(config_dir, 'accounts.json')) as f:
                cal_id = 'primary'
                for a in json.load(f).get('accounts', []):
                    if a['email'] == acct:
                        cal_id = a.get('calendar_id', 'primary')
                        break
            cal_client = CalendarClient(get_auth(acct, project_root))
            cal_client.create_event(cal_id, proposal.get('summary',''),
                proposal.get('start',''), proposal.get('end',''), proposal.get('location'))
            print(f'  캘린더: {proposal.get(\"summary\",\"\")}')
        except Exception as e:
            print(f'  캘린더 실패: {e}')

    elif action == 'skip':
        print(f'  캘린더 스킵: {proposal.get(\"summary\",\"\")}')

    elif action == 'delete':
        print(f'  캘린더 삭제: {proposal.get(\"summary\",\"\")}')

    with open(feedback_log, 'a') as f:
        f.write(json.dumps({
            'time': now_kst, 'type': 'calendar',
            'action': action, 'summary': proposal.get('summary', '')
        }, ensure_ascii=False) + '\n')

    os.remove(fpath)
    total += 1

# ============================================
# 라벨 큐 처리 (data/queue/labels/*.json)
# ============================================
for fpath in sorted(glob.glob(os.path.join(queue_dir, 'labels', '*.json'))):
    with open(fpath) as f:
        item = json.load(f)

    action = item.get('action')
    if action is None:
        continue

    if action == 'label':
        label_name = item.get('action_arg') or item.get('suggested_name', '')
        for acct in item.get('accounts', []):
            try:
                get_client(acct).create_label(label_name)
            except: pass

        # data/labels.json 업데이트
        labels_file = os.path.join(data_dir, 'labels.json')
        try:
            with open(labels_file) as f:
                cfg = json.load(f)
        except:
            cfg = {'labels': []}
        if not any(l['name'] == label_name for l in cfg['labels']):
            cfg['labels'].append({
                'name': label_name,
                'description': item.get('reason', ''),
                'default_archive': True
            })
            save_json(labels_file, cfg)
        print(f'  새 라벨: {label_name}')

    elif action == 'skip':
        print(f'  라벨 스킵: {item.get(\"suggested_name\",\"\")}')

    os.remove(fpath)
    total += 1

# ============================================
# 메모리 저장
# ============================================
if memory_changed:
    patterns['last_updated'] = now_kst
    save_json(os.path.join(memory_dir, 'sender-patterns.json'), patterns)
    rules['last_updated'] = now_kst
    save_json(os.path.join(memory_dir, 'classification-rules.json'), rules)
    print(f'  메모리: 패턴 {len(patterns[\"patterns\"])}개, 규칙 {len(rules[\"rules\"])}개')

if total > 0:
    print(f'처리 완료: {total}건')
else:
    print('처리할 항목 없음')
"

exit 0
