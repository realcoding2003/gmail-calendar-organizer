#!/bin/bash
# Phase 1: 프로그래밍 방식 패턴 매칭 (메모리 기반, LLM 미사용)
# Phase 2: 상세 분류 — need_body 메일만 본문 포함하여 개별 AI 분류
# === Phase 1: 메모리 패턴 매칭 (발신자+제목 키워드) ===
pre_classify() {
  local mail_list_json="$1"
  local acct="$2"

  echo "$mail_list_json" | python3 -c "
import json, sys, os, re

memory_dir = '$MEMORY_DIR'

# 발신자 패턴 로드
try:
    with open(os.path.join(memory_dir, 'sender-patterns.json')) as f:
        patterns = json.load(f).get('patterns', {})
except:
    patterns = {}

# 분류 규칙 로드
try:
    with open(os.path.join(memory_dir, 'classification-rules.json')) as f:
        rules = json.load(f).get('rules', [])
except:
    rules = []

def extract_email_domain(from_header):
    \"\"\"From 헤더에서 이메일과 도메인 추출\"\"\"
    m = re.search(r'<([^>]+)>', from_header)
    email = m.group(1).lower() if m else from_header.strip().lower()
    domain = email.split('@')[-1] if '@' in email else ''
    return email, domain

data = json.load(sys.stdin)
fast = []
need_body = []

for msg in data.get('messages', []):
    mid = msg['id']
    subject = msg.get('subject', '')
    from_addr = msg.get('from', '')
    email, domain = extract_email_domain(from_addr)
    subject_lower = subject.lower()
    matched = False

    # 1. 발신자 패턴 매칭 — 엄격 매칭
    #    패턴 키가 @ 포함 → 이메일 정확 일치
    #    패턴 키가 도메인 → 도메인 정확 일치 또는 서브도메인 (.key로 끝남)
    for key, val in patterns.items():
        if key.startswith('_'):
            continue
        key_lower = key.lower()
        if '@' in key_lower:
            if email == key_lower:
                fast.append({
                    'id': mid, 'label': val['label'], 'confidence': 0.95,
                    'reason': f'발신자 매칭: {key} → {val[\"label\"]}'
                })
                matched = True
                break
        else:
            if domain == key_lower or domain.endswith('.' + key_lower):
                fast.append({
                    'id': mid, 'label': val['label'], 'confidence': 0.95,
                    'reason': f'발신자 도메인 매칭: {key} → {val[\"label\"]}'
                })
                matched = True
                break

    if matched:
        continue

    # 2. 제목 키워드 규칙 매칭 — confidence 0.8 이상만, 3글자 이상 키워드만
    for rule in rules:
        conf = rule.get('confidence', 0.9)
        if conf < 0.8:
            continue
        pat = rule.get('pattern', {})
        kw = (pat.get('subject_contains') or '').lower()
        label = rule.get('action', {}).get('label', '')

        if kw and len(kw) >= 3 and kw in subject_lower:
            fast.append({
                'id': mid, 'label': label, 'confidence': conf,
                'reason': f'키워드 매칭: \"{kw}\" → {label}'
            })
            matched = True
            break

    if not matched:
        need_body.append({'id': mid, 'reason': '매칭 패턴 없음'})

print(json.dumps({'fast': fast, 'need_body': need_body}, ensure_ascii=False))
" 2>/dev/null || echo '{"fast":[],"need_body":[]}'
}

# === Phase 1 결과 처리: fast 항목 라벨 적용 (직접 API, subprocess 없음) ===
process_pre_classify_result() {
  local result_json="$1"
  local acct="$2"

  echo "$result_json" | python3 -c "
import json, sys, os
sys.path.insert(0, '$LIB_DIR')
from google_api import get_auth, GmailClient

raw = sys.stdin.read()
start = raw.find('{'); end = raw.rfind('}') + 1
if start == -1:
    print('FAST_DONE:0')
    sys.exit(0)
data = json.loads(raw[start:end])

log_file = '$EMAIL_LOG'
now_kst = '$NOW_KST'
acct = '$acct'

# API 클라이언트 1회 초기화
auth = get_auth(acct, '$PROJECT_ROOT')
client = GmailClient(auth)

count = 0
for item in data.get('fast', []):
    tid = item.get('id', '')
    label = item.get('label', '')
    conf = item.get('confidence', 0.9)
    reason = item.get('reason', '')

    if not tid or not label:
        continue

    # 라벨 적용 + 보관 (한 번의 API 호출)
    try:
        if label.lower() == 'null' or label == '분류안함':
            status = 'skip'
        else:
            client.modify_labels([tid], add_labels=[label], remove_labels=['INBOX'])
            status = 'success'
    except Exception as e:
        status = 'failed'

    # 로그
    with open(log_file, 'a') as f:
        f.write(json.dumps({
            'time': now_kst, 'account': acct, 'email_id': tid,
            'label': label, 'confidence': conf, 'method': 'fast',
            'reason': reason
        }, ensure_ascii=False) + '\n')

    count += 1
    print(f'FAST: {label} | {reason} [{status}]')

# need_body ID 목록 출력
need_ids = [item.get('id','') for item in data.get('need_body', []) if item.get('id')]
for nid in need_ids:
    print(f'NEED_BODY:{nid}')

print(f'FAST_DONE:{count}')
" 2>/dev/null
}

# === Phase 2: 상세 분류 프롬프트 빌드 ===
build_classify_prompt() {
  local emails="$1"
  local acct="$2"

  local template
  template=$(cat "$PROMPTS_DIR/classify-email.txt")
  template="${template//\{TODAY\}/$(date +%Y-%m-%d)}"

  local memory_ctx
  memory_ctx=$(load_memory_context)

  local label_desc
  label_desc=$(load_label_descriptions)

  echo "${template}

${memory_ctx}
=== 현재 라벨 목록 ===
${label_desc}

계정: $acct
=== 메일 데이터 ===
$emails"
}

# === Phase 2: LLM 호출 ===
classify_emails() {
  local emails="$1"
  local acct="$2"

  local prompt
  prompt=$(build_classify_prompt "$emails" "$acct")

  llm_call "$prompt" 2>/dev/null || echo '{"results":[],"new_label_suggestions":[],"fast_patterns":[]}'
}

# === Phase 2: 분류 결과 처리 ===
process_classification_result() {
  local result_json="$1"
  local acct="$2"
  local threshold="${CONFIDENCE_THRESHOLD:-0.6}"

  echo "$result_json" | python3 -c "
import json, sys, os
sys.path.insert(0, '$LIB_DIR')
from google_api import get_auth, GmailClient

raw = sys.stdin.read()
start = raw.find('{'); end = raw.rfind('}') + 1
if start == -1: sys.exit(0)
data = json.loads(raw[start:end])

threshold = float('$threshold')
queue_dir = '$QUEUE_DIR'
log_file = '$EMAIL_LOG'
now_kst = '$NOW_KST'
acct = '$acct'
memory_dir = '$MEMORY_DIR'

# API 클라이언트 1회 초기화
auth = get_auth(acct, '$PROJECT_ROOT')
client = GmailClient(auth)

auto_count = 0
queue_count = 0
schedule_count = 0

for item in data.get('results', []):
    mid = item.get('id', '')
    cls = item.get('classification', {})
    schedule = item.get('schedule')
    log_entry = item.get('log', {})
    needs_review = item.get('needs_user_review', False)
    review_reason = item.get('review_reason', '')

    label = cls.get('label', '') or ''
    conf = cls.get('confidence', 0.8)
    cls_reason = cls.get('reason', '')

    title = log_entry.get('title', '')
    sender = log_entry.get('from', '')
    mail_date = log_entry.get('date', '')
    urgency = log_entry.get('urgency', 'none')
    summary = log_entry.get('summary', '')

    # --- 로그 기록 (모든 메일) ---
    with open(log_file, 'a') as f:
        f.write(json.dumps({
            'time': now_kst, 'account': acct, 'email_id': mid,
            'title': title, 'from': sender, 'label': label,
            'confidence': conf, 'urgency': urgency, 'summary': summary,
            'has_schedule': schedule is not None, 'needs_review': needs_review,
            'method': 'ai'
        }, ensure_ascii=False) + '\n')

    # --- 사용자 확인 필요 → "확인필요" 라벨 + INBOX 유지 + 분류 큐 ---
    if needs_review or conf < threshold:
        try:
            client.modify_labels([mid], add_labels=['확인필요'], remove_labels=[])
        except:
            pass
        item_id = f'pending-{mid[:12]}'
        queue_path = os.path.join(queue_dir, 'classifications', f'{item_id}.json')
        with open(queue_path, 'w') as f:
            json.dump({
                'id': item_id, 'created': now_kst,
                'email_id': mid, 'account': acct,
                'subject': title, 'from': sender, 'date': mail_date,
                'summary': summary,
                'ai_suggestion': {'label': label, 'confidence': conf, 'reason': review_reason or cls_reason},
                'action': None, 'action_arg': None
            }, f, ensure_ascii=False, indent=2)
        queue_count += 1
        print(f'QUEUE: {title[:50]} (conf:{conf:.1f}) {review_reason}')
        continue

    # --- 자동 분류 실행 (라벨 + 보관) ---
    if mid and label and label not in ('분류안함', 'null', ''):
        try:
            client.modify_labels([mid], add_labels=[label], remove_labels=['INBOX'])
            status = 'success'
        except:
            status = 'failed'
        auto_count += 1
        print(f'AI: {label} | {title[:50]} | {sender[:30]} [{status}]')

    # --- 일정 감지 → 캘린더 큐 (1건 = 1파일) ---
    if schedule:
        cal_id = f'cal-{mid[:12]}'
        cal_path = os.path.join(queue_dir, 'calendars', f'{cal_id}.json')
        with open(cal_path, 'w') as f:
            json.dump({
                'id': cal_id, 'created': now_kst,
                'source_email': title, 'account': acct,
                'proposal': {
                    'type': schedule.get('type', 'event'),
                    'summary': schedule.get('summary', title),
                    'start': schedule.get('start', ''),
                    'end': schedule.get('end', ''),
                    'location': schedule.get('location'),
                },
                'confidence': schedule.get('confidence', 0.5),
                'needs_confirm': schedule.get('needs_confirm', True),
                'action': None, 'action_arg': None
            }, f, ensure_ascii=False, indent=2)
        schedule_count += 1
        print(f'SCHEDULE: {schedule.get(\"summary\",\"\")} ({schedule.get(\"start\",\"\")[:16]})')

# --- 새 라벨 제안 → 큐 ---
for suggestion in data.get('new_label_suggestions', []):
    label_id = f'label-{suggestion.get(\"name\",\"\")}'
    label_path = os.path.join(queue_dir, 'labels', f'{label_id}.json')
    with open(label_path, 'w') as f:
        json.dump({
            'id': label_id, 'created': now_kst,
            'suggested_name': suggestion.get('name', ''),
            'reason': suggestion.get('reason', ''),
            'sample_subjects': suggestion.get('sample_subjects', []),
            'email_ids': suggestion.get('email_ids', [mid] if mid else []),
            'account': acct,
            'action': None, 'action_arg': None
        }, f, ensure_ascii=False, indent=2)
    print(f'NEW_LABEL: {suggestion.get(\"name\",\"\")}')

# --- 메모리 학습 ---
for mem in data.get('memory_updates', []):
    mem_type = mem.get('type', '')
    if mem_type == 'sender_pattern':
        pf = os.path.join(memory_dir, 'sender-patterns.json')
        try:
            with open(pf) as f: patterns = json.load(f)
        except: patterns = {'version':1,'last_updated':None,'patterns':{}}
        sender_key = mem.get('from', '')
        if sender_key and sender_key not in patterns['patterns']:
            patterns['patterns'][sender_key] = {
                'label': mem.get('label',''), 'archive': True,
                'count': 1, 'last_seen': now_kst[:10], 'note': mem.get('note','')
            }
            patterns['last_updated'] = now_kst
            with open(pf, 'w') as f:
                json.dump(patterns, f, ensure_ascii=False, indent=2)
    elif mem_type == 'keyword_pattern':
        rf = os.path.join(memory_dir, 'classification-rules.json')
        try:
            with open(rf) as f: rules_data = json.load(f)
        except: rules_data = {'version':1,'last_updated':None,'rules':[],'label_descriptions':{}}
        kw = mem.get('keyword', '')
        if kw:
            rules_data['rules'].append({
                'id': f'rule-auto-{len(rules_data[\"rules\"])+1:03d}',
                'pattern': {'from_contains': None, 'subject_contains': kw},
                'action': {'label': mem.get('label',''), 'archive': True},
                'confidence': 0.7, 'source': 'ai_learned',
                'created': now_kst[:10], 'applied_count': 0, 'note': mem.get('note','')
            })
            rules_data['last_updated'] = now_kst
            with open(rf, 'w') as f:
                json.dump(rules_data, f, ensure_ascii=False, indent=2)

# --- fast_patterns 학습 (Phase 2 → Phase 1 fast로 승격) ---
fast_learned = 0
for pat in data.get('fast_patterns', []):
    pat_type = pat.get('type', '')
    match_key = pat.get('match', '')
    label = pat.get('label', '')
    reason = pat.get('reason', '')
    if not match_key or not label:
        continue

    if pat_type == 'sender':
        pf = os.path.join(memory_dir, 'sender-patterns.json')
        try:
            with open(pf) as f: sp = json.load(f)
        except: sp = {'version':1,'last_updated':None,'patterns':{}}
        if match_key not in sp['patterns']:
            sp['patterns'][match_key] = {
                'label': label, 'archive': True,
                'count': 1, 'last_seen': now_kst[:10],
                'note': f'AI fast: {reason}'
            }
            sp['last_updated'] = now_kst
            with open(pf, 'w') as f:
                json.dump(sp, f, ensure_ascii=False, indent=2)
            fast_learned += 1
            print(f'FAST_LEARN: {match_key} -> {label}')

    elif pat_type == 'keyword':
        rf = os.path.join(memory_dir, 'classification-rules.json')
        try:
            with open(rf) as f: rd = json.load(f)
        except: rd = {'version':1,'last_updated':None,'rules':[],'label_descriptions':{}}
        exists = any(r.get('pattern',{}).get('subject_contains') == match_key for r in rd['rules'])
        if not exists:
            rd['rules'].append({
                'id': f'rule-fast-{len(rd[\"rules\"])+1:03d}',
                'pattern': {'from_contains': None, 'subject_contains': match_key},
                'action': {'label': label, 'archive': True},
                'confidence': 0.9, 'source': 'ai_fast_pattern',
                'created': now_kst[:10], 'applied_count': 0,
                'note': f'AI fast: {reason}'
            })
            rd['last_updated'] = now_kst
            with open(rf, 'w') as f:
                json.dump(rd, f, ensure_ascii=False, indent=2)
            fast_learned += 1
            print(f'FAST_LEARN: keyword \"{match_key}\" -> {label}')

print(f'SUMMARY: auto={auto_count} queued={queue_count} schedules={schedule_count} fast_learned={fast_learned}')
" 2>/dev/null
}
