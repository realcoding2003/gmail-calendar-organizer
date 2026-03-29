#!/bin/bash
# 메모리 통합 - 주 1회 cron 실행
# Ollama 로컬 LLM으로 메모리 분석 + 최적화
#
# 1. 현재 메모리 + 수정 이력 → LLM이 분석
# 2. 패턴 병합/정리/충돌 감지
# 3. 최적화된 메모리 저장
# 4. 정확도 리포트 생성

set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPTS/lib/common.sh"

echo "=== 메모리 통합 시작 ($(date '+%Y-%m-%d %H:%M')) ==="

# 현재 메모리 수집
PATTERNS=$(cat "$MEMORY_DIR/sender-patterns.json" 2>/dev/null || echo '{}')
RULES=$(cat "$MEMORY_DIR/classification-rules.json" 2>/dev/null || echo '{}')
CORRECTIONS=""
if [ -f "$MEMORY_DIR/user-corrections.jsonl" ]; then
  # 최근 100건만
  CORRECTIONS=$(tail -100 "$MEMORY_DIR/user-corrections.jsonl" 2>/dev/null || echo "")
fi

# 최근 7일 로그 통계
LOG_STATS=$(python3 -c "
import json, os, glob
from collections import Counter

log_dir = '$LOG_DIR'
files = sorted(glob.glob(os.path.join(log_dir, 'email-*.jsonl')))[-7:]

stats = {'total': 0, 'fast': 0, 'ai': 0, 'queued': 0, 'labels': Counter()}
for f in files:
    with open(f) as fh:
        for line in fh:
            try:
                e = json.loads(line.strip())
                stats['total'] += 1
                m = e.get('method', '')
                if m == 'fast': stats['fast'] += 1
                elif m == 'ai': stats['ai'] += 1
                if e.get('needs_review'): stats['queued'] += 1
                if e.get('label'): stats['labels'][e['label']] += 1
            except: pass

print(json.dumps({
    'total': stats['total'], 'fast': stats['fast'],
    'ai': stats['ai'], 'queued': stats['queued'],
    'label_distribution': dict(stats['labels'].most_common(20))
}, ensure_ascii=False))
" 2>/dev/null || echo '{}')

# 프롬프트 빌드
TEMPLATE=$(cat "$PROMPTS_DIR/consolidate-memory.txt")
TEMPLATE="${TEMPLATE//\{TODAY\}/$(date +%Y-%m-%d)}"

PROMPT="${TEMPLATE}

=== 현재 발신자 패턴 ===
${PATTERNS}

=== 현재 분류 규칙 ===
${RULES}

=== 최근 사용자 수정 이력 (최근 100건) ===
${CORRECTIONS}

=== 최근 7일 분류 통계 ===
${LOG_STATS}"

# Ollama LLM으로 분석
echo "  LLM 분석 중 (${LLM_MODEL:-phi4})..."
T0=$(date +%s)

RESULT=$(llm_call "$PROMPT" 2>/dev/null || echo "")

T1=$(date +%s)
echo "  분석 완료: $((T1 - T0))초"

if [ -z "$RESULT" ]; then
  echo "  LLM 응답 없음. 스킵."
  exit 1
fi

# 결과 적용
python3 -c "
import json, sys, os, shutil
from datetime import datetime

raw = '''$( echo "$RESULT" | sed "s/'/'\\\\''/g" )'''

# JSON 추출
start = raw.find('{')
end = raw.rfind('}') + 1
if start == -1 or end == 0:
    print('JSON 파싱 실패')
    sys.exit(1)

data = json.loads(raw[start:end])
memory_dir = '$MEMORY_DIR'
now = datetime.now().strftime('%Y-%m-%d %H:%M')

# 백업
for fname in ['sender-patterns.json', 'classification-rules.json']:
    src = os.path.join(memory_dir, fname)
    if os.path.exists(src):
        bak = os.path.join(memory_dir, f'{fname}.bak')
        shutil.copy2(src, bak)

# 발신자 패턴 업데이트
if data.get('optimized_patterns'):
    patterns = {
        'version': 1,
        'last_updated': now,
        'patterns': data['optimized_patterns']
    }
    with open(os.path.join(memory_dir, 'sender-patterns.json'), 'w') as f:
        json.dump(patterns, f, ensure_ascii=False, indent=2)

# 분류 규칙 업데이트
if data.get('optimized_rules') is not None:
    # 기존 label_descriptions 유지
    try:
        with open(os.path.join(memory_dir, 'classification-rules.json')) as f:
            old = json.load(f)
        desc = old.get('label_descriptions', {})
    except:
        desc = {}

    rules = {
        'version': 1,
        'last_updated': now,
        'rules': data['optimized_rules'],
        'label_descriptions': desc
    }
    with open(os.path.join(memory_dir, 'classification-rules.json'), 'w') as f:
        json.dump(rules, f, ensure_ascii=False, indent=2)

# 통계 출력
stats = data.get('stats', {})
print(f'패턴: {stats.get(\"patterns_before\",\"?\")} → {stats.get(\"patterns_after\",\"?\")}')
print(f'규칙: {stats.get(\"rules_before\",\"?\")} → {stats.get(\"rules_after\",\"?\")}')

removed = stats.get('removed_patterns', [])
if removed:
    print(f'제거: {len(removed)}개 - {\", \".join(removed[:5])}')

merged = stats.get('merged_patterns', [])
if merged:
    print(f'병합: {len(merged)}개 - {\", \".join(merged[:5])}')

conflicts = data.get('conflicts', [])
if conflicts:
    print(f'충돌 감지: {len(conflicts)}건')
    for c in conflicts:
        print(f'  {c.get(\"key\",\"?\")} → {c.get(\"labels\",[])} ({c.get(\"recommendation\",\"\")})')
" 2>/dev/null

# 리포트 저장
echo "$RESULT" > "$LOG_DIR/memory-consolidation-$(date +%Y%m%d).json"

echo "=== 메모리 통합 완료 ==="

exit 0
