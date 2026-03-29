# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/ko/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- 사용자 확인 필요 메일에 "확인필요" Gmail 라벨 자동 부착 (classifier)

### Changed

- Phase 1을 LLM → 프로그래밍 방식 메모리 패턴 매칭으로 교체 (classifier, watcher)
- 발신자 매칭: 도메인/이메일 정확 일치, 서브도메인 지원 (classifier)
- 키워드 매칭: confidence 0.8+, 3글자 이상만 적용 (classifier)
- Ollama keep_alive=-1 설정, num_ctx 고정 할당 제거 (llm_call)
- Claude CLI 직접 호출을 Ollama REST API 기반 `llm_call()`로 교체 (llm, classifier, watcher, consolidator)

### Fixed

- macOS mktemp 버그: `.txt` 접미사로 인해 LLM 호출이 즉시 실패하던 문제 수정 (common.sh)
- Phase 1 LLM 실패 시 전체 스레드가 분류 없이 `_processed` 처리되던 버그 수정 (watcher)
