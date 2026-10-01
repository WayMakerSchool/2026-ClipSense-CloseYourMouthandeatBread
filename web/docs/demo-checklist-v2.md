# 시연 영상 촬영 체크리스트 v2 (SafeGraph-RTA, 3막, 목표 60~90초)

원본설계서 §23(시연 영상 구성)을 그대로 채택한다. v1 체크리스트(`docs/demo-checklist.md`, ClipSense
기본 이중검증 3막)와는 별개이며, 이 문서는 **SafeGraph-RTA 전용** 새 3막 구성이다.

## 사전 준비

- [ ] `npm run dev` 구동 (http://localhost:5173)
- [ ] 화면 녹화 시작 — 브라우저 탭 + 시스템 오디오 함께 캡처
- [ ] **오디오 활성화 버튼을 시연 시작 전에 미리 클릭** (`🔈 오디오 활성화` → `🔊 오디오 활성화됨`).
      브라우저 TTS는 사용자 제스처 없이 자동 재생되지 않으므로, 녹화 시작 후 첫 시나리오를
      누르기 전에 반드시 이 버튼을 눌러 둔다.
- [ ] 모드가 `시나리오 재생`인지 확인 (카메라 라이브 모드 아님)
- [ ] 화면 상단 안전 고지 배너와 `MANUAL TARGET BINDING` 배지가 항상 보이는 상태로 프레임 구성

---

## 1막 — 기존 방식의 반례 (약 20~30초)

목표: baseline(Legacy AND+Stabilizer)이 "두 신호가 모두 초록이면 통과"로 판단해, 실제로는
**잘못된 횡단보도**를 가리키는 상황에서도 CROSS(진행 가능)를 낼 수 있음을 보여준다.

- [ ] 화면 첫 장면에 안전 고지 배너("⚠️ 기술 검증용 시제품입니다. 실제 보행 판단이나 안전
      보장에 사용할 수 없습니다.")와 `MANUAL TARGET BINDING` 배지가 함께 보이는 상태에서 녹화 시작
- [ ] 시나리오 바에서 `인접 대상 오신호`(WRONG_TARGET_GREEN) 버튼 클릭
- [ ] 비교 패널(ComparisonPanel)에서 baseline(비교 전용 패널)과 proposed(실제 안내 연결
      패널)를 **같은 화면에 동시에** 노출
- [ ] baseline 쪽 판정이 `CROSS`(확정, proceed-like)로 표시되는 것을 확인 — 이 판정은
      화면 텍스트로만 표시되고 음성으로는 나오지 않음(v1 회귀 보증)
- [ ] proposed 쪽 판정이 `WAIT` + 사유 `TARGET_MISMATCH`로 즉시 갈리는 것을 확인
- [ ] 화면에 **"잘못된 횡단보도"** 문구를 자막/나레이션으로 명시

> 나레이션 예시: "두 센서가 모두 초록이라도, 서로 다른 횡단보도를 가리키면 기존 방식은
> 통과 판정을 낼 수 있습니다. 이것이 잘못된 횡단보도입니다."

---

## 2막 — SafeGraph-RTA 차단 (약 15~25초)

목표: 게이트 패널이 무엇을 근거로 차단했는지 짧게 두 시나리오로 보여준다.

- [ ] 시나리오 바에서 `오래된 C-ITS 초록`(STALE_CITS_GREEN) 버튼 클릭
- [ ] 안전 게이트 패널(14 checks)에서 `C-ITS Freshness` 항목이 ⛔ BLOCK으로 표시되고,
      `failedChecks (reason codes)` 목록에 `CITS_STALE`이 뜨는 것을 화면에 노출
- [ ] proposed 판정이 즉시 `WAIT`로 전환되는 것을 확인
- [ ] 이어서 `정지된 초록 영상`(FROZEN_GREEN_VIDEO) 버튼 클릭 — 짧게(3~5초)만 재현
- [ ] 게이트 패널에서 실제로 BLOCK 표시되는 항목을 그대로 노출
      **★ 나레이션 주의**: 사전 예상 사유는 `VIDEO_FROZEN`이었으나, 실측 대표 reason은
      **`VISION_STALE`**이다 (`REASON_PRIORITY`에서 VISION_STALE이 VIDEO_FROZEN보다 우선순위가
      높아 대표로 선택됨 — `videoAdvancing=false`(VIDEO_FROZEN)도 failedChecks에는 함께
      기록되지만 화면 대표 사유는 VISION_STALE). 나레이션에서 "정지된 영상"이라고 말하되,
      화면에 뜨는 정확한 reason 코드가 VISION_STALE임을 자막으로 병기한다.

> 나레이션 예시: "오래된 C-ITS 신호도, 멈춘 영상도 SafeGraph-RTA는 같은 판정 주기 안에서
> 즉시 차단합니다. 게이트 패널에 어떤 검사가 막았는지 그대로 나옵니다."

---

## 3막 — 정상 확인과 즉시 해제 (약 20~30초)

목표: 진행 가능 상태는 느리게(K프레임+hold) 승인하지만, 위험 신호가 들어오면 같은 tick에서
즉시 해제됨을 보여준다.

- [ ] 시나리오 바에서 `정상 이중 초록`(NORMAL_GREEN) 버튼 클릭 — 올바른 target, fresh dual
      green, 잔여시간 30초 이상 확보된 상태로 시작
- [ ] proposed 판정이 `WAIT` → `CONFIRMING`(화면 표시 문구는 `VERIFYING`: "보행신호를
      확인하고 있습니다. 대기하세요.")으로 전환되는 것을 확인
- [ ] tick 15(confirmHoldMs 1500ms 경과 시점)에서 `SIGNAL_CONFIRMED`로 전환되고, TTS로
      "보행신호가 확인되었습니다. 잔여시간은 N초입니다. 주변 차량에 주의하세요."가 재생되는
      것을 확인 (사전에 오디오 활성화를 눌러 두었는지 재확인)
- [ ] 이 상태에서 `초록에서 빨강 전환`(TRUE_GREEN_TO_RED) 버튼 클릭
- [ ] **같은 tick에서** 판정이 즉시 `WAIT`로 전환되는 것을 확인 (측정값: Time-to-Inhibit
      0ms — baseline도 이 시나리오는 0ms 즉시 차단이므로 비교 포인트는 "진행 승인은 느리고
      차단은 둘 다 즉시"임을 명확히 함)

> 나레이션 예시: "진행 가능 상태는 15틱, 1.5초에 걸쳐 천천히 확인합니다. 하지만 위험 신호가
> 들어오면 같은 판정 주기 안에서 즉시 해제합니다."

---

## §26 최종 실행 체크리스트 대조표

원본설계서 §26 항목 중 이 프로토타입에서 자동/코드로 검증 가능한 항목만 발췌해 현재 상태를 표기한다.
전체 21개 항목 전문은 `docs/research/SafeGraph_RTA_원본설계서_0723.md` §26 참조.

| §26 항목 | 현재 상태 | 근거 |
|---|---|---|
| 기존 baseline `decide()`가 비교용으로 남아 있다 | ✓ | `src/safety/baselineAdapter.js`, v1 테스트 66개 무수정 유지 |
| proposed 결과만 TTS·햅틱에 연결된다 | ✓ | `src/App.jsx` — announcer/vibrate는 `shieldOut`(proposed)에만 연결 |
| baseline의 "지금 건너셔도 됩니다"가 음성으로 나오지 않는다 | ✓ | ComparisonPanel baseline 패널에 `comparison-badge`("비교 전용, 음성 출력 안 함") 명시, TTS 미연결 |
| target ID가 없으면 SIGNAL_CONFIRMED가 불가능하다 | ✓ | `targetBound`/`targetMatch` check가 REASON_PRIORITY 상위, P1~P7 불변식 테스트로 검증 |
| timestamp가 없으면 SIGNAL_CONFIRMED가 불가능하다 | ✓ | `citsFresh`/`visionFresh` check, `inputValid` 계약 |
| 같은 frameSeq 반복으로 확인 수를 채울 수 없다 | ✓ | `distinctFramesOk` check (14개 중 하나) |
| red/unknown/stale/mismatch/freeze/time-short는 같은 update에서 WAIT다 | ✓ | 11개 결함주입 시나리오 실측 — 본 문서 2막/3막 |
| LIVE/RECORDED/MOCK/MANUAL TARGET 배지가 항상 보인다 | ✓ | `SourcePanel`(CAMERA/MOCK, MOCK 배지), `App.jsx` `badge-manual-target` |
| Vite proxy를 배포 환경 기능이라고 주장하지 않는다 | ✓ | README §"Vite proxy는 dev 전용" 명시 |
| JSONL 원본 로그가 있다 / CSV 요약이 원본 로그에서 자동 생성된다 | ✓ | `artifacts/experiment_raw.jsonl`, `experiment_summary.csv`, `scenario_results.csv` |
| 결과 수치의 분자와 분모가 보고서에 있다 | ✓ | `실험보고서_SafeGraph_RTA.md` 표(n/N 형식), CVER 5/6·UAER 1/4 등 |
| 결과가 없는 칸은 TBD다 | ✓ | H4(ablation) 등 미구현 항목은 보고서에 TBD로 명시 |
| 테스트와 빌드가 모두 통과한다 | ✓ (본 태스크 검증 결과, 아래 참조) | `npm test`, `npm run build` |
| 한계 문장이 보고서에 포함된다 | ✓ | 보고서 §22.5 원문 그대로 포함 |
| 실제 시연 브라우저에서 10회 연속 실행한다 | 수동 검증 필요 (자동 검증 범위 아님) | 시연 전 별도 확인 필요 |
| TTS 사용자 제스처와 진동 fallback이 있다 | ✓ (제스처) / 진동은 브라우저 지원 시에만 | 오디오 활성화 버튼 = 사용자 제스처, `feedback/haptic.js` fallback |

---

## 참고

- v1(ClipSense 기본 이중검증) 3막 체크리스트: `docs/demo-checklist.md`
- 이 문서는 SafeGraph-RTA A/B 비교 시연 전용이며, 두 체크리스트는 서로 다른 목적의 별개 녹화다.
