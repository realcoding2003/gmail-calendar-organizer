# 시스템 아키텍처

## 개요

Mac Mini에서 crontab으로 구동하는 이메일 자동 분류 + 캘린더 일정 등록 시스템.
Google API 직접 호출 + Claude Code CLI 기반.

## 전체 구성도

```mermaid
graph TB
    subgraph "Mac Mini — 이 프로젝트"
        subgraph "Cron"
            W[email-watcher.sh<br/>5분마다]
            MC[memory-consolidator.sh<br/>매일 03시]
        end

        subgraph "외부 호출"
            FP[feedback-processor.sh<br/>알림 봇이 호출]
        end

        subgraph "Claude Code CLI"
            S1[Sonnet — Phase 1 사전 분류]
            S2[Sonnet — Phase 2 상세 분류]
            O1[Opus — 메모리 통합]
        end

        subgraph "Google API"
            GM[Gmail API]
            GC[Calendar API]
        end

        subgraph "데이터"
            Q[data/queue/<br/>1건 = 1 JSON 파일]
            MEM[data/memory/<br/>sender-patterns<br/>classification-rules<br/>user-corrections]
            LOG[logs/]
        end

        W --> S1 & S2
        W --> GM
        W -->|미결정| Q
        W -->|처리 로그| LOG
        S1 & S2 -.->|메모리 참조| MEM

        FP --> GM & GC
        FP -->|학습| MEM
        FP -->|처리 후 삭제| Q

        MC --> O1
        O1 -->|최적화| MEM
    end

    subgraph "별도 프로젝트 — 알림 봇"
        BOT[알림 봇]
    end

    subgraph "외부"
        KT[카카오톡]
        USER[사용자]
    end

    Q -.->|큐 파일 읽기| BOT
    BOT -->|질문 전송| KT --> USER
    USER -->|답변| KT --> BOT
    BOT -->|feedback-processor.sh 호출| FP
```

## 메일 분류 흐름

```mermaid
sequenceDiagram
    participant Cron
    participant Watcher as email-watcher.sh
    participant Gmail as Gmail API
    participant Claude as Claude CLI (Sonnet)
    participant Queue as data/queue/
    participant Memory as data/memory/

    Cron->>Watcher: 5분마다 실행
    Watcher->>Gmail: 미처리 스레드 20개 조회 (batch API)
    Gmail-->>Watcher: 스레드 목록

    Note over Watcher: Phase 1: 제목+발신자만
    Watcher->>Memory: 메모리 컨텍스트 로드
    Watcher->>Claude: 20건 일괄 분류 요청
    Claude-->>Watcher: fast / need_body 분류

    loop fast 항목
        Watcher->>Gmail: 라벨 + 보관 + _processed
    end

    Note over Watcher: Phase 2: 본문 포함
    loop need_body 항목
        Watcher->>Gmail: 스레드 상세 조회
        Watcher->>Claude: 개별 분류 요청
        alt 자동 분류
            Watcher->>Gmail: 라벨 + 보관 + _processed
        else 미결정
            Watcher->>Queue: 큐 파일 생성
        else 일정 감지
            Watcher->>Queue: 캘린더 큐 파일 생성
        end
    end
```

## 피드백 처리 흐름

```mermaid
sequenceDiagram
    participant Bot as 알림 봇
    participant Queue as data/queue/
    participant FP as feedback-processor.sh
    participant Gmail as Gmail API
    participant Cal as Calendar API
    participant Memory as data/memory/

    Bot->>Queue: 큐 파일 읽기 (decision: null)
    Bot->>Bot: Claude CLI로 질문 생성
    Bot-->>Bot: 카카오톡 → 사용자 → 답변 수신
    Bot->>Bot: Claude CLI로 답변 해석

    Bot->>FP: 호출 (파일경로, decision, label)

    alt approve / modify
        FP->>Gmail: 라벨 적용 + 보관 + _processed
        FP->>Memory: sender-patterns 학습
        FP->>Memory: user-corrections 기록
    else approve (캘린더)
        FP->>Cal: 일정 등록
    else reject
        FP->>Gmail: 휴지통으로 이동
    end

    FP->>Queue: 큐 파일 삭제
```

## 메모리 학습 구조

```mermaid
graph LR
    subgraph "입력"
        A[사용자 피드백]
        B[AI 분류 결과]
    end

    subgraph "메모리"
        SP[sender-patterns.json<br/>발신자 → 라벨]
        CR[classification-rules.json<br/>키워드 → 라벨]
        UC[user-corrections.jsonl<br/>수정 이력]
    end

    subgraph "활용"
        P1[Phase 1 프롬프트<br/>패턴 매칭 우선]
        P2[Phase 2 프롬프트<br/>상세 분류 참고]
    end

    A -->|피드백 처리 시| SP & CR & UC
    B -->|memory_updates| SP & CR
    SP & CR & UC -->|load_memory_context| P1 & P2

    subgraph "일간 통합"
        MC[memory-consolidator<br/>Claude Opus]
    end

    SP & CR & UC -->|분석| MC
    MC -->|최적화| SP & CR
```

## 스레드 단위 처리

- Gmail API `threads().list()`로 스레드 검색 (batch API로 메타데이터 일괄 조회)
- 스레드의 모든 메시지(보낸/받은)를 한 번에 그룹핑
- `_processed` 라벨은 스레드 단위 적용 → 중복 처리 방지 (멱등)
- Phase 2에서 스레드 전체 대화를 Claude에 전달 → 답장 내용까지 분석

## 큐 시스템 설계

파일 기반 메시지 큐. DB/API 불필요.

```
data/queue/
├── classifications/    분류 미결정 (pending-{id}.json)
├── calendars/          캘린더 미결정 (cal-{id}.json)
└── labels/             라벨 제안 (label-{name}.json)
```

- **1건 = 1 JSON 파일** → 동시 접근 충돌 없음
- **watcher**: 새 파일 생성만 (write)
- **알림 봇**: 파일 읽기만 (read)
- **feedback-processor**: 처리 후 삭제 (read → execute → delete)
- 파일 존재 = 미처리, 파일 없음 = 처리 완료

## 성능 최적화

| 병목 | 해결 |
| --- | --- |
| 스레드 검색 N+1 | Gmail batch API로 1회 호출 |
| 라벨 적용 건별 subprocess | Google API 클라이언트 1회 초기화 |
| Phase 2 과다 호출 | Phase 1에서 메모리 기반 fast 처리 비율 높임 |
| 메모리 무한 증가 | 매일 Opus 통합으로 정리 |
