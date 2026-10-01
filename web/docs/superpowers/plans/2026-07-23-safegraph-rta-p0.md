# SafeGraph-RTA P0′ 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** v1 Boolean AND을 기준선으로 보존한 채, 대상 일치·신선도·순서/정지·시간 예산·비대칭 확인을 검사하는 SafeGraph-RTA 계층 + 결함주입 A/B 실험 + 자동 연구 산출물.

**Spec (구속력):** `docs/superpowers/specs/2026-07-23-safegraph-rta-p0-design.md` — 모든 인터페이스·enum·수치·문구는 스펙 §2 그대로. 원본 설계서 `docs/research/SafeGraph_RTA_원본설계서_0723.md`의 §6(입력 계약)·§8(검사 공식)·§9(상태기계)·§10(출력 계약)·§12(시나리오 표)·§14(로그 스키마)를 구현 참조로 읽을 것.

**Architecture:** `safety/`(순수 코어) → `experiments/`(trace·metrics) → `scripts/`(러너) → UI 확장. 기존 `core/`·기존 테스트 66개는 불가침.

## Global Constraints

- 작업 디렉토리 `/Users/daniellim/Desktop/ClipSense/Prototype`, 브랜치 `feat/safegraph-rta`
- 기존 66개 테스트 삭제·수정 금지 (`npm test`로 매 태스크 회귀 확인)
- 안전 코어(src/safety, src/experiments)는 브라우저 API·Date.now()·performance.now() 직접 호출 금지 — clock 주입
- proceed-like = baseline `CROSS`(확정) / proposed `SIGNAL_CONFIRMED` 뿐
- 임계값은 `src/safety/config.js` 단일 파일에만
- 문구 byte-exact (스펙 §2.2 MESSAGES, 원본 §9.4)
- 결과 수치 조작 금지 — 보고서 수치는 로그 산출값만, 미측정은 `TBD`
- 커밋 메시지 끝: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- 각 태스크: TDD (실패 테스트 → RED 확인 → 구현 → GREEN → 전체 suite → 커밋)

---

### Task S1: safety/config + reasonCodes + contracts

**Files:** Create `src/safety/config.js`, `src/safety/reasonCodes.js`, `src/safety/contracts.js`, Test `tests/safety/contracts.test.js`

**Produces (후속 태스크가 그대로 import):**
- `RTA_CONFIG_V1` (원본 §7 값 그대로, 11개 키)
- `REASONS` (17 코드), `REASON_PRIORITY` (스펙 §2.2 순서), `pickPrimaryReason(failedChecks)` — 목록에 없는 코드만 있으면 `INVALID_INPUT` 반환(fail-safe)
- `MESSAGES = { WAIT, VERIFYING, INFORMATION_ONLY }` 문자열 + `confirmedMessage(remainingSec) → '보행신호가 확인되었습니다. 잔여시간은 {정수}초입니다. 주변 차량에 주의하세요.'`
- `validateTargetContext / validateCitsObservation / validateVisionObservation / validateClock / validateConfig` — 각 `{ ok, errors: string[] }`, errors에 실패 필드명 포함

**필수 테스트 케이스:**
- 유효 표본 각 1건 ok
- TargetContext: 각 ID 누락/빈 문자열/공백만 → 불합격, bindingMethod 'MANUAL_DEMO' 외 → 불합격
- CitsObservation: color enum 위반, remainingSec NaN/Infinity/음수, sourceEpochMs 누락, seq 비정수, sourceMode enum 위반, `sourceMode:'LIVE'`인데 sourceEpochMs 없음 → 전부 불합격
- VisionObservation: score/quality 범위 밖(<0, >1, NaN), frameSeq 누락, roiBindingId 빈 문자열 → 불합격
- Clock: 둘 중 하나 NaN → 불합격
- pickPrimaryReason: `['TIME_SHORT','TARGET_MISMATCH']` → `TARGET_MISMATCH`; `['CITS_STALE','RED_SIGNAL']` → `RED_SIGNAL`; 빈 배열 → `INVALID_INPUT`
- validateConfig: 음수 임계값 → 불합격

- [ ] 실패 테스트 작성 → RED 확인 → 구현 → GREEN → `npm test` 전체 → 커밋 `feat(safety): 설정·reason 코드·입력 계약 검증`

---

### Task S2: safety/safeGraphChecks

**Files:** Create `src/safety/safeGraphChecks.js`, Test `tests/safety/safeGraphChecks.test.js`

**Consumes:** S1 전부. **Produces:** `evaluateChecks({ target, cits, vision, user, crosswalk, clock, config, history })` — 스펙 §2.4 시그니처·의미론 그대로. checks 14키 전부 반환하되 distinctFramesOk/holdTimeOk는 항상 false로 반환(shield가 병합). `requiredCrossingSec`는 기존 `src/core/crossingTime.js`의 `requiredCrossingSec` 재사용 (crosswalk.marginSec 전달).

**필수 테스트 케이스 (원본 §19.2):**
- 전 필드 일치 → targetMatch true; intersection/crosswalk/movement/direction/roiBinding 각각 단독 불일치 → false + failedChecks에 TARGET_MISMATCH
- freshness 경계: citsSourceAge 1999ms → citsFresh true / 2001ms → false(CITS_STALE); visionAge 499/501; receiveAge 1499/1501
- 미래 timestamp: age -200ms(tol 250 이내) → 통과 / -300ms → 실패
- seq 역전(101→100) → REPLAY_OR_REORDER; frameSeq 역전 동일
- freeze: lastFrameAdvanceMonoMs로부터 751ms → VIDEO_FROZEN
- dualGreen: red/unknown 조합별 → RED_SIGNAL(cits red) / SOURCE_MISMATCH(cits green×vision red) / VISION_UNCERTAIN(unknown·저score·저quality)
- 시간: remaining 35, sourceAge 200ms, budget 500ms → effective = 35-0.2-0.5=34.3 ≥ 18.67+1.5 → true; remaining 20 → 19.3 < 20.17 → false(TIME_SHORT)
- invalid 입력(계약 불합격) → inputValid false, failedChecks [INVALID_INPUT], 나머지 검사 시도 안 함
- 순수성: 같은 입력 2회 → 동일 출력, history 미변형

- [ ] TDD 사이클 → 커밋 `feat(safety): SafeGraph 즉시 검사 12종`

---

### Task S3: safety/runtimeShield (상태기계)

**Files:** Create `src/safety/runtimeShield.js`, Test `tests/safety/runtimeShield.test.js`

**Consumes:** S1, S2. **Produces:** `createRuntimeShield({ config })` → `{ update(input) → ShieldOutput, getState(), reset() }` — 스펙 §2.5 의미론 전부. 핵심 골격:

```js
update(input) {
  try {
    const targetKey = serializeTarget(input.target)          // 5필드 join
    const modeKey = `${input.cits?.sourceMode}|${input.vision?.sourceMode}`
    if (targetKey !== this.lastTargetKey || modeKey !== this.lastModeKey) this._resetAccumulation()
    const evald = evaluateChecks({ ...input, config, history: this.history })
    this._advanceHistory(input, evald)                       // seq/frameSeq/advance 시각 갱신
    const hardOk = HARD_CHECK_KEYS.every(k => evald.checks[k])
    if (!hardOk) { this._resetAccumulation(); return waitOrInfoOutput(evald) }
    this._countDistinctFrame(input.vision.frameSeq, input.clock.nowMonoMs)
    const confirmed = this.count >= config.minDistinctGreenFrames
      && input.clock.nowMonoMs - this.confirmingSince >= config.confirmHoldMs
    ...
  } catch { return INTERNAL_ERROR_WAIT }
}
```

- HARD_CHECK_KEYS = 12개 즉시 검사 (distinct/hold 제외)
- cits 미가용 경로: hardOk 실패 중 citsAvailable만 문제고 vision green+score+quality+fresh면 decision `INFORMATION_ONLY`(VISION_ONLY_INFORMATION), 그 외 WAIT
- CONFIRMING 중 decision은 `VERIFYING`, reason `CONFIRMING`
- SIGNAL_CONFIRMED 메시지에 `Math.floor(effectiveRemainingSec)` 삽입

**필수 테스트 (원본 §19.3 전체):**
- K-1 프레임에서는 미확정; K 충족+hold 미달 미확정; hold 충족+K 미달 미확정; 동시 충족 시 확정
- 같은 frameSeq 반복 tick으로 K 못 채움 (frameSeq 고정 100 tick → 영원히 VERIFYING… 단 freeze가 먼저 걸리므로 freezeTimeout 이내 반복으로 검증)
- target 변경 → 누적 초기화 + 그 update는 proceed-like 아님; sourceMode 변경 동일
- SIGNAL_CONFIRMED에서 red/stale/time-short/target 변경 각 1 tick → **같은 update에서** decision WAIT
- WAIT 후 재green → 누적 0부터
- update() 인자 없음/null/필드 결측 → WAIT INVALID_INPUT; 내부 예외 강제(잘못된 config 주입) → INTERNAL_ERROR
- cits unavailable + vision 완벽 → INFORMATION_ONLY, 절대 SIGNAL_CONFIRMED 아님 (P3)
- 출력 계약: checks 14키·ages·confirmation·configVersion 존재

- [ ] TDD 사이클 → 커밋 `feat(safety): 비대칭 RTA Shield 상태기계`

---

### Task S4: 불변식 전수 테스트 (P1~P7)

**Files:** Test `tests/safety/invariants.test.js` (구현 파일 없음 — 게이트 전용)

색상 {green,red,unknown} × available {t,f} × 신선도 {fresh,stale} × seq {ok,replay} × frame {advance,frozen,repeat} × 시간 {enough,short} × target {match,mismatch} 조합을 프로그램으로 순회(수백 조합)하며 shield를 fresh 인스턴스로 구동해 확인:

- P1/P2: SIGNAL_CONFIRMED ⇔ hard check 전부 true (역방향 포함)
- P3: available=false 조합 전체에서 SIGNAL_CONFIRMED 0건
- P4: 확정 상태에서 target 변경 주입 → 즉시 비-proceed
- P5: red/unknown/stale/replay/freeze/short 각 조합 → 그 update 비-proceed
- P6: frameSeq 고정 반복 → 확정 불가
- P7: 강제 예외 → WAIT

- [ ] 순회 테스트 작성 → 통과 확인 → `npm test` 전체 → 커밋 `test(safety): 안전 불변식 P1~P7 전수 검증`

---

### Task S5: baselineAdapter + faultScenarios

**Files:** Create `src/safety/baselineAdapter.js`, `src/experiments/faultScenarios.js`, Test `tests/safety/baselineAdapter.test.js`, `tests/experiments/faultScenarios.test.js`

**baselineAdapter (스펙 §2.6):** 매핑 정확히 — tier 산출, confidence=score, 기존 decide/stabilizer 무수정 재사용. 테스트: dual green 35초 → raw 즉시 CROSS·stabilized 1.5초 후 CROSS(proceedLike true); cits red → WAIT; wrong-target 입력이어도 (ID 필드가 decide에 전달되지 않으므로) CROSS 가능함을 **명시적으로 확인하는 테스트** (H1의 코드 증거).

**faultScenarios (스펙 §2.7):** 11종 buildTrace. 테스트: 각 시나리오 100 tick·스키마 유효(contracts 통과, NORMAL 기준)·groundTruth가 표와 일치(예: WRONG_TARGET 전 tick unsafe, TRUE_GREEN_TO_RED는 60번째 tick부터 unsafe)·결정론(2회 호출 동일)·faultScenarios의 cits/vision이 정상 시나리오에서 fresh하게 진행(sourceEpoch/seq/frameSeq 갱신 확인).

- [ ] TDD 사이클 → 커밋 `feat(exp): baseline 어댑터 + 결정론 결함주입 시나리오 11종`

---

### Task S6: traceRunner + metrics

**Files:** Create `src/experiments/traceRunner.js`, `src/experiments/metrics.js`, Test `tests/experiments/traceRunner.test.js`, `tests/experiments/metrics.test.js`

**traceRunner:** `runScenario(trace, { raw, stabilized, shield }, { measureLatency })` → 원본 §14 스키마 record 배열. 엔진 인스턴스는 시나리오마다 fresh 생성(호출측 책임 명시). latency 측정 함수는 주입(`measureLatency: fn => ms`) — 코어의 clock 금지 규칙 유지.

**metrics:** `summarize(recordsByScenario)` → 스펙 §2.8. 정의:
- UAER: PHYSICAL 시나리오 중 proceed-like ≥1 tick 발생 시나리오 수 / PHYSICAL 시나리오 수
- CVER: CONTRACT 동일 / CONTRACT 수
- DPR_tick: unsafe tick 중 proceed-like tick / 전체 unsafe tick
- SafeCoverage: NORMAL_GREEN의 "확인 가능 구간"(트레이스 시작+K·hold 이후) tick 중 proceed-like / 해당 tick 수
- confirmLatency: NORMAL_GREEN에서 조건 최초 성립(tick 0)→최초 proceed-like까지 ms
- timeToInhibit: TRUE_GREEN_TO_RED에서 fault 시작→최초 비-proceed까지 ms (같은 tick=0)
- evalLatency: 주입된 측정값의 median/p95/max

테스트: 손으로 만든 소형 record 배열로 각 지표 분자/분모 정확성 검증 (예: 2 PHYSICAL 중 1개에서 proceed → UAER {n:1,N:2}).

- [ ] TDD 사이클 → 커밋 `feat(exp): 트레이스 러너 + episode 지표`

---

### Task S7: 실험 스크립트 + artifacts + 보고서 생성

**Files:** Create `scripts/runFaultExperiments.mjs`, Modify `package.json` (`"experiment": "node scripts/runFaultExperiments.mjs"`), Create `artifacts/.gitkeep`

11 시나리오 × 3 엔진 전체 실행 → 스펙 §2.9 산출물 7종. 보고서는 원본 §22 목차·§22.4 표(구현 3개 엔진 행만 수치, 미구현 행 삭제하지 말고 `P1 미구현`)·§22.5 한계 문장 전문·주장 가능/불가 목록(원본 §4) 포함. manifest에 git HEAD·node -v·config hash. `performance.now()`는 이 스크립트에서만 사용해 latency 주입.

검증: `npm run experiment` 실행 → 7파일 생성 확인, jsonl 라인 수 = 11×100×?(record 구조 확인), csv 수치와 보고서 수치 일치 spot-check, **실측 결과 요약을 리포트에 기록** (H1 갈림 여부 — WRONG_TARGET/STALE/REORDER/FROZEN에서 baseline vs proposed).

- [ ] 구현 → 실행 → 산출물 검증 → `npm test`·`npm run build` 회귀 → 커밋 `feat(exp): 원커맨드 결함주입 실험 + 자동 연구 산출물`

---

### Task S8: UI v2 통합

**Files:** Create `src/ui/SourcePanel.jsx`, `src/ui/SafetyGatePanel.jsx`, `src/ui/ComparisonPanel.jsx`, Modify `src/App.jsx`, `src/App.css`, `src/ui/ScenarioBar.jsx`, `src/ui/CameraView.jsx`, `src/feedback/tts.js`(수정 없이 재사용 우선)

스펙 §2.10 전부:
- 배너 문구 교체 + MANUAL TARGET 배지
- CameraView: onVision 콜백에 `frameSeq`(단조 증가 카운터)·`capturedAtMonoMs`(performance.now())·`quality`(유효픽셀 비율×평균 밝기 정규화, 산식 주석) 추가 — 기존 반환 필드는 유지(회귀 보호)
- App: 시나리오 모드 = buildTrace 실시간 재생(100ms tick, MOCK 배지) / 카메라 모드 = 실캠 vision + MOCK cits(정상 green). safety tick 100ms에서 shield.update + baseline.update 동시 호출, 같은 tickInput
- generation token: 시나리오/모드 전환 시 증가, 이전 재생 타이머 정리, 이전 비동기 응답 폐기
- ComparisonPanel 좌/우 라벨·배지 문구 스펙 그대로
- TTS: `오디오 활성화` 토글 후 proposed decision 변화 시만 발화(MESSAGES), WAIT 전환 시 cancel, baseline 무음
- 검증(헤드리스): `npx vite build` 성공, `npm test` 전체 통과. 브라우저 수동 검증은 사람에게 deferred 명시

- [ ] 구현 → build/test → 커밋 `feat(ui): SafeGraph A/B 통합 화면 — 게이트·비교·결함주입`

---

### Task S9: 문서 v2 + 최종 검증

**Files:** Modify `README.md`, Create `docs/demo-checklist-v2.md`

- README: SafeGraph-RTA 섹션(한 문단), `npm run experiment` 안내, Vite proxy dev 전용 명시, 증거 등급 표(원본 방향 조언의 등급 체계)
- demo-checklist-v2: 원본 §23 3막 (1막 기존 방식 반례 → 2막 SafeGraph 차단 + 게이트 패널 → 3막 정상 확인 CONFIRMING→SIGNAL_CONFIRMED→red 주입 same-tick WAIT), 60~90초, 첫 장면 고지
- 최종: `npm test` + `npm run build` + `npm run experiment` 3종 실행·결과 기록, 체크리스트(원본 §26) 대조표 작성 → 커밋 `docs: SafeGraph 시연 체크리스트 v2 + 최종 검증`

---

## Self-Review 결과

- 스펙 커버리지: 스펙 §2.1~§2.10 → S1~S8, §3 정직성 → S7 보고서·S8 TTS 차단·S9 문서, §4 성공기준 → S4(불변식)·S7(artifacts·H1)·S9(3종 명령). 원본 §19 테스트 목록 → S1~S6에 분배, §19.6 비동기는 S3(순수 로직 레벨)+S8(generation token, 수동 검증 defer).
- 타입 일관성: evaluateChecks의 history 키 4종 = shield `_advanceHistory` 갱신 대상; proceedLike 정의 = traceRunner·metrics·UI 공통; MESSAGES는 S1 단일 정의를 S3·S8이 import.
- 미결 의존: C-ITS 실자료 도착 시 recordedCits fixture는 별도 후속(P1) — 본 계획 비차단.
