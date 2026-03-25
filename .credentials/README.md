# 인증 정보

이 폴더에는 Google Cloud API 인증 파일을 저장합니다.
**절대 git에 커밋하지 마세요.**

## 필요한 파일

### 1. credentials.json (필수)

Google Cloud Console에서 다운로드한 OAuth 2.0 클라이언트 ID 파일.

**생성 방법:**
1. [Google Cloud Console](https://console.cloud.google.com/) 접속
2. 프로젝트 선택 (또는 새 프로젝트 생성)
3. API 및 서비스 > 사용자 인증 정보
4. 사용자 인증 정보 만들기 > OAuth 클라이언트 ID
5. 애플리케이션 유형: 데스크톱 앱
6. JSON 다운로드 → 이 폴더에 `credentials.json`으로 저장

**필요한 API (사용 설정 필요):**
- Gmail API
- Google Calendar API

### 2. token_<account>.json (자동 생성)

계정별 OAuth 토큰. 최초 인증 시 자동 생성됩니다.

```bash
# 인증 명령
python3 lib/google_api.py auth --account your-email@gmail.com
```

생성되는 파일:

```text
token_your-email@gmail.com.json
```

토큰은 자동 갱신되므로 crontab 환경에서 재인증 불필요.

## 파일 구조

```
.credentials/
├── README.md              # 이 파일
├── credentials.json       # Google Cloud OAuth 클라이언트 (수동 배치)
├── token_<account>.json   # 계정별 토큰 (자동 생성)
└── .gitkeep
```
