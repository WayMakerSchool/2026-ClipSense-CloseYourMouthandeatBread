# ClipSense SafeGraph-RTA: 대상 일치와 데이터 신선도를 검증하는 다중센서 보행신호 Runtime Assurance

> ⚠️ 기술 검증용 시제품 보고서입니다. 실제 보행 판단이나 안전 보장에 사용할 수 없습니다.
> MANUAL TARGET BINDING — 예선 기술 검증에서는 횡단보도와 카메라 ROI를 수동 연결합니다.

- 생성 시각(ISO): 2026-07-23T09:56:53.882Z
- git HEAD: `0fd1937509af2c8377b7ba66e760dbb7c0e6eb1d`
- Node: `v22.17.0`
- configVersion: `safegraph-rta-demo-v1` / config sha256: `bdd92753baf06d57…`
- 원본 raw log: `artifacts/experiment_raw.jsonl` (1100줄 = 11 시나리오 × 100 tick)

---

## 초록

기존 ClipSense의 Boolean AND 판정은 C-ITS와 카메라 비전이 같은 색인지만 확인하며, 두 관측이 같은 횡단보도·같은 방향을 가리키는지, 아직 유효한 데이터인지, 재전송·정지된 입력은 아닌지를 검사하지 않는다. 이 연구는 대상 일치·데이터 신선도·순서/정지 검출·잔여시간 지연 예산을 검사하는 SafeGraph-Lite 즉시 검사와, 진행 방향은 느리게 승인하고 차단 방향은 즉시 반영하는 비대칭 Runtime Assurance Shield(SafeGraph-RTA)를 제안한다. 결정론적 결함주입 시나리오 11종(정상 1종 + 계약위반 6종 + 물리적위험 4종)을 Raw Boolean AND, Legacy AND+Stabilizer(주 기준선), Full SafeGraph-RTA 세 엔진에 동일 입력으로 재생해 비교했다. 실측 결과, Legacy 기준선의 계약위반 episode 진행률(CVER)은 5/6인 반면 Full SafeGraph-RTA는 0/6였고, 물리적위험 episode 진행률(UAER)은 1/4, 정상 조건에서의 Safe Coverage는 100.0%로 측정되었다(WRONG_TARGET_GREEN: 갈림(baseline proceed / proposed block), STALE_CITS_GREEN: 갈림(baseline proceed / proposed block), REORDERED_PACKET: 갈림(baseline proceed / proposed block), FROZEN_GREEN_VIDEO: 갈림(baseline proceed / proposed block)). 다만 두 소스가 동일 target·정상 timestamp로 장시간 동일한 거짓 초록을 제공하는 공통원인 오류(PERSISTENT_COMMON_CAUSE)는 본 Shield도 차단하지 못했으며, 이는 §22.5 한계에 명시한 잔존 위험이다. 본 실험은 통제된 소프트웨어 결함주입 환경의 결과이며 실제 도로 안전성을 보장하지 않는다.

---

## 본문

### 1. 문제 정의

기존 Boolean AND 방식(`C-ITS == GREEN AND Vision == GREEN AND score >= threshold AND remainingSec >= requiredCrossingSec`)은 두 센서가 "동의"했다는 사실만 확인하며, 그 둘이 같은 교차로·같은 횡단보도·같은 진행 방향을 가리키는지, 현재 패킷인지, 재생/정지된 입력이 아닌지, 판정 지연을 제외한 실제 잔여시간이 충분한지를 확인하지 않는다. 본 연구가 해결하려는 정확한 문제는 "잘못된 대상, 오래된 데이터 또는 정지된 관측이 우연히 모두 초록일 때 기존 Boolean AND가 진행 가능 상태를 내보낼 수 있는 문제"다.

### 2. 기존 방식과 위험 반례

Legacy AND+Stabilizer 기준선은 target ID·timestamp·sequence를 아예 입력으로 받지 않는다(`src/safety/baselineAdapter.js` — cits/vision 매핑에서 색상·잔여시간·score만 전달하고 ID·timestamp·seq는 버림). 이 구조적 한계 자체가 H1의 근거다.

### 3. 연구 질문과 가설

RQ1–RQ3, H1–H4는 원본설계서 §3을 그대로 채택한다. 본 보고서의 정량 결과 절(§12 상당)이 H1–H3를 검증하고, H4(ablation)는 P1로 보류되어 이번 실험 범위에 포함되지 않는다(TBD).

### 4. 시스템 적용 범위와 위협 모델

SafeGraph-Lite는 완전 자동 대상 인식이 아니라 수동 바인딩(MANUAL TARGET BINDING) 기반 검증 계층이다. 위협 모델은 "두 관측이 우연히 또는 결함으로 인해 잘못된 대상·오래된 데이터·정지된 입력을 초록으로 보고하는 경우"로 한정하며, 공통원인 오류(두 소스가 동일 target·정상 timestamp로 장시간 동일한 거짓 초록을 제공)는 위협 모델 밖의 잔존 위험으로 별도 취급한다(§12 결과 참조).

### 5. SafeGraph-Lite 대상 바인딩

`src/safety/safeGraphChecks.js`의 `targetMatch`는 intersectionId/crosswalkId/movementId/direction/roiBindingId 5필드 전체가 일치해야 통과한다(원본 §8.1).

### 6. 데이터 신선도·sequence 모델

citsSourceAgeMs/citsReceiveAgeMs/visionAgeMs 세 나이를 각각 config 임계값과 비교하고, seq/frameSeq 역행을 REPLAY_OR_REORDER로, frameSeq/mediaTimeMs 정체를 VIDEO_FROZEN으로 판정한다(원본 §8.2–8.3).

### 7. 잔여시간·지연 예산

`effectiveRemainingSec = cits.remainingSec - citsSourceAgeMs/1000 - latencyBudgetMs/1000`, `timeSufficient = effectiveRemainingSec >= requiredCrossingSec + confirmHoldMs/1000`(원본 §8.5). 현재 config: `latencyBudgetMs=500ms`(설계 예산, §11 실측 evalLatencyMs와 별도 필드).

### 8. 비대칭 RTA 상태기계

WAIT → CONFIRMING → SIGNAL_CONFIRMED. 진행 방향은 서로 다른 K(=5)개 프레임과 hold(=1500ms) 동시 충족이 필요하고, 위험 조건은 모든 상태에서 같은 update 내 즉시 WAIT로 반영된다(원본 §9).

### 9. 구현 환경과 소프트웨어 구조

- Node v22.17.0, 실행 시각 2026-07-23T09:56:53.882Z, git HEAD `0fd1937509af2c8377b7ba66e760dbb7c0e6eb1d`
- 안전 코어: `src/safety/`(config, contracts, reasonCodes, safeGraphChecks, runtimeShield, baselineAdapter)
- 실험 러너: `src/experiments/`(faultScenarios, traceRunner, metrics) + `scripts/runFaultExperiments.mjs`
- 3개 엔진: Raw Boolean AND(`createBaselineEngines().raw`), Legacy AND+Stabilizer(`createBaselineEngines().stabilized`), Full SafeGraph-RTA(`createRuntimeShield()`)
- Temporal Only, SafeGraph without Target Check, SafeGraph without Freshness Check 등 나머지 ablation 변형은 **P1 미구현**이다.

### 10. 결함주입 실험 설계

11개 결정론적 시나리오, 각 100 tick(TICK_MS=100ms, DURATION_MS=10000ms), `src/experiments/faultScenarios.js`의 `buildTrace()`로 생성한다. groundTruth(unsafe/faultActive/faultType)는 평가 알고리즘이 아니라 시나리오 정의에 고정되어 있다(원본 §12). 매 시나리오마다 3개 엔진 모두 **새 인스턴스**로 재생성해 상태 누수를 방지한다.

riskClass 구성: SAFE 1개(NORMAL_GREEN), PHYSICAL(UAER 분모) 4개(SINGLE_FALSE_GREEN, TIME_SHORT, TRUE_GREEN_TO_RED, PERSISTENT_COMMON_CAUSE), CONTRACT(CVER 분모) 6개(WRONG_TARGET_GREEN, STALE_CITS_GREEN, REORDERED_PACKET, FROZEN_GREEN_VIDEO, CAMERA_OCCLUDED, TARGET_SWITCH_MID_CONFIRM).

무작위 결함주입(seed 고정, correlated burst fault)은 **P1 미구현**이다.

### 11. 평가 지표

`artifacts/metric_definitions.md` 참조(UAER/CVER/DPR_tick/Safe Coverage/Confirmation Latency/Time-to-Inhibit/Evaluation Latency 정의 전문).

### 12. 정량 결과

전체 raw log: `artifacts/experiment_raw.jsonl`(1100줄). 요약: `artifacts/experiment_summary.csv`. 시나리오별 세부: `artifacts/scenario_results.csv`.

#### 12.1 엔진별 종합 지표

| Engine | UAER (n/N) | CVER (n/N) | Safe coverage (n/N) | Confirm latency (ms) | Inhibit latency (ms) |
|---|---:|---:|---:|---:|---:|
| Raw Boolean AND | 1/4 | 5/6 | 85/85 | 0.00 | 0.00 |
| Legacy AND + Stabilizer | 1/4 | 5/6 | 85/85 | 1500.00 | 0.00 |
| Full SafeGraph-RTA | 1/4 | 0/6 (단측 95% 상한 39.3%) | 85/85 | 1500.00 | 0.00 |
| Temporal Only | P1 미구현 | P1 미구현 | P1 미구현 | P1 미구현 | P1 미구현 |

- Confirm latency: NORMAL_GREEN 단일 episode 관측값(반복 실행 없음 — 신뢰구간 없음).
- Inhibit latency: TRUE_GREEN_TO_RED 단일 episode 관측값. 실측 결과 baseline(Raw)=0.00ms, baseline(Legacy+Stabilizer)=0.00ms, proposed(Full SafeGraph-RTA)=0.00ms — **세 엔진 모두 동일 tick에서 즉시 차단**되었다. Legacy+Stabilizer의 비대칭 설계(WAIT는 즉시 확정, CROSS만 hold)가 red 전환 자체를 같은 tick에서 반영하기 때문이며, proposed만 빠른 것이 아니다.

#### 12.2 결함(fault)별 결과

| Fault | Baseline (Legacy AND+Stabilizer) | SafeGraph-RTA | Blocking reason (실측) | Evidence |
|---|---|---|---|---|
| Wrong target green | 통과(proceed-like) 발생 (85/100 unsafe tick) | WAIT/차단 유지 (0/100 unsafe tick) | TARGET_MISMATCH | scenario_results.csv (scenarioId=WRONG_TARGET_GREEN, engine=Full SafeGraph-RTA) |
| Stale C-ITS green | 통과(proceed-like) 발생 (61/61 unsafe tick) | WAIT/차단 유지 (0/61 unsafe tick) | CITS_STALE | scenario_results.csv (scenarioId=STALE_CITS_GREEN, engine=Full SafeGraph-RTA) |
| Reordered packet | 통과(proceed-like) 발생 (80/80 unsafe tick) | WAIT/차단 유지 (0/80 unsafe tick) | REPLAY_OR_REORDER | scenario_results.csv (scenarioId=REORDERED_PACKET, engine=Full SafeGraph-RTA) |
| Frozen green video | 통과(proceed-like) 발생 (72/72 unsafe tick) | WAIT/차단 유지 (0/72 unsafe tick) | VISION_STALE [*] | scenario_results.csv (scenarioId=FROZEN_GREEN_VIDEO, engine=Full SafeGraph-RTA) |
| Single false green | 통과 없음 (0/100 unsafe tick) | WAIT/차단 유지 (0/100 unsafe tick) | RED_SIGNAL | scenario_results.csv (scenarioId=SINGLE_FALSE_GREEN, engine=Full SafeGraph-RTA) |
| Camera occluded | 통과 없음 (0/100 unsafe tick) | WAIT/차단 유지 (0/100 unsafe tick) | VISION_UNCERTAIN | scenario_results.csv (scenarioId=CAMERA_OCCLUDED, engine=Full SafeGraph-RTA) |
| Time short | 통과 없음 (0/100 unsafe tick) | WAIT/차단 유지 (0/100 unsafe tick) | TIME_SHORT | scenario_results.csv (scenarioId=TIME_SHORT, engine=Full SafeGraph-RTA) |
| Target switch mid-confirm | 통과(proceed-like) 발생 (70/70 unsafe tick) | WAIT/차단 유지 (0/70 unsafe tick) | TARGET_MISMATCH | scenario_results.csv (scenarioId=TARGET_SWITCH_MID_CONFIRM, engine=Full SafeGraph-RTA) |
| True green→red | 통과 없음 (0/40 unsafe tick) | WAIT/차단 유지 (0/40 unsafe tick) | RED_SIGNAL [†] | scenario_results.csv (scenarioId=TRUE_GREEN_TO_RED, engine=Full SafeGraph-RTA) |
| Persistent common cause | 통과(proceed-like) 발생 (85/100 unsafe tick) | 통과(proceed-like) 발생 (85/100 unsafe tick) | SAFEGRAPH_CONFIRMED [‡] | scenario_results.csv (scenarioId=PERSISTENT_COMMON_CAUSE, engine=Full SafeGraph-RTA) |

[*] **FROZEN_GREEN_VIDEO 실측 주의**: 사전 예상은 VIDEO_FROZEN이었으나, 실측 대표 reason은 **VISION_STALE**이다. frozen 시점(t=2000ms)부터 `capturedAtMonoMs`가 더 이상 갱신되지 않아 visionAgeMs가 `maxVisionAgeMs`(500ms)를 freezeTimeoutMs(750ms)보다 먼저 초과하고, `REASON_PRIORITY`(`src/safety/reasonCodes.js`)에서 VISION_STALE이 VIDEO_FROZEN보다 우선 순위가 높아 대표 reason으로 선택된다. `failedChecks`에는 videoAdvancing=false(VIDEO_FROZEN)도 함께 기록되며 로그에서 확인 가능하다 — 실제 원인(정지된 영상)은 손실되지 않는다.

[†] TRUE_GREEN_TO_RED는 §12.1 각주 참조 — baseline도 0ms 즉시 차단이다.

[‡] **PERSISTENT_COMMON_CAUSE 실측 주의**: proposed(Full SafeGraph-RTA)도 이 episode에서 통과(proceed-like)가 발생했다. 두 소스가 동일 target ID·정상 timestamp로 장시간 동일한 거짓 초록을 제공하는 공통원인 오류는 target/freshness 계약 검사로는 구분 불가능하다 — 원본설계서 §12가 예고한 잔존 위험이 실측으로도 재현되었다. 이는 실패를 숨기는 것이 아니라 정직성 원칙(원본 §4, §22.5)에 따라 명시적으로 보고하는 것이다.

### 13. baseline·ablation 분석

Raw Boolean AND와 Legacy AND+Stabilizer는 CONTRACT 시나리오 6종 중 다수에서 proceed-like를 출력했다(§12.2 표). 이는 baseline이 target ID/timestamp/seq를 입력 계약 자체에 포함하지 않기 때문이며(§2 참조), stabilizer가 시간축 안정화만 수행하고 대상 정체성 변화를 감지하지 못한다는 원본 §11.1의 문서화된 한계를 실측으로 재확인한다. Ablation(SafeGraph without Target Check 등)은 P1 미구현이므로 TBD.

### 14. 안전성–가용성 trade-off

Safe Coverage(§12.1 표)는 SafeGraph-RTA가 정상 조건에서도 K프레임+hold 확인을 요구하므로 baseline보다 낮게 측정될 것으로 예상되었다(H3). 그러나 실측에서는 측정 window 내 coverage 손실 없이(proposed 85/85, baseline 85/85 — 두 값이 동일) 확인 지연(confirmLatencyMs=1500.00ms)으로만 나타났다. 즉 tick 15(=confirmHoldMs 1500ms/TICK_MS 100ms) 이전 구간은 Safe Coverage 분모에서 애초에 제외되므로(§Safe Coverage 정의 참조), SafeGraph-RTA가 요구하는 K프레임+hold 확인은 coverage 자체를 깎는 대신 SIGNAL_CONFIRMED 도달 시점을 raw baseline 대비 1500.00ms만큼(raw=0.00ms) 늦추는 형태의 trade-off로 실측되었다. 가용성 손실이 "확인 지연"과 "coverage 손실" 중 지연 쪽으로만 나타난 것은 이 실험의 NORMAL_GREEN episode가 유지된 30초 내내 안정적으로 초록을 유지했기 때문이며, 신호가 tick 15 이후에도 자주 흔들리는 조건에서는 coverage 손실이 함께 나타날 수 있다(TBD, 추가 시나리오 필요).

### 15. 한계와 타당성 위협

§22.5(아래) 참조. 추가로: 각 시나리오는 반복 없는 단일 결정론적 episode이므로 신뢰구간을 계산하지 않았다(원본 §13.10). 0/N 결과에는 단측 95% 상한을 병기했다.

### 16. 윤리·안전 고지

이 시스템은 보행 판단을 대신하거나 안전을 인증하는 제품이 아니다. MOCK 데이터만 사용했으며 실제 C-ITS·실영상은 사용하지 않았다(run_manifest.json: sourceMode=MOCK 전부).

### 17. 재현 방법

```bash
cd /Users/daniellim/Desktop/ClipSense/Prototype
npm test
npm run build
npm run experiment
```

`npm run experiment`가 이 보고서와 `artifacts/` 전체를 재생성한다. config hash(`run_manifest.json`)와 git HEAD로 실행 환경을 고정 재현할 수 있다.

### 18. 본선 확장 계획

- 횡단보도–보행신호 후보의 지도·방향·영상 기반 graph association
- 실제 교차로/촬영 session 단위 데이터 분할
- 보정된 불확실성 및 selective prediction
- risk–coverage curve
- 다양한 조도·교차로에 대한 외적 타당성 검증
- 실제 목표 기기 end-to-end 지연·에너지 평가
- Temporal Only / SafeGraph without Target Check / SafeGraph without Freshness Check ablation, Wilson 95% CI, 무작위 결함주입(P1 전체)

### 19. 참고문헌

1. J. T. Slagel et al., *A Verification Framework for Runtime Assurance of Autonomous UAS*, NASA, 2024. https://ntrs.nasa.gov/citations/20240007986
2. E. Tabassi, *Artificial Intelligence Risk Management Framework (AI RMF 1.0)*, NIST AI 100-1, 2023. https://doi.org/10.6028/NIST.AI.100-1
3. R. El-Yaniv and Y. Wiener, *On the Foundations of Noise-free Selective Classification*, JMLR 11, 2010. https://jmlr.csail.mit.edu/papers/v11/el-yaniv10a.html
4. Y. Geifman and R. El-Yaniv, *Selective Classification for Deep Neural Networks*, 2017. https://arxiv.org/abs/1705.08500

참고 근거에서 가져올 핵심 개념: 신뢰하기 어려운 구성요소를 runtime monitor가 감시하고 안전 조건 위반 시 보수적 상태로 전환하는 RTA 구조; AI 위험을 평균 정확도가 아니라 위험·불확실성·테스트·문서화로 관리하는 관점; 불확실한 예측을 기권하고 coverage-risk trade-off를 측정하는 selective classification 관점. ClipSense가 위 기관의 인증·검증을 받았다는 뜻은 아니다.

---

## 22.5 한계 (원본설계서 §22.5 전문)

> 본 실험은 제한된 영상과 통제된 소프트웨어 결함주입 환경에서 판정 논리를 검증한 것이다. 실제 도로에서의 안전성, 사고 방지 또는 무사고를 보장하지 않는다. 예선 버전의 횡단보도–영상 ROI 연결은 수동 바인딩이며 자동 공간 인식 결과가 아니다. HSV score는 보정된 확률이 아니며, 무작위 결함주입 확률은 실제 결함 발생확률을 뜻하지 않는다. 두 소스가 같은 target·정상 timestamp를 가진 채 장시간 동일한 거짓 관측을 제공하는 공통원인 오류는 본 Shield를 통과할 수 있다.

---

## 주장 가능/불가 목록 (원본설계서 §4)

### 주장할 수 있는 것

- 정의된 소프트웨어 결함 시나리오에서 기존 기준선과 새 안전 계층을 비교했다.
- 대상 ID, timestamp, sequence, 잔여시간 불변식을 런타임에 검사한다.
- 불일치가 발생하면 같은 판정 주기에서 진행 가능 상태를 해제한다.
- 실험 로그와 테스트로 관찰된 결과를 재현할 수 있다.

### 주장하면 안 되는 것

- 실제 도로에서 안전을 보장한다.
- 사고를 원천 차단한다.
- 자동으로 올바른 횡단보도를 인식한다.
- MOCK C-ITS를 실제 경찰청 C-ITS라고 표현한다.
- HSV 색상 분석을 학습된 AI 모델이라고 표현한다.
- 합성·결함주입 실험 결과를 실도로 정확도라고 표현한다.
- 테스트 0건 실패를 사고 확률 0%라고 표현한다.
- RTA 구조를 사용했다는 이유로 안전 인증을 받았다고 표현한다.
