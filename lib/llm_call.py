#!/usr/bin/env python3
# Ollama REST API 호출 래퍼
# 사용법: python3 llm_call.py <prompt_file>
# 환경변수:
#   LLM_MODEL    - 사용할 모델 (기본값: gpt-oss:20b)
#   LLM_BASE_URL - Ollama 서버 URL (기본값: http://localhost:11434)

import json
import os
import sys
import urllib.request
import urllib.error

def main():
    if len(sys.argv) < 2:
        print("사용법: llm_call.py <prompt_file>", file=sys.stderr)
        sys.exit(1)

    model = os.environ.get("LLM_MODEL", "gpt-oss:20b")
    base_url = os.environ.get("LLM_BASE_URL", "http://localhost:11434")

    prompt_file = sys.argv[1]
    try:
        with open(prompt_file, encoding="utf-8") as f:
            prompt = f.read()
    except OSError as e:
        print(f"프롬프트 파일 읽기 오류: {e}", file=sys.stderr)
        sys.exit(1)

    payload = json.dumps({
        "model": model,
        "prompt": prompt,
        "stream": False,
        "options": {"temperature": 0.1}
    }).encode("utf-8")

    req = urllib.request.Request(
        f"{base_url}/api/generate",
        data=payload,
        headers={"Content-Type": "application/json"}
    )

    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            result = json.load(resp)
            print(result["response"], end="")
    except urllib.error.URLError as e:
        print(f"Ollama 연결 오류: {e}", file=sys.stderr)
        sys.exit(1)
    except (KeyError, json.JSONDecodeError) as e:
        print(f"Ollama 응답 파싱 오류: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
