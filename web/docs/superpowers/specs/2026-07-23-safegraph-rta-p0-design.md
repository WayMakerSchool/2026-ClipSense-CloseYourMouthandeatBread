# SafeGraph-RTA P0′ 확정 스펙 (조정안)

- 날짜: 2026-07-23
- 기반 문서: `docs/research/SafeGraph_RTA_원본설계서_0723.md` (ChatGPT 작성 통합설계서)
- 본 문서는 원본 설계서에 대한 **구속력 있는 조정·확정 사항**만 기록한다. 여기 없는 내용은 원본 설계서를 따른다.
- 브랜치: `feat/safegraph-rta` (main의 v1은 항상 제출 가능 상태로 보존)

## 1. 스코프 조정 (사용자 승인 완료)

**P0′ 채택:**
- `src/safety/` 순수 코어: contracts + safeGraphChecks + runtimeShield + 불변식 P1~P7
- 결정론 시나리오 11종 (원본 §12 표 전체, PERSISTENT_COMMON_CAUSE 포함)
- 엔진 비교 3종: **Raw Boolean AND / Legacy AND+Stabilizer(주 기준선) / Full SafeGraph-RTA**
  (Raw는 adapter에서 공짜로 나오므로 포함. 그 외 5종 변형은 P1)
- `npm run experiment` → JSONL/CSV/manifest/보고서 자동 생성
- UI: 기존 화면 확장 (SourcePanel·SafetyGatePanel·ComparisonPanel·ScenarioBar v2), poll/tick 분리
- baseline 음성 차단, proposed만 TTS/햅틱

**P1로 보류:** 무작위 결함주입, ablation, Wilson CI, 녹화영상 업로드, 모바일 레이아웃

**원본 기준상태(§2.1) 정정:** v1은 셸이 아니라 완성 상태다 (통합 UI, TTS/햅틱, C-ITS 클라이언트, 66 테스트, 빌드 통과, main 머지 완료). C-ITS 키는 발급·호출 성공 상태 (자료 수령 대기).

## 2. 확정 인터페이스

### 2.1 src/safety/config.js
원본 §7의 `RTA_CONFIG_V1` 그대로. 단일 파일에만 존재.

### 2.2 src/safety/reasonCodes.js
- `REASONS`: 원본 §10의 17개 코드 enum (값 = 동명 문자열)
- `REASON_PRIORITY`: `INVALID_INPUT → TARGET_UNBOUND → TARGET_MISMATCH → RED_SIGNAL → CITS_MISSING → CITS_STALE → VISION_STALE → REPLAY_OR_REORDER → VIDEO_FROZEN → VISION_UNCERTAIN → SOURCE_MISMATCH → TIME_SHORT → CONFIRMING`
- `pickPrimaryReason(failedChecks[]) → REASON`
- `MESSAGES`: 원본 §9.4 문구 4종 (SIGNAL_CONFIRMED는 잔여초 삽입 함수)

### 2.3 src/safety/contracts.js
`validateTargetContext / validateCitsObservation / validateVisionObservation / validateClock / validateConfig` — 각각 `{ ok, errors: string[] }`. 빈 문자열·잘못된 enum·NaN·Infinity·음수 시간·누락 timestamp 전부 불합격. LIVE인데 sourceEpochMs 없음 → 불합격.

### 2.4 src/safety/safeGraphChecks.js
```js
evaluateChecks({ target, cits, vision, user, crosswalk, clock, config, history })
→ { checks, failedChecks, ages, effectiveRemainingSec, requiredCrossingSec }
```
- **순수 함수** — history(`{ lastCitsSeq, lastFrameSeq, lastFrameAdvanceMonoMs, lastMediaTimeMs }`)는 읽기 전용, 갱신은 shield 소유
- 즉시 검사 12종만 담당: inputValid, targetBound, targetMatch, citsAvailable, citsFresh, visionFresh, sequenceValid, videoAdvancing, dualGreen, visionScoreOk, visionQualityOk, timeSufficient
- `distinctFramesOk`/`holdTimeOk`는 shield가 확인 상태로부터 병합 (checks 객체 14키는 출력 계약 §10 그대로 유지)
- sequenceValid 실패 조건: `cits.seq < history.lastCitsSeq` 또는 `vision.frameSeq < history.lastFrameSeq` (REPLAY_OR_REORDER). 동일 seq는 실패가 아니라 "새 데이터 아님" — freshness가 시간 경과로 잡는다
- videoAdvancing: `nowMonoMs - history.lastFrameAdvanceMonoMs <= freezeTimeoutMs`
- 시간 계산은 원본 §8.5 공식 그대로 (confirmHold 포함)
- 음수 age는 `futureClockToleranceMs` 초과 시 실패

### 2.5 src/safety/runtimeShield.js
```js
createRuntimeShield({ config = RTA_CONFIG_V1 } = {})
→ { update(input) → ShieldOutput, getState(), reset() }
```
- ShieldOutput = 원본 §10 계약 전체 (decision, state, reason, message, checks, ages, effectiveRemainingSec, requiredCrossingSec, confirmation, configVersion, failedChecks)
- 상태: WAIT → CONFIRMING → SIGNAL_CONFIRMED. 위험 입력은 same-update WAIT
- **결정 의미 확정 (원본 §9.2 표와 §9.4 enum의 조화):** state CONFIRMING의 외부 decision은 `'VERIFYING'`이다. proceed-like는 오직 `SIGNAL_CONFIRMED`. 불변식 P4·P5의 "WAIT"는 "proceed-like가 아님 + 확인 누적 초기화"를 뜻한다
- distinct frame 카운트: 모든 hard check 통과 tick에서 `frameSeq > lastCountedFrameSeq`일 때만 +1. K(`minDistinctGreenFrames`) 충족 AND `confirmHoldMs` 경과 동시 충족 시 SIGNAL_CONFIRMED
- target key(5필드 직렬화) 또는 sourceMode 변경 → history·confirmation 즉시 초기화
- cits 미가용 시: vision green·score/quality 통과면 `INFORMATION_ONLY`(reason VISION_ONLY_INFORMATION), 아니면 WAIT — **CONFIRMING 진입 불가** (P3)
- 예외 → catch → WAIT, INTERNAL_ERROR
- Date.now()/performance.now() 직접 호출 금지 — clock은 인자

### 2.6 src/safety/baselineAdapter.js
```js
createBaselineEngines() → { raw, stabilized }   // 각 { update(tickInput, nowMonoMs) → { verdict, reason, proceedLike } }
```
- 매핑: `tier = cits?.available === true ? 1 : 2`, `vision.confidence = vision.score`, cits는 {color, remainingSec, available}만 전달
- stabilized = decide() + 기존 createStabilizer() (target 변경 무지 등 한계는 **수정하지 않고 보존** — 원본 §11.1)
- proceedLike = 확정 verdict === 'CROSS'

### 2.7 src/experiments/faultScenarios.js
- `TICK_MS = 100`, `DURATION_MS = 10000` (시나리오당 100 tick), base epoch `1784780000000`
- `SCENARIO_IDS` 11종 = 원본 §12 표 전체. 각 정의에 `riskClass: 'SAFE' | 'PHYSICAL' | 'CONTRACT'` 명시:
  - SAFE: NORMAL_GREEN
  - PHYSICAL(UAER 분모): SINGLE_FALSE_GREEN, TIME_SHORT, TRUE_GREEN_TO_RED, PERSISTENT_COMMON_CAUSE
  - CONTRACT(CVER 분모): WRONG_TARGET_GREEN, STALE_CITS_GREEN, REORDERED_PACKET, FROZEN_GREEN_VIDEO, CAMERA_OCCLUDED, TARGET_SWITCH_MID_CONFIRM
- `buildTrace(scenarioId) → { scenarioId, riskClass, ticks: [{ tickIndex, clock, target, cits, vision, user, crosswalk, groundTruth: { unsafe, faultActive, faultType } }] }`
- 정상 기저값: cits green 잔여 35초 카운트다운, seq 500ms마다 +1, sourceEpochMs=now-200, receivedAtMonoMs=now-100; vision green score .9 quality .8, frameSeq 매 tick +1, capturedAtMonoMs=now-50; sourceMode 전부 'MOCK'
- ground truth는 시나리오 정의에 고정 (평가 알고리즘이 만들지 않음)
- **UI의 결함주입 버튼도 이 buildTrace를 재생한다** — 실험과 시연이 동일 데이터 (단일 진실 원천)

### 2.8 src/experiments/traceRunner.js + metrics.js
- `runScenario(trace, engines)` → tick별 record (원본 §14 스키마, latencyMs 포함)
- `summarize(records)` → 엔진별 UAER/CVER/DPR_tick/SafeCoverage `{n, N}` + confirmLatency·timeToInhibit·evalLatency `{median, p95, max}`
- episode = 시나리오 1회. 모든 비율은 분자/분모 보존

### 2.9 scripts/runFaultExperiments.mjs
- Node ESM, `npm run experiment`
- 산출: `artifacts/experiment_raw.jsonl`, `experiment_summary.csv`, `scenario_results.csv`, `experiment_config.json`, `run_manifest.json`, `metric_definitions.md`, `실험보고서_SafeGraph_RTA.md`
- 보고서 수치는 전부 metrics 결과에서 주입. 측정 전 항목은 TBD. NaN/Infinity는 null+사유로 직렬화
- manifest: git HEAD, node 버전, 실행시각, config+해시, 시나리오 목록

### 2.10 UI v2 (기존 화면 확장)
- 상단 고지 문구 교체: `⚠️ 기술 검증용 시제품입니다. 실제 보행 판단이나 안전 보장에 사용할 수 없습니다.` + `MANUAL TARGET BINDING` 배지
- SourcePanel: 영상/C-ITS 소스 배지(CAMERA·RECORDED·MOCK / LIVE·RECORDED·MOCK), target 4필드, C-ITS 색·잔여·age·seq, Vision 색·score·quality·frameSeq
- SafetyGatePanel: 14 check PASS/BLOCK (아이콘+텍스트, 색상 단독 금지)
- ComparisonPanel: 좌 `기존 Boolean AND — 비교 전용, 음성 출력 안 함` / 우 `SafeGraph-RTA — 실제 안내 연결`
- ScenarioBar v2: 11 시나리오 버튼 (buildTrace 재생) + 카메라 라이브 모드
- 루프 분리: safety tick `100ms` 고정, C-ITS poll 비동기 독립, generation token으로 늦은 응답 폐기
- TTS: `오디오 활성화` 버튼(사용자 제스처) 후에만, proposed 상태 변화 시만 발화, WAIT 전환 시 cancel. baseline 발화 금지
- CameraView 확장: `frameSeq`(단조 카운터)·`capturedAtMonoMs` 발급. quality 산식: ROI 유효픽셀 비율 × 평균 밝기 정규화 (구현 파일에 산식 주석 문서화)

## 3. 정직성 규칙 (원본 §4 전문 채택 + 추가)

- v1의 "지금 건너셔도 됩니다"는 baseline 패널 텍스트로만 존재, 음성 금지
- 기존 v1 테스트 66개는 삭제·수정 금지 (baseline 회귀 보증). NORMAL_GREEN mock 등 v1 파일은 그대로 두고 실험은 신규 모듈 사용
- 보고서 한계 문장(원본 §22.5) 전문 포함
- Vite proxy는 dev 전용임을 README에 명시

## 4. 성공 기준

1. `npm test` (기존 66 + 신규 전부) / `npm run build` / `npm run experiment` 3종 통과
2. 불변식 P1~P7 테스트 통과
3. UI에서 11개 시나리오 원클릭 재생, baseline/proposed 동시 반응
4. artifacts 7종 자동 생성, 보고서 수치가 로그에서 추적 가능
5. WRONG_TARGET·STALE·REORDER·FROZEN에서 baseline proceed-like vs proposed WAIT가 실측으로 갈릴 것 (H1 검증)
6. 7/25 오전 시연영상 녹화 가능 상태
