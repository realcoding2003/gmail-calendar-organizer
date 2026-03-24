#!/bin/bash
# 이메일 자동 분류 스크립트 - Claude Code CLI 기반
# 날짜 제한 없이 받은편지함 전체 처리 (--all 플래그)
# Max20 구독 사용량으로 처리 (API 비용 0)

set -euo pipefail

ACCOUNTS=("kevinpark@webace.co.kr" "contact@okyc.kr")

# 쿼리로 ID 전체 가져와서 labels modify 실행하는 헬퍼 함수
apply_label() {
  local query="$1"
  local label="$2"
  local archive="$3"  # true/false
  local acct="$4"

  IDS=$(gog gmail search "$query" --all --account "$acct" --json 2>/dev/null | \
    python3 -c "import json,sys; [print(t['id']) for t in json.load(sys.stdin).get('threads',[])]" 2>/dev/null || true)

  if [ -z "$IDS" ]; then return; fi

  COUNT=0
  # 50개씩 배치로 modify 실행
  echo "$IDS" | xargs -n 50 bash -c '
    ARGS=("$@")
    CMD=(gog gmail labels modify "${ARGS[@]}" --add "'"$label"'" --account "'"$acct"'" --force)
    if [ "'"$archive"'" = "true" ]; then CMD+=(--remove "INBOX"); fi
    "${CMD[@]}" 2>/dev/null || true
  ' _ && COUNT=$(echo "$IDS" | wc -l | tr -d ' ')

  echo "  ✓ $label: ${COUNT}건"
}

# =============================================
# 1단계: 규칙 기반 즉시 처리
# =============================================
echo "📌 규칙 기반 처리 시작..."

for acct in "${ACCOUNTS[@]}"; do
  echo ""
  echo "  [$acct]"

  # 명시적 광고 → 삭제
  TRASH_COUNT=$(gog gmail trash \
    --query 'in:inbox (subject:"(광고)" OR subject:"[광고]" OR subject:"(AD)" OR subject:"[AD]")' \
    --max 1000 --account "$acct" --force 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo 0)
  [ "$TRASH_COUNT" -gt 0 ] 2>/dev/null && echo "  🗑 명시적 광고 삭제: ${TRASH_COUNT}건" || true

  # 소셜
  apply_label 'in:inbox (from:linkedin.com OR from:facebookmail.com OR from:twitter.com OR from:instagram.com OR from:youtube.com OR from:medium.com)' "소셜" "true" "$acct"

  # 금융-결제
  apply_label 'in:inbox (subject:"결제하신 내역" OR subject:"이용대금명세서" OR subject:"결제 내역" OR subject:"청구서" OR subject:"세금계산서" OR from:bccard.com OR from:nonghyup.com OR from:naverpayadmin_noreply OR from:hanamail OR from:nicepg.co.kr OR from:kcp.co.kr OR from:billing-on.com OR from:hanacard.co.kr OR from:kosmes.or.kr OR from:makebill.co.kr)' "금융-결제" "true" "$acct"

  # 보안
  apply_label 'in:inbox (subject:"보안 알림" OR subject:"보안 경고" OR subject:"Security alert" OR from:no-reply@accounts.google.com)' "보안" "true" "$acct"

  # 광고/뉴스레터
  apply_label 'in:inbox (from:kova@kova.or.kr OR from:digest.producthunt.com OR from:marketing.descript.com OR from:bistep.re.kr OR from:glance.media OR from:no-reply@awscustomercouncil.com OR from:support@awscustomercouncil.com OR from:bizinfo.go.kr OR from:eg.hotels.com OR from:microsoft-noreply@microsoft.com OR from:news@nvidia.com OR from:googlecloud@google.com OR from:GoogleCloudStartups@google.com OR from:webinars@mail.anthropic.com OR from:team@email.anthropic.com OR from:hello@ollama.com OR from:hello@gamma.app)' "광고" "true" "$acct"

  # 개발-테크
  apply_label 'in:inbox (from:tailscale.com OR from:no_reply@email.apple.com OR from:googleplay-noreply@google.com OR from:azure-noreply@microsoft.com OR from:sc-noreply@google.com OR from:noreply@github.com)' "개발-테크" "true" "$acct"

  # 보험
  apply_label 'in:inbox (from:samsungfire.com OR from:sgic.co.kr)' "보험" "false" "$acct"

  # 도메인-호스팅
  apply_label 'in:inbox (from:hosting.kr OR from:godaddy.com OR from:dnsever.com)' "도메인-호스팅" "false" "$acct"

done

echo ""
echo "📌 규칙 처리 완료"
echo ""

# =============================================
# 2단계: Claude로 남은 메일 분류 (50건씩 배치)
# =============================================
echo "🤖 Claude 분류 처리..."

for acct in "${ACCOUNTS[@]}"; do
  echo ""
  echo "  [$acct]"

  PAGE_TOKEN=""
  BATCH=1

  while true; do
    if [ -z "$PAGE_TOKEN" ]; then
      INBOX=$(gog gmail search 'in:inbox' --max 50 --account "$acct" --json 2>/dev/null || echo '{"threads":[]}')
    else
      INBOX=$(gog gmail search 'in:inbox' --max 50 --page "$PAGE_TOKEN" --account "$acct" --json 2>/dev/null || echo '{"threads":[]}')
    fi

    THREAD_COUNT=$(echo "$INBOX" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('threads',[])))" 2>/dev/null || echo 0)
    [ "$THREAD_COUNT" -eq 0 ] && break

    RESULT=$(claude --print --allowed-tools "" -- "받은편지함 메일 분류. JSON만.

기존 라벨: 광고, 금융-결제, 보안, 정부-R&D, 보험, 개발-테크, 도메인-호스팅, 확인필요, 소셜

출력형식:
{\"new_labels\":[{\"name\":\"새라벨\",\"account\":\"이메일\"}],\"actions\":[{\"id\":\"id\",\"account\":\"이메일\",\"label\":\"라벨\",\"archive\":true}],\"urgent\":[\"긴급건\"]}

- SNS알림 → 소셜 archive:true
- 광고/뉴스레터 → 광고 archive:true
- 결제/청구/세금 → 금융-결제 archive:true
- 보안알림(긴급아닌것) → 보안 archive:true
- 정부/R&D/지원사업 → 정부-R&D archive:false
- 보험 → 보험 archive:false
- 개발/테크 정보성 → 개발-테크 archive:true
- 도메인/호스팅 → 도메인-호스팅 archive:false
- 액션필요(기한,계약) → 확인필요 archive:false
- 업무/개인메일 → 분류안함
- 같은종류 3건이상 새패턴 → new_labels 추가

계정: $acct
$INBOX" 2>/dev/null)

    echo "$RESULT" | python3 -c "
import json, sys, subprocess
raw = sys.stdin.read()
start = raw.find('{'); end = raw.rfind('}') + 1
if start == -1: sys.exit(0)
data = json.loads(raw[start:end])
for nl in data.get('new_labels', []):
    name, ac = nl.get('name',''), nl.get('account','')
    if name and ac:
        subprocess.run(['gog','gmail','labels','create', name,'--account', ac,'--force'], capture_output=True)
        print(f'    🏷 새 라벨: {name}')
processed = 0
for a in data.get('actions', []):
    tid, ac, label = a['id'], a['account'], a.get('label')
    if not label: continue
    cmd = ['gog','gmail','labels','modify', tid,'--add', label,'--account', ac,'--force']
    if a.get('archive'): cmd.extend(['--remove','INBOX'])
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode == 0: processed += 1
for u in data.get('urgent', []):
    print(f'    ⚠️  {u}')
print(f'    배치{sys.argv[1]}: {processed}/{len(data.get(\"actions\",[]))}건')
" "$BATCH" 2>/dev/null || echo "    배치$BATCH: 처리완료"

    PAGE_TOKEN=$(echo "$INBOX" | python3 -c "import json,sys; print(json.load(sys.stdin).get('nextPageToken',''))" 2>/dev/null || echo "")
    [ -z "$PAGE_TOKEN" ] && break

    BATCH=$((BATCH + 1))
    sleep 0.5
  done
done

echo ""
echo "✅ 전체 정리 완료"
