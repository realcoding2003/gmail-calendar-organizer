#!/bin/bash
# 피드백 처리기 - 사용자 결정 실행 + 메모리 자동 학습
#
# 사용법:
#   1건 처리: bash feedback-processor.sh <큐파일> <decision> [label]
#     예: bash feedback-processor.sh data/queue/classifications/pending-abc.json approve 광고
#     예: bash feedback-processor.sh data/queue/classifications/pending-abc.json reject
#     예: bash feedback-processor.sh data/queue/calendars/cal-abc.json approve
#
#   전체 처리: bash feedback-processor.sh --all
#     decision이 설정된 모든 큐 파일 일괄 처리
#
# 알림 봇 연동: 봇이 사용자 답변 해석 후 이 스크립트를 단일 건으로 호출

set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPTS/lib/common.sh"

FEEDBACK_LOG="$LOG_DIR/feedback-${TODAY}.jsonl"

# 단일 건 처리: 인수로 큐 파일 + decision 전달
if [ "${1:-}" != "--all" ] && [ -n "${1:-}" ]; then
  QUEUE_FILE="$1"
  DECISION="${2:-}"
  USER_LABEL="${3:-}"

  if [ ! -f "$QUEUE_FILE" ]; then
    echo "파일 없음: $QUEUE_FILE"
    exit 1
  fi

  if [ -z "$DECISION" ]; then
    echo "사용법: feedback-processor.sh <큐파일> <approve|reject|modify> [라벨]"
    exit 1
  fi

  # 큐 파일에 decision 설정
  python3 -c "
import json
with open('$QUEUE_FILE') as f:
    item = json.load(f)
item['decision'] = '$DECISION'
if '$USER_LABEL':
    item['user_label'] = '$USER_LABEL'
with open('$QUEUE_FILE', 'w') as f:
    json.dump(item, f, ensure_ascii=False, indent=2)
"
fi

# 이하 처리 로직 (단일 건이든 --all이든 동일)

python3 -c "
import json, sys, os, re, glob
sys.path.insert(0, '$LIB_DIR')
from google_api import get_auth, GmailClient, CalendarClient

queue_dir = '$QUEUE_DIR'
memory_dir = '$MEMORY_DIR'
config_dir = '$CONFIG_DIR'
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

# 메모리 로드
def load_json(path, default):
    try:
        with open(path) as f: return json.load(f)
    except: return default

patterns = load_json(os.path.join(memory_dir, 'sender-patterns.json'),
    {'version': 1, 'last_updated': None, 'patterns': {}})
rules = load_json(os.path.join(memory_dir, 'classification-rules.json'),
    {'version': 1, 'last_updated': None, 'rules': [], 'label_descriptions': {}})

memory_changed = False
total = 0

# ============================================
# 1. 분류 큐 (data/queue/classifications/*.json)
# ============================================
for fpath in sorted(glob.glob(os.path.join(queue_dir, 'classifications', '*.json'))):
    with open(fpath) as f:
        item = json.load(f)

    decision = item.get('decision')
    if decision is None:
        continue  # 아직 미결정

    email_id = item.get('email_id', '')
    acct = item.get('account', '')
    sender_raw = item.get('from', '')
    sender_email = extract_email(sender_raw)
    sender_domain = extract_domain(sender_email)
    subject = item.get('subject', '')
    ai_label = item.get('ai_suggestion', {}).get('label', '')
    final_label = None

    if decision == 'approve':
        final_label = item.get('user_label') or ai_label
    elif decision == 'modify':
        final_label = item.get('user_label', '')
    elif decision == 'reject':
        final_label = None

    # Gmail 적용
    if final_label and email_id and final_label not in ('분류안함', 'null', ''):
        try:
            client = get_client(acct)
            client.modify_labels([email_id], add_labels=[final_label, '_processed'], remove_labels=['INBOX'])
            print(f'  분류: {final_label} <- {subject[:40]}')
        except Exception as e:
            print(f'  실패: {subject[:40]} - {e}')
    elif decision == 'reject' and email_id:
        try:
            client = get_client(acct)
            # 삭제 (휴지통으로 이동)
            client.service.users().threads().trash(userId='me', id=email_id).execute()
            print(f'  삭제: {subject[:40]}')
        except Exception as e:
            print(f'  삭제실패: {subject[:40]} - {e}')

    # 발신자 패턴 학습
    if decision in ('approve', 'modify') and final_label:
        key = sender_domain or sender_email
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

    # AI 오분류 수정 → 규칙 추가
    if decision == 'modify' and final_label and ai_label != final_label:
        rules['rules'].append({
            'id': f'rule-fb-{len(rules[\"rules\"])+1:03d}',
            'pattern': {'from_contains': sender_domain, 'subject_contains': None},
            'action': {'label': final_label, 'archive': True},
            'confidence': 0.85, 'source': 'user_correction',
            'created': now_kst[:10], 'applied_count': 0,
            'note': f'{ai_label} -> {final_label}'
        })
        memory_changed = True

    # 이력 기록
    with open(os.path.join(memory_dir, 'user-corrections.jsonl'), 'a') as f:
        f.write(json.dumps({
            'time': now_kst, 'sender': sender_email, 'domain': sender_domain,
            'subject': subject[:60], 'original': ai_label,
            'final': final_label or '(거부)', 'decision': decision
        }, ensure_ascii=False) + '\n')

    # 피드백 로그
    with open(feedback_log, 'a') as f:
        f.write(json.dumps({
            'time': now_kst, 'id': item.get('id',''),
            'decision': decision, 'original': ai_label,
            'final': final_label or '(거부)', 'sender': sender_domain
        }, ensure_ascii=False) + '\n')

    # 처리 완료 → 파일 삭제
    os.remove(fpath)
    total += 1

# ============================================
# 2. 캘린더 큐 (data/queue/calendars/*.json)
# ============================================
for fpath in sorted(glob.glob(os.path.join(queue_dir, 'calendars', '*.json'))):
    with open(fpath) as f:
        item = json.load(f)

    decision = item.get('decision')
    if decision is None:
        continue

    proposal = item.get('proposal', {})
    acct = item.get('account', '')

    if decision in ('approve', 'modify'):
        p = item.get('modified_proposal', proposal) if decision == 'modify' else proposal
        try:
            with open(os.path.join(config_dir, 'accounts.json')) as f:
                cal_id = 'primary'
                for a in json.load(f).get('accounts', []):
                    if a['email'] == acct:
                        cal_id = a.get('calendar_id', 'primary')
                        break
            cal_client = CalendarClient(get_auth(acct, project_root))
            cal_client.create_event(cal_id, p.get('summary',''), p.get('start',''), p.get('end',''), p.get('location'))
            print(f'  캘린더: {p.get(\"summary\",\"\")}')
        except Exception as e:
            print(f'  캘린더 실패: {e}')
    else:
        print(f'  캘린더 스킵: {proposal.get(\"summary\",\"\")}')

    os.remove(fpath)
    total += 1

# ============================================
# 3. 라벨 큐 (data/queue/labels/*.json)
# ============================================
for fpath in sorted(glob.glob(os.path.join(queue_dir, 'labels', '*.json'))):
    with open(fpath) as f:
        item = json.load(f)

    decision = item.get('decision')
    if decision is None:
        continue

    if decision == 'approve':
        label_name = item.get('suggested_name', '')
        for acct in item.get('accounts', []):
            try:
                get_client(acct).create_label(label_name)
            except: pass

        try:
            with open(os.path.join(config_dir, 'labels.json')) as f:
                cfg = json.load(f)
            if not any(l['name'] == label_name for l in cfg['labels']):
                cfg['labels'].append({
                    'name': label_name,
                    'description': item.get('reason', ''),
                    'default_archive': True
                })
                with open(os.path.join(config_dir, 'labels.json'), 'w') as f:
                    json.dump(cfg, f, ensure_ascii=False, indent=2)
        except: pass
        print(f'  새 라벨: {label_name}')

    os.remove(fpath)
    total += 1

# ============================================
# 4. 메모리 저장
# ============================================
if memory_changed:
    patterns['last_updated'] = now_kst
    with open(os.path.join(memory_dir, 'sender-patterns.json'), 'w') as f:
        json.dump(patterns, f, ensure_ascii=False, indent=2)
    rules['last_updated'] = now_kst
    with open(os.path.join(memory_dir, 'classification-rules.json'), 'w') as f:
        json.dump(rules, f, ensure_ascii=False, indent=2)
    print(f'  메모리: 패턴 {len(patterns[\"patterns\"])}개, 규칙 {len(rules[\"rules\"])}개')

if total > 0:
    print(f'피드백 처리: {total}건')
else:
    print('처리할 피드백 없음')
"

exit 0
