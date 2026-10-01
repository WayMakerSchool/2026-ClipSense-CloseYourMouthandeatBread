# ClipSense SafeGraph-Lite + RTA Shield 통합개발·연구설계서

> 작성일: 2026-07-23  
> 대상: Claude Code  
> 작업 저장소: `/Users/daniellim/Desktop/ClipSense/Prototype`  
> 목적: 제8회 한국코드페어 SW공모전 2차 예선용 통합 시제품, 결함주입 실험, 재현 가능한 연구보고서 완성  
> 마감: 2026-07-26 23:59  
> 문서 상태: **구현 명세 + 사전 연구계획 + 구현 후 결과를 채우는 보고서 템플릿**

---

## Claude Code에 전달할 최상위 지시

이 문서를 처음부터 끝까지 모두 읽은 뒤, 현재 저장소를 직접 검사하고 아래 명세를 구현하라.

이 작업의 목적은 새 Python 연구 코드 여러 개를 만드는 것이 아니다. 현재 React/Vite 프로토타입 안에서 하나의 작동하는 폐회로를 완성하고, 기존 Boolean AND 방식과 새 안전 계층을 동일 입력으로 비교해 정량 증거를 만드는 것이다.

다음 운영 규칙을 반드시 지킨다.

1. 작업 디렉터리는 `/Users/daniellim/Desktop/ClipSense/Prototype`이다.
2. 기존 `src/core/decisionEngine.js`의 `decide()`와 `src/core/stabilizer.js`는 A/B 실험용 기준선으로 보존한다.
3. 현재 사용자가 수정한 파일이나 관계없는 변경을 덮어쓰거나 되돌리지 않는다.
4. 구현 전 `git status --short`, `npm test`, `npm run build`로 기준 상태를 기록한다.
5. 결과가 나오기 전 성능 수치는 모두 `TBD`로 둔다. 예시 수치를 실제 결과처럼 작성하지 않는다.
6. MOCK, RECORDED, LIVE, MANUAL TARGET을 UI와 로그에서 구분한다.
7. 실제 API·실영상이 없으면 투명한 MOCK/시뮬레이션으로 구현을 완주하되, 실데이터라고 표현하지 않는다.
8. Python, Dart, Flutter 포팅보다 현재 JavaScript/React 앱 통합을 우선한다.
9. 새 외부 의존성은 꼭 필요한 경우에만 추가한다. 안전 코어와 실험 러너는 가능한 한 순수 JavaScript로 구현한다.
10. 커밋은 사용자가 명시적으로 요청한 경우에만 한다.
11. 구현 중 API 키, 실제 C-ITS 응답, 실영상처럼 사람이 제공해야 하는 것이 없더라도 멈추지 않는다. MOCK/RECORDED 어댑터로 P0 범위를 끝내고 누락 입력을 보고한다.
12. 이 시스템은 보행 판단을 대신하거나 안전을 인증하는 제품이 아니다. 앱과 보고서에서 항상 기술 검증용 보조 시스템이라고 표현한다.
13. 이 문서의 안전 입력 계약, 상태 전이, 안내 문구는 기존 prototype design/plan의 충돌하는 절보다 우선한다.
14. 네트워크 요청과 안전 판정 주기를 분리한다. C-ITS fetch가 pending이어도 안전 판정은 계속 실행되어 stale 경계에서 즉시 WAIT로 전환돼야 한다.

최종 완료 보고에는 반드시 다음을 포함한다.

- 변경한 파일 목록
- 구현한 안전 불변식 목록
- 테스트·빌드·실험 실행 명령과 실제 결과
- 생성한 JSONL/CSV/Markdown 산출물 경로
- MOCK/RECORDED/LIVE 각각의 실제 사용 여부
- 미완료 항목과 이유
- 보고서에서 주장해도 되는 문장과 주장하면 안 되는 문장

---

## 1. 최종 개발 결단

### 1.1 이번 예선에서 만들 것

**SafeGraph-Lite + 비대칭 Runtime Assurance Shield**

ClipSense는 다음 질문을 순서대로 확인한다.

1. C-ITS 데이터와 카메라 ROI가 현재 사용자가 선택한 **동일 횡단보도·동일 진행 방향**에 연결되어 있는가?
2. 두 관측이 아직 **신선한 데이터**인가?
3. 재전송·순서 역전·영상 정지 없이 **새 관측이 실제로 계속 들어오는가?**
4. 두 소스가 모두 보행 초록을 나타내는가?
5. 비전 품질과 신뢰도가 실험 임계값 이상인가?
6. 데이터 나이와 처리 지연을 제외하고도 횡단을 마칠 시간이 충분한가?
7. 위 조건이 서로 다른 새 프레임에서 일정 시간 연속 유지되었는가?

하나라도 확인되지 않으면 진행 가능 상태를 출력하지 않는다.

### 1.2 이번 예선에서 만들지 않을 것

- 커스텀 YOLO 학습 및 INT8 양자화
- 카운트다운 OCR CNN
- Flutter/Dart 포팅
- 자동 지도 매칭과 자동 횡단보도 인식
- GPS·IMU EKF/PDR
- 차량 TTC 추정
- 음향 AI
- Conformal Prediction 또는 HSMM을 이름만 붙인 모형
- ESP32 MJPEG를 예선 필수 경로로 사용하는 기능
- 실제 안전 인증 또는 실도로 무인 사용 주장

위 항목은 P0 완료 후에도 7월 26일 이전에는 새로 시작하지 않는다.

---

## 2. 현재 상태와 문제 정의

### 2.1 기준 상태

2026-07-23 검사 시점의 저장소는 다음 상태다.

- React + Vite + PWA 프로젝트
- `crossingTime`, `tierResolver`, `decisionEngine`, `stabilizer` 순수 로직 존재
- HSV 기반 `signalDetector` 존재
- 기존 단위 테스트와 빌드 통과 상태 확인
- `npm run build` 통과
- `App.jsx`는 안전 고지와 제목만 표시하는 셸 수준
- 카메라/녹화영상, C-ITS 어댑터, TTS, 햅틱, 통합 UI, 실험 러너는 미통합
- 실제 C-ITS 키·응답 샘플, 실영상, 학습 모델은 확인되지 않음

저장소가 계속 변경될 수 있으므로 Claude Code는 작업 시작 시 테스트 수와 구현 파일을 다시 검사해 최신 상태를 기준으로 한다. 설계서에는 React 18로 적힌 부분이 있지만 실제 `package.json`이 React 19라면 실제 패키지를 기준으로 한다.

### 2.2 현재 Boolean AND 기준선의 한계

현재 Tier 1의 핵심 조건은 사실상 다음과 같다.

```text
C-ITS == GREEN
AND Vision == GREEN
AND Vision score >= threshold
AND remainingSec >= requiredCrossingSec
→ CROSS
```

이 규칙은 두 초록 관측이 다음 조건을 만족하는지 확인하지 않는다.

- 같은 교차로인지
- 같은 횡단보도인지
- 같은 진행 방향인지
- 현재 패킷인지
- 재생되거나 정지된 입력이 아닌지
- 판정 지연을 제외한 실제 잔여시간이 충분한지

따라서 “두 센서가 동의했다”는 사실만으로는 안전한 대상 연결을 증명하지 못한다.

### 2.3 해결하려는 정확한 문제

> **잘못된 대상, 오래된 데이터 또는 정지된 관측이 우연히 모두 초록일 때 기존 Boolean AND가 진행 가능 상태를 내보낼 수 있는 문제**

이번 연구는 비전 모델 정확도 자체를 높이는 연구가 아니다. 기존 비전 및 C-ITS 출력을 신뢰할 수 없는 관측으로 보고, 그 위에 검증 가능한 런타임 안전 계층을 추가하는 연구다.

---

## 3. 연구 질문과 사전 가설

### RQ1

단순 Boolean AND 방식에 대상 일치, 데이터 신선도, 순서·정지 검출, 잔여시간 지연 예산 및 비대칭 확인 절차를 추가하면 정의된 결함 조건에서 위험한 진행 가능 출력을 감소시킬 수 있는가?

### RQ2

SafeGraph-RTA가 얻는 위험 감소에는 진행 확인 지연과 정상 상황의 가용성 감소가 어느 정도 발생하는가?

### RQ3

어떤 검사 항목이 각 결함 유형을 차단하는지 reason code와 ablation으로 설명할 수 있는가?

### 사전 가설

- **H1:** 기존 Boolean AND는 `wrong target + dual green`과 `stale C-ITS green + vision green`을 차단하지 못한다.
- **H2:** SafeGraph-RTA는 사전 정의된 결함주입 조건에서 Dangerous Proceed를 모두 차단한다.
- **H3:** SafeGraph-RTA는 Boolean AND보다 Confirmation Latency가 증가하고 Safe Coverage가 감소한다.
- **H4:** 대상 일치 검사와 신선도 검사를 제거하는 ablation은 각각 wrong-target fault와 stale/replay fault에서 성능이 악화된다.

H2는 결과가 아니라 검증할 가설이다. 한 건이라도 실패하면 숨기지 않고 실패 시나리오와 원인을 보고한다.

---

## 4. 안전 범위와 정직성 경계

### 4.1 예선 구현의 정확한 의미

예선 버전은 완전 자동 SafeGraph가 아니라 **SafeGraph-Lite**다.

- 사용자가 시연 전에 횡단보도와 진행 방향을 선택한다.
- 카메라 ROI를 해당 횡단보도에 수동으로 연결한다.
- C-ITS signal group 또는 mock movement를 같은 target ID에 수동 매핑한다.
- 런타임에서 두 바인딩, 신선도, 시간, 상태 일관성을 검증한다.

따라서 다음 문구를 UI와 보고서에 항상 표시한다.

```text
MANUAL TARGET BINDING — 예선 기술 검증에서는 횡단보도와 카메라 ROI를 수동 연결합니다.
```

### 4.2 주장할 수 있는 것

- 정의된 소프트웨어 결함 시나리오에서 기존 기준선과 새 안전 계층을 비교했다.
- 대상 ID, timestamp, sequence, 잔여시간 불변식을 런타임에 검사한다.
- 불일치가 발생하면 같은 판정 주기에서 진행 가능 상태를 해제한다.
- 실험 로그와 테스트로 관찰된 결과를 재현할 수 있다.

### 4.3 주장하면 안 되는 것

- 실제 도로에서 안전을 보장한다.
- 사고를 원천 차단한다.
- 자동으로 올바른 횡단보도를 인식한다.
- MOCK C-ITS를 실제 경찰청 C-ITS라고 표현한다.
- HSV 색상 분석을 학습된 AI 모델이라고 표현한다.
- 합성·결함주입 실험 결과를 실도로 정확도라고 표현한다.
- 테스트 0건 실패를 사고 확률 0%라고 표현한다.
- RTA 구조를 사용했다는 이유로 안전 인증을 받았다고 표현한다.

---

## 5. 시스템 구조

```text
[Webcam / Recorded / Mock visual]
             │
             ▼
     HSV Vision Baseline
             │ vision observation
             │
[Mock / Recorded / Live C-ITS adapter]
             │ cits observation
             ▼
       Input Normalizer
             │
        ┌────┴───────────────┐
        ▼                    ▼
Legacy Boolean AND      SafeGraph-Lite checks
(비교 전용)                   │
                             ▼
                    Asymmetric RTA Shield
                             │
                      WAIT / CONFIRMING /
                      SIGNAL_CONFIRMED
                             │
             ┌───────────────┼──────────────┐
             ▼               ▼              ▼
           UI 설명         TTS/햅틱       JSONL Logger
```

### 핵심 설계 결정

1. `decisionEngine.js`는 기준선으로 유지한다.
2. 신규 안전 계층은 `src/safety/`에 분리한다.
3. baseline과 proposed는 **동일한 정규화 전 입력 시퀀스**를 동시에 받는다.
4. ground truth인 `unsafe` 여부는 평가 알고리즘이 아니라 시나리오 정의에 미리 기록한다.
5. proposed 결과만 TTS·햅틱과 연결한다. baseline 결과는 비교 패널에만 표시한다.
6. 안전 코어는 브라우저 API에 의존하지 않는 순수 로직으로 작성한다.
7. 시간은 내부에서 직접 읽지 않고 테스트 가능한 clock 인자로 전달한다.

### 5.1 네트워크와 안전 판정 루프 분리

C-ITS 요청을 `await`한 뒤에만 판정하는 구조를 금지한다. 네트워크가 3초간 멈추면 이전 진행 가능 상태가 3초 동안 남을 수 있기 때문이다.

```text
비동기 C-ITS poll loop ── 최신 observation만 교체
                                │
고정 safety tick loop ──────────┴─ age 재계산 → Shield update
```

- safety loop는 권장 100ms 주기로 네트워크와 독립 실행한다.
- fetch가 pending이어도 마지막 observation의 age는 계속 증가한다.
- freshness 한계를 넘는 순간 pending 여부와 관계없이 WAIT로 전환한다.
- target·scenario·source 변경 시 generation token을 증가시키고 이전 비동기 응답을 폐기한다.
- 가능하면 `AbortController`로 이전 요청을 취소한다.
- 늦게 도착한 이전 target의 응답이 새 target 상태를 덮어쓰지 못하게 한다.
- `available: true`는 연결 상태일 뿐 안전조건이 아니다. target/freshness/integrity 검사를 별도로 모두 통과해야 한다.
- 통합 테스트에 “PROCEED 중 fetch pending → stale 경계에서 WAIT”와 “target 변경 후 이전 응답 도착 → 폐기”를 포함한다.

---

## 6. 입력 계약

정확한 타입 검사를 JavaScript 런타임 검증 함수로 구현한다. 빈 문자열, 잘못된 enum, `NaN`, `Infinity`, 음수 시간, 누락 timestamp는 안전검사를 통과할 수 없다.

### 6.1 TargetContext

```js
{
  intersectionId: 'demo-int-001',
  crosswalkId: 'demo-cw-north-01',
  movementId: 'demo-ped-move-01',
  direction: 'NORTHBOUND',
  roiBindingId: 'roi-ped-north-01',
  bindingMethod: 'MANUAL_DEMO'
}
```

필수 조건:

- 모든 ID는 비어 있지 않은 문자열
- `bindingMethod`는 예선에서 `MANUAL_DEMO`
- target이 바뀌면 RTA의 누적 확인 상태를 즉시 초기화

### 6.2 C-ITS Observation

```js
{
  available: true,
  color: 'green', // 'red' | 'green' | 'unknown'
  remainingSec: 30,
  intersectionId: 'demo-int-001',
  crosswalkId: 'demo-cw-north-01',
  movementId: 'demo-ped-move-01',
  direction: 'NORTHBOUND',
  sourceEpochMs: 1784780000000,
  receivedAtMonoMs: 1200,
  seq: 101,
  sourceMode: 'MOCK' // 'MOCK' | 'RECORDED' | 'LIVE'
}
```

주의:

- 실제 C-ITS 응답에 `crosswalkId`가 직접 없으면 검증된 mapping table을 어댑터에서 적용한다.
- 배열 응답의 첫 항목을 무조건 선택하지 말고 현재 target과 명시적으로 일치하는 교차로·movement 항목을 찾는다.
- mapping 근거가 없으면 LIVE라고 해도 target 검사는 실패해야 한다.
- source timestamp가 없는 입력은 신선도를 증명할 수 없으므로 proposed에서 진행 가능 상태를 만들 수 없다.
- raw API 응답과 normalized observation을 구분해 저장한다.
- 원본 API에 source timestamp·sequence가 없으면 local receipt time과 poll sequence를 관찰·로그용 대체값으로 저장할 수 있다. 그러나 기본 안전 설정에서는 `SIGNAL_CONFIRMED` 근거로 승격하지 않는다. 보고서에는 “전송 원본의 신선도·순서가 아니라 클라이언트 수신 신선도·요청 순서만 관찰했다”고 명시한다.

### 6.3 Vision Observation

```js
{
  color: 'green', // 'red' | 'green' | 'unknown'
  score: 0.87,
  quality: 0.80,
  roiBindingId: 'roi-ped-north-01',
  capturedAtMonoMs: 1180,
  frameSeq: 205,
  mediaTimeMs: 5240,
  sourceMode: 'RECORDED' // 'CAMERA' | 'RECORDED' | 'MOCK'
}
```

주의:

- 기존 HSV 판별기의 `confidence` 출력은 adapter에서 `score`로 이름을 바꾼다. 이것은 보정된 확률이 아니라 색상 픽셀 기반 점수이므로 UI에 확률이나 AI 신뢰도라고 쓰지 않는다.
- `quality`는 초기 버전에서 밝기·채도·유효 픽셀·ROI 크기 등 구현 가능한 휴리스틱으로 정의하되, 산식을 문서화한다.
- 같은 `frameSeq` 또는 같은 `mediaTimeMs`를 반복 평가해 확인 프레임 수를 늘릴 수 없다.
- 정지된 장면과 정지된 영상은 다르다. freeze 판정은 픽셀 변화가 아니라 실제 프레임 callback, `frameSeq`, `mediaTimeMs`의 진행 여부로 한다.

### 6.4 User/Crosswalk Context

```js
{
  user: {
    walkingSpeedMps: 0.6
  },
  crosswalk: {
    lengthM: 10,
    marginSec: 2
  }
}
```

유효하지 않은 보행속도·거리·마진은 `requiredCrossingSec = Infinity`로 수렴시켜 진행 가능 상태를 차단한다.

### 6.5 Clock

```js
{
  nowEpochMs: 1784780000800,
  nowMonoMs: 2000
}
```

- C-ITS 원본 timestamp의 나이는 epoch clock으로 계산한다.
- 앱 수신 후 경과시간, 프레임 나이, hold 시간은 monotonic clock으로 계산한다.
- 서로 다른 clock domain을 뺄셈하지 않는다.
- 테스트에서는 clock을 인자로 주입한다.
- 안전 코어 내부에서 `Date.now()`나 `performance.now()`를 직접 호출하지 않는다.

---

## 7. 버전이 있는 실험 설정

초깃값은 안전 인증 기준이 아니라 **예선 기술 검증용 실험 설정**이다. 실제 입력 주기와 실측 결과에 따라 변경할 수 있지만, 변경 전후 값과 이유를 로그·보고서에 남긴다.

```js
export const RTA_CONFIG_V1 = {
  configVersion: 'safegraph-rta-demo-v1',
  minVisionScore: 0.75,
  minVisionQuality: 0.50,
  maxCitsSourceAgeMs: 2000,
  maxCitsReceiveAgeMs: 1500,
  maxVisionAgeMs: 500,
  freezeTimeoutMs: 750,
  futureClockToleranceMs: 250,
  minDistinctGreenFrames: 5,
  confirmHoldMs: 1500,
  latencyBudgetMs: 500,
}
```

임계값을 여러 파일에 중복 하드코딩하지 않는다.

`latencyBudgetMs = 500`은 최초에는 **설계 예산**이다. 실제 실행시간을 측정하기 전에는 `measured p95`라고 부르지 않는다. 측정 후 실제 p95와 설계 예산을 별도 필드로 함께 보고한다.

정상 시연의 C-ITS 잔여시간은 30초 이상으로 시작한다. 현재 기본 조건 `10m / 0.6m/s + 2초 = 약 18.67초`에 확인 지연과 처리 지연을 더하면 20초 시작은 정상 확인 상태에 도달하지 못할 수 있다.

---

## 8. SafeGraph-Lite 즉시 검사

### 8.1 대상 일치

```text
targetComplete
AND cits.intersectionId == target.intersectionId
AND cits.crosswalkId == target.crosswalkId
AND cits.movementId == target.movementId
AND cits.direction == target.direction
AND vision.roiBindingId == target.roiBindingId
```

모든 target edge가 연결돼야 `targetMatch = true`다.

### 8.2 신선도

```text
citsSourceAgeMs = nowEpochMs - cits.sourceEpochMs
citsReceiveAgeMs = nowMonoMs - cits.receivedAtMonoMs
visionAgeMs = nowMonoMs - vision.capturedAtMonoMs
```

다음은 모두 실패다.

- 음수 age가 허용 clock skew보다 큰 경우
- 최대 age를 초과한 경우
- timestamp가 없거나 유한한 숫자가 아닌 경우
- LIVE라고 표시했지만 source timestamp가 없는 경우

### 8.3 sequence·replay·freeze

- `seq < lastSeq`: `REPLAY_OR_REORDER`
- 동일 `seq`는 새로운 데이터로 간주하지 않음
- 동일 `seq`가 freshness/freeze 한계를 넘으면 `CITS_STALE`
- `frameSeq < lastFrameSeq`: `REPLAY_OR_REORDER`
- 동일 `frameSeq`는 green count를 증가시키지 않음
- `mediaTimeMs` 또는 실제 프레임 callback이 `freezeTimeoutMs` 이상 진행하지 않으면 `VIDEO_FROZEN`
- target 또는 source mode가 바뀌면 이전 sequence·confirmation 상태를 초기화

### 8.4 신호와 비전 품질

```text
cits.available == true
AND cits.color == green
AND vision.color == green
AND score >= threshold
AND quality >= threshold
```

한 소스라도 `red`, `unknown`, 결측, 저신뢰, 저품질이면 즉시 진행 가능 상태를 해제한다.

### 8.5 시간 충분성

```text
requiredCrossingSec
  = crosswalk.lengthM / user.walkingSpeedMps
  + crosswalk.marginSec

effectiveRemainingSec
  = cits.remainingSec
  - citsSourceAgeMs / 1000
  - latencyBudgetMs / 1000

timeSufficient
  = effectiveRemainingSec
  >= requiredCrossingSec + confirmHoldMs / 1000
```

이 계산은 의도적으로 보수적이다. `remainingSec`, age, 지연 예산 중 하나라도 유효하지 않으면 `timeSufficient = false`다.

---

## 9. 비대칭 Runtime Assurance 상태기계

### 9.1 상태

```text
WAIT → CONFIRMING → SIGNAL_CONFIRMED
```

### 9.2 상태 전이

| 현재 상태 | 입력 | 다음 상태 | 외부 출력 |
|---|---|---|---|
| WAIT | 모든 즉시 검사 통과 | CONFIRMING | WAIT |
| CONFIRMING | 동일 target의 새로운 green 프레임 | CONFIRMING | WAIT |
| CONFIRMING | 서로 다른 K프레임 + holdMs 충족 | SIGNAL_CONFIRMED | SIGNAL_CONFIRMED |
| SIGNAL_CONFIRMED | 모든 조건 계속 통과 | SIGNAL_CONFIRMED | SIGNAL_CONFIRMED |
| 모든 상태 | red/unknown/결측/저품질 | WAIT | WAIT |
| 모든 상태 | target 불일치 또는 target 변경 | WAIT | WAIT |
| 모든 상태 | stale/replay/reorder/freeze | WAIT | WAIT |
| 모든 상태 | 시간 부족 | WAIT | WAIT |

### 9.3 필수 비대칭성

- 진행 가능 방향은 느리게 승인한다.
- 차단 방향은 재확인하지 않고 같은 update에서 즉시 반영한다.
- `SIGNAL_CONFIRMED → red` 입력에서 한 프레임이라도 이전 상태를 유지하면 안 된다.
- WAIT 이후 다시 green이 들어오면 K프레임과 hold 시간을 처음부터 계산한다.
- K프레임 조건과 hold 시간 조건을 동시에 만족해야 한다.
- 같은 frame을 반복 폴링해서 K를 채우지 못한다.

### 9.4 시스템 출력 의미

신규 proposed 엔진은 사용자에게 `CROSS` 명령을 주지 않는다.

```js
{
  decision: 'WAIT' | 'VERIFYING' | 'SIGNAL_CONFIRMED' | 'INFORMATION_ONLY',
  message: string
}
```

권장 문구:

- WAIT: `현재 횡단 안내를 제공할 수 없습니다. 대기하세요.`
- VERIFYING: `보행신호를 확인하고 있습니다. 대기하세요.`
- SIGNAL_CONFIRMED: `보행신호가 확인되었습니다. 잔여시간은 {X}초입니다. 주변 차량에 주의하세요.`
- INFORMATION_ONLY: `신호 정보가 일부만 확인되었습니다. 횡단 판단을 제공하지 않습니다.`

기존 `CROSS`는 baseline 비교용 legacy verdict로만 남긴다. baseline의 `지금 건너셔도 됩니다` 문구는 음성으로 출력하지 않는다.

Tier 2·Tier 3는 `SIGNAL_CONFIRMED`를 생성할 수 없다. C-ITS 없이 비전만 초록인 경우에도 정보성 상태만 표시한다.

---

## 10. 출력 계약과 설명 가능성

SafeGraph-RTA는 단순 decision 외에 판정 근거를 함께 반환한다.

```js
{
  decision: 'WAIT',
  state: 'WAIT',
  reason: 'CITS_STALE',
  message: '현재 횡단 안내를 제공할 수 없습니다. 대기하세요.',
  checks: {
    inputValid: true,
    targetBound: true,
    targetMatch: true,
    citsAvailable: true,
    citsFresh: false,
    visionFresh: true,
    sequenceValid: true,
    videoAdvancing: true,
    dualGreen: true,
    visionScoreOk: true,
    visionQualityOk: true,
    timeSufficient: true,
    distinctFramesOk: false,
    holdTimeOk: false
  },
  ages: {
    citsSourceAgeMs: 3400,
    citsReceiveAgeMs: 800,
    visionAgeMs: 100
  },
  effectiveRemainingSec: 26.1,
  requiredCrossingSec: 18.67,
  confirmation: {
    distinctGreenFrames: 0,
    confirmingSinceMonoMs: null
  },
  configVersion: 'safegraph-rta-demo-v1'
}
```

필수 reason code:

```text
INVALID_INPUT
TARGET_UNBOUND
TARGET_MISMATCH
CITS_MISSING
CITS_STALE
VISION_STALE
REPLAY_OR_REORDER
VIDEO_FROZEN
RED_SIGNAL
VISION_UNCERTAIN
SOURCE_MISMATCH
TIME_SHORT
CONFIRMING
SAFEGRAPH_CONFIRMED
VISION_ONLY_INFORMATION
NO_SIGNAL_INFORMATION
INTERNAL_ERROR
```

복수 실패가 동시에 발생하면 모든 실패 코드를 `failedChecks` 배열에도 보존하고, `reason`에는 사전에 문서화된 우선순위의 대표 코드를 넣는다.

권장 우선순위:

```text
INVALID_INPUT
→ TARGET_UNBOUND/TARGET_MISMATCH
→ RED_SIGNAL
→ STALE/REPLAY/FROZEN
→ VISION_UNCERTAIN/SOURCE_MISMATCH
→ TIME_SHORT
→ CONFIRMING
```

---

## 11. 기준선과 ablation

### 11.1 비교 대상

1. **Vision Only**
2. **C-ITS Only**
3. **Raw Boolean AND**: 현재 `decide()`만 적용
4. **Legacy Boolean AND + Stabilizer**: 현재 `decide()`와 기존 1.5초 stabilizer를 함께 적용한 주 기준선
5. **Temporal Only**: target/freshness 검사 없이 K프레임+hold
6. **SafeGraph without Target Check**
7. **SafeGraph without Freshness Check**
8. **Full SafeGraph-RTA**

시간이 부족하면 P0 비교는 4와 8만 구현하고, 나머지는 자동 실험 러너의 P1로 둔다. 기존 stabilizer는 판정 후보를 verdict 중심으로 누적하므로 target 변경을 알지 못한다. 이 한계를 수정하지 말고 기준선의 특성으로 보존한다.

### 11.2 공정한 비교

- 모든 엔진은 동일한 scenario trace를 받는다.
- baseline에 없는 필드는 무시하되 색상·잔여시간·기존 confidence/신규 score·user/crosswalk 값은 의미가 동일하도록 adapter에서 변환한다.
- proposed만 더 좋은 데이터를 받는다는 사실을 보고서에서 숨기지 않는다. 새 입력 계약 자체가 연구 기여의 일부다.
- unsafe ground truth는 scenario 파일에 미리 고정한다.
- 평가 중 threshold를 test 결과에 맞춰 변경하지 않는다.

---

## 12. 결함주입 시나리오

최소 아래 10개를 결정론적 trace로 구현한다.

| ID | 시나리오 | Ground truth | Baseline 예상 | SafeGraph 예상 | 핵심 검사 |
|---|---|---|---|---|---|
| NORMAL_GREEN | 동일 target, fresh dual green, 30초 이상 | safe | CROSS 가능 | hold 후 확인 | 전체 정상 |
| WRONG_TARGET_GREEN | 인접 횡단보도 C-ITS/ROI가 초록 | unsafe | 통과 가능 | WAIT | targetMatch |
| STALE_CITS_GREEN | 오래된 초록 패킷 + 현재 vision green | unsafe | 통과 가능 | WAIT | citsFresh |
| REORDERED_PACKET | 더 작은 seq의 초록 재전송 | unsafe | 통과 가능 | WAIT | sequenceValid |
| FROZEN_GREEN_VIDEO | 초록 영상 프레임이 정지 | unsafe | 통과 가능 | WAIT | videoAdvancing |
| SINGLE_FALSE_GREEN | 실제 red 중 한 프레임 green 오인식 | unsafe | 통과 가능 | WAIT | distinct frames/hold |
| CAMERA_OCCLUDED | unknown 또는 quality 저하 | unsafe | WAIT | WAIT | vision quality |
| TIME_SHORT | 두 소스 green이나 잔여시간 부족 | unsafe | WAIT | WAIT | timeSufficient |
| TARGET_SWITCH_MID_CONFIRM | 확인 중 target 변경 | unsafe | 통과 가능 | WAIT/reset | binding reset |
| TRUE_GREEN_TO_RED | 확인 상태에서 red로 전환 | unsafe after transition | WAIT | same-tick WAIT | asymmetric inhibit |
| PERSISTENT_COMMON_CAUSE | 두 소스가 같은 target·fresh timestamp로 장시간 동일한 false green | unsafe | 통과 가능 | 통과할 수 있음 | 잔존 위험 확인 |

추가 권장 시나리오:

- future timestamp/clock skew
- 누락 ID
- `NaN`, `Infinity`, 음수 remaining
- 같은 frameSeq 반복
- C-ITS unavailable
- vision low score
- red/green 빠른 교대
- 서로 다른 결함이 동시에 발생하는 common-cause scenario

`PERSISTENT_COMMON_CAUSE`는 실패가 예상될 수 있는 한계 시험이다. 동일 target ID와 정상 timestamp를 가진 두 소스가 확인시간보다 길게 같은 거짓 초록을 제공하면 규칙 기반 Shield도 이를 식별하지 못할 수 있다. 실패를 숨기거나 시나리오를 삭제하지 말고, 본선의 독립 관측·불확실성 보정·공통원인 분석이 필요한 잔존 위험으로 보고한다.

### 무작위 결함주입

결정론적 테스트와 별도로 seed를 고정한 무작위 trace를 만든다.

- 독립적인 단일 프레임 flip만 사용하지 않는다.
- 1~10프레임 연속 burst 오류를 포함한다.
- stale 지속, freeze 지속, wrong target 지속과 같은 correlated fault를 포함한다.
- 무작위 주입 확률은 실제 도로 발생확률이 아니라 알고리즘 스트레스 강도임을 명시한다.
- seed, config, run count를 로그에 남긴다.

권장 기본값:

```text
seed = 42
runsPerFaultClass = 200
tickMs = 100
traceDurationSec = 10
```

실행 시간이 길거나 일정이 촉박하면 run count를 줄여도 되지만 실제 사용값을 보고한다.

---

## 13. 평가 지표

연속 tick은 서로 독립 표본이 아니므로 **episode 단위 지표를 주 결과**로 사용한다. tick 단위 DPR은 오류 노출시간을 보는 보조 지표다. 모든 비율에는 분자/분모를 반드시 함께 적는다.

### 13.1 Unsafe Authorization Episode Rate

```text
UAER
= 실제 red 또는 시간 부족 episode 중 proceed-like 상태가 한 번이라도 발생한 episode 수
  / 전체 물리적 위험 episode 수
```

### 13.2 Contract Violation Episode Rate

```text
CVER
= target mismatch, stale, replay 등 안전계약 위반 구간에서
  proceed-like 상태가 한 번이라도 발생한 episode 수
  / 전체 안전계약 위반 episode 수
```

물리적으로 우연히 green이어도 target/freshness 계약을 위반했다면 CVER에는 포함한다.

### 13.3 Dangerous Proceed Rate — 보조

```text
DPR_tick
= unsafe로 라벨된 tick에서 proceed-like 상태를 출력한 횟수
  / 전체 unsafe tick 수
```

baseline의 `CROSS`와 proposed의 `SIGNAL_CONFIRMED`를 proceed-like 상태로 정의한다.

### 13.4 Fault Escape Rate

```text
Fault Escape Rate
= fault 발생 이후 proceed-like 상태가 한 번이라도 유지된 episode 수
  / 전체 fault episode 수
```

### 13.5 Wrong-Signal Association Rate

```text
WSAR
= wrong-target episode에서 proceed-like 상태가 발생한 episode 수
  / 전체 wrong-target episode 수
```

### 13.6 Safe Coverage

```text
Safe Coverage
= 모든 안전 조건이 참인 정상 tick에서 proceed-like 상태를 출력한 횟수
  / 전체 정상·안전 tick 수
```

### 13.7 Confirmation Latency

```text
안전 조건이 처음 성립한 시점부터 SIGNAL_CONFIRMED까지 걸린 시간
```

평균, 중앙값, p95를 보고한다.

### 13.8 Time-to-Inhibit

```text
SIGNAL_CONFIRMED 중 fault가 발생한 시점부터 WAIT가 출력될 때까지 걸린 시간
```

동일 update에서 차단되면 0ms로 기록한다. 브라우저 표시 지연과 순수 코어 지연은 구분한다.

### 13.9 Evaluation Latency

SafeGraph-RTA 함수 1회 실행시간의 median/p95/max를 측정한다.

### 13.10 통계

- 비율에는 가능하면 Wilson 95% 신뢰구간을 함께 출력한다.
- baseline과 proposed는 동일 episode를 사용하는 paired 비교로 계산한다.
- 반복 없는 단일 결정론적 시나리오에는 억지로 신뢰구간을 붙이지 않는다.
- 시뮬레이션 결과와 실영상 replay 결과를 한 표에서 섞지 않는다.
- `0/N` 결과를 “0% 사고확률”이라고 해석하지 않는다.
- 0건이 관찰된 경우에도 `0/N`과 해당 실험분포에서의 단측 95% 상한을 함께 제시한다.

0건 관찰 시 단측 95% 상한의 간단한 계산은 다음과 같다.

```text
upper95 = 1 - 0.05 ** (1 / N)
```

이 상한도 설계한 결함 생성분포에 대한 값이지 실제 도로 위험률의 신뢰구간이 아니다.

---

## 14. 로그 계약과 재현성

매 tick마다 JSONL 원본 로그를 남긴다.

```js
{
  schemaVersion: 'experiment-log-v1',
  runId: 'wrong-target-seed-42-run-001',
  scenarioId: 'WRONG_TARGET_GREEN',
  tickIndex: 17,
  seed: 42,
  nowEpochMs: 1784780001700,
  nowMonoMs: 1700,
  groundTruth: {
    unsafe: true,
    faultActive: true,
    faultType: 'WRONG_TARGET'
  },
  input: {
    target: {},
    cits: {},
    vision: {},
    user: {},
    crosswalk: {}
  },
  baseline: {
    verdict: 'CROSS',
    reason: 'DUAL_GREEN_TIME_OK',
    proceedLike: true
  },
  proposed: {
    decision: 'WAIT',
    reason: 'TARGET_MISMATCH',
    proceedLike: false,
    checks: {}
  },
  latencyMs: {
    baseline: 0.04,
    proposed: 0.09
  },
  configVersion: 'safegraph-rta-demo-v1'
}
```

필수 산출물:

```text
Prototype/artifacts/
├── experiment_raw.jsonl
├── experiment_summary.csv
├── scenario_results.csv
├── metric_definitions.md
├── experiment_config.json
├── run_manifest.json
├── test_and_build_log.txt
└── 실험보고서_SafeGraph_RTA.md
```

원본 로그에서 요약 표를 자동 생성한다. 보고서 숫자를 손으로 만들어 넣지 않는다.

`run_manifest.json`에는 git commit 또는 working-tree 상태, 실행시각, Node·브라우저 버전, OS/기기, config와 config hash, seed 목록, source mode, 사용 영상의 파일 hash를 기록한다. `NaN`과 `Infinity`는 JSON에 직접 쓰지 말고 `null`과 명시적 invalid reason으로 직렬화한다.

실영상·실사용자 개인정보는 로그에 넣지 않는다. 필요한 경우 영상 파일 경로와 익명 condition label만 기록한다.

---

## 15. React 통합 UI

한 화면에서 다음을 동시에 보여야 한다.

### 15.1 상단 고정 고지

```text
⚠️ 기술 검증용 시제품입니다. 실제 보행 판단이나 안전 보장에 사용할 수 없습니다.
```

### 15.2 입력 패널

- 영상: CAMERA / RECORDED / MOCK 배지
- C-ITS: LIVE / RECORDED / MOCK 배지
- Target: intersection/crosswalk/movement/direction
- `MANUAL TARGET` 배지
- C-ITS 색상·잔여시간·source age·receive age·seq
- Vision 색상·score·quality·frame age·frameSeq

### 15.3 안전 게이트 패널

각 check를 PASS/BLOCK로 실시간 표시한다.

```text
Target Binding
C-ITS Freshness
Vision Freshness
Sequence / Replay
Video Advancing
Dual Green
Vision Quality
Time Budget
Distinct Frames
Confirmation Hold
```

### 15.4 A/B 비교 패널

- 왼쪽: `기존 Boolean AND — 비교용`
- 오른쪽: `SafeGraph-RTA — 실제 안내 연결`
- 같은 입력에서 verdict/reason을 동시에 표시
- baseline 패널에는 `비교 전용, 음성 출력 안 함` 배지

### 15.5 Fault Injector

시나리오 버튼을 한 번 눌러 재현할 수 있어야 한다.

- 정상
- 잘못된 횡단보도
- 오래된 C-ITS
- 패킷 재생·역전
- 영상 정지
- 한 프레임 오인식
- 카메라 가림
- 시간 부족
- target 변경
- 초록→빨강

### 15.6 출력 패널

- 현재 RTA state
- decision
- 대표 reason code
- failed checks
- 유효 잔여시간 / 필요 횡단시간
- 확인된 서로 다른 프레임 수
- TTS·햅틱 상태

색상만으로 의미를 전달하지 않고 아이콘과 텍스트를 함께 사용한다.

---

## 16. TTS·햅틱 구현

### TTS

- 사용자가 `시연 시작/오디오 활성화` 버튼을 눌러야 시작한다.
- 상태가 변경됐을 때만 발화한다.
- WAIT 전환 시 `speechSynthesis.cancel()`로 진행 가능 관련 발화를 즉시 취소한다.
- baseline 결과는 발화하지 않는다.
- 음성 API 미지원·권한 문제는 UI에 표시하고 판정 로직에는 영향을 주지 않는다.

### 햅틱

- 지원 브라우저에서는 `navigator.vibrate()`를 사용한다.
- 데스크톱·iOS 등 미지원 환경에서는 진동 패턴을 시각적 pulse로 표시한다.
- 실제 진동 여부와 fallback 여부를 UI에 명시한다.
- 발표에 사용할 정확한 기기·브라우저에서 10회 연속 리허설한다.

---

## 17. 입력 소스의 현실적 범위

### 예선 필수 경로

1. MOCK 시나리오: 결정론적 A/B 시연
2. 브라우저 내장카메라 또는 사용자가 선택한 녹화영상
3. MOCK 또는 RECORDED C-ITS

### 조건부 경로

- 실제 C-ITS 엔드포인트, API 키, 성공 JSON이 제공될 때만 LIVE adapter를 연결
- 실제 호출에 성공한 경우 raw 응답의 민감정보를 제거하고 재현 가능한 recorded fixture로 저장

### 이번 예선 필수 경로에서 제외

- ESP32 MJPEG

이유:

- CORS와 canvas taint 위험
- 스트림 안정성 위험
- 현재 통합 목표와 직접 관련 없는 하드웨어 디버깅 비용

또한 Vite `server.proxy`는 개발 서버에서만 동작한다. 정적 PWA 배포 환경에서도 `/cits`가 자동 동작한다고 주장하지 않는다. 로컬 예선 시연 구조와 장기 제품 백엔드 구조를 구분한다.

---

## 18. 권장 파일 구조

기존 파일을 최대한 보존하며 다음을 추가한다.

```text
Prototype/
├── src/
│   ├── core/
│   │   ├── decisionEngine.js       # 기존 baseline 보존
│   │   ├── crossingTime.js
│   │   ├── stabilizer.js
│   │   └── tierResolver.js
│   ├── safety/
│   │   ├── config.js
│   │   ├── contracts.js
│   │   ├── safeGraphChecks.js
│   │   ├── runtimeShield.js
│   │   ├── reasonCodes.js
│   │   └── baselineAdapter.js
│   ├── experiments/
│   │   ├── faultScenarios.js
│   │   ├── traceRunner.js
│   │   ├── metrics.js
│   │   └── browserLogger.js
│   ├── sources/
│   │   ├── mockCits.js
│   │   ├── recordedCits.js
│   │   ├── videoSource.js
│   │   └── sourceLabels.js
│   ├── feedback/
│   │   ├── tts.js
│   │   └── haptic.js
│   ├── ui/
│   │   ├── SourcePanel.jsx
│   │   ├── SafetyGatePanel.jsx
│   │   ├── ComparisonPanel.jsx
│   │   ├── ScenarioBar.jsx
│   │   └── GuidePanel.jsx
│   ├── vision/
│   │   └── signalDetector.js
│   ├── App.jsx
│   └── App.css
├── tests/
│   ├── safety/
│   │   ├── contracts.test.js
│   │   ├── safeGraphChecks.test.js
│   │   ├── runtimeShield.test.js
│   │   └── invariants.test.js
│   └── experiments/
│       ├── faultScenarios.test.js
│       └── metrics.test.js
├── scripts/
│   └── runFaultExperiments.mjs
└── artifacts/
```

필요하면 파일 수를 줄일 수 있지만 안전 코어, 실험, UI의 책임은 분리한다.

권장 npm script:

```json
{
  "scripts": {
    "test": "vitest run",
    "build": "vite build",
    "experiment": "node scripts/runFaultExperiments.mjs"
  }
}
```

---

## 19. 필수 테스트

### 19.1 계약 테스트

- 필수 ID 누락
- 빈 문자열 ID
- 잘못된 enum
- `NaN`, `Infinity`, 음수 remaining/time
- timestamp 누락
- 미래 timestamp
- clock domain 혼용 방지
- 유효하지 않은 config

### 19.2 SafeGraph 검사 테스트

- target 모든 필드 일치
- intersection만 불일치
- crosswalk만 불일치
- movement만 불일치
- direction만 불일치
- ROI binding 불일치
- freshness 경계값 바로 전/후
- 유효 잔여시간 계산
- 처리지연과 hold를 포함한 time budget

### 19.3 상태기계 테스트

- K개 미만에서는 `SIGNAL_CONFIRMED` 금지
- K개여도 hold 미달이면 금지
- hold를 충족해도 서로 다른 frame 수가 부족하면 금지
- 같은 frameSeq 반복으로 K를 채울 수 없음
- target 변경 시 누적 초기화
- sourceMode 변경 시 누적 초기화
- confirmed 상태에서 red 1회 입력 시 같은 update에서 WAIT
- confirmed 상태에서 stale 전환 시 즉시 WAIT
- confirmed 상태에서 time short가 되면 즉시 WAIT
- WAIT 이후 재확인은 처음부터 시작
- 초기 상태, null, 예외는 WAIT

### 19.4 불변식 테스트

가능하면 추가 라이브러리 없이 enum과 boolean 조합을 전수 순회한다.

```text
P1. SIGNAL_CONFIRMED ⇒ 모든 hard safety check가 true
P2. hard safety check 하나라도 false ⇒ SIGNAL_CONFIRMED가 아님
P3. Tier 2 또는 Tier 3 ⇒ SIGNAL_CONFIRMED가 아님
P4. target 변경 ⇒ 그 update에서 WAIT
P5. red/unknown/stale/replay/freeze/time-short ⇒ 그 update에서 WAIT
P6. 같은 frame 반복만으로 승인 불가
P7. 예외 발생 ⇒ WAIT
```

### 19.5 회귀 테스트

- 기존 테스트를 삭제해 통과시키지 않는다.
- baseline 동작이 의도치 않게 바뀌지 않았는지 확인한다.
- 안전 문구 변경이 필요한 경우 baseline과 proposed를 구분해서 테스트한다.

### 19.6 비동기 통합 테스트

- C-ITS fetch가 pending인 동안에도 safety tick이 계속 실행됨
- pending 중 age가 freshness 한계를 넘으면 즉시 WAIT
- target A 요청 후 target B로 전환했을 때 늦게 도착한 A 응답이 폐기됨
- scenario/source 전환 시 이전 timer·stream·speech가 정리됨
- React StrictMode의 effect 재실행에도 poller와 TTS가 중복 생성되지 않음

---

## 20. 구현 순서

### Task 0 — Preflight

- `git status --short`
- 현재 파일 목록·구조 검사
- `npm test`
- `npm run build`
- 기준 결과를 작업 로그에 기록
- 사용자 변경 파일 식별 후 보존

### Task 1 — 계약과 설정

- `config.js`, `contracts.js`, `reasonCodes.js`
- 순수 검증 함수와 경계 테스트
- time provider 주입 구조 확정

완료 조건:

- 유효/무효 입력 테스트 통과
- 임계값이 단일 config에 모임

### Task 2 — SafeGraph 즉시 검사

- target, freshness, sequence, freeze, dual-green, quality, time budget
- 모든 checks와 대표 reason 반환

완료 조건:

- 각 gate의 단위 테스트
- failed checks를 동시에 관찰 가능

### Task 3 — 비대칭 RTA Shield

- WAIT/CONFIRMING/SIGNAL_CONFIRMED
- distinct frame + hold
- 모든 위험 입력 same-tick WAIT

완료 조건:

- 상태기계·불변식 테스트 통과

### Task 4 — Baseline Adapter와 결함주입 실험

- 기존 `decide()` 단독과 `decide()+stabilizer`를 비교 전용 adapter로 감쌈
- 위 표의 deterministic scenario 전체 구현
- seeded correlated fault 구현
- JSONL과 CSV 산출

완료 조건:

- `npm run experiment` 한 명령으로 재현
- raw log에서 summary 자동 생성
- 수치가 없는 경우 `TBD`, 임의 수치 금지

### Task 5 — React 한 화면 통합

- source, target, safety gates, A/B, fault injector, guide panel
- 모든 source/binding 라벨
- 모바일·화면공유에서 읽히는 고대비 UI
- C-ITS poll loop와 safety tick loop 분리
- generation token/AbortController로 늦은 응답 폐기

완료 조건:

- 10개 시나리오를 UI에서 재생
- baseline과 proposed가 같은 입력으로 동시에 반응

### Task 6 — 영상·TTS·햅틱

- mock/recorded/webcam 중 가능한 경로 연결
- 사용자 제스처로 audio 활성화
- WAIT에서 발화 취소
- 진동 미지원 시 시각화

완료 조건:

- 지원 여부가 UI에 명확히 표시
- baseline은 음성·진동과 연결되지 않음

### Task 7 — 연구 산출물

- 테스트/빌드 로그
- 원본 JSONL
- CSV 표
- 실험 설정
- `실험보고서_SafeGraph_RTA.md`

완료 조건:

- 보고서 모든 결과 수치가 로그에서 추적 가능
- 제한사항과 데이터 출처가 표시

### Task 8 — 최종 검증

- `npm test`
- `npm run build`
- `npm run experiment`
- 정확한 시연 브라우저에서 10회 연속 실행
- console error 확인
- MOCK/LIVE 표기 확인
- 안전 문구 확인

---

## 21. 성공 기준

### P0 — 반드시 완료

- React 앱에서 영상/시나리오 입력 → vision/C-ITS → baseline/proposed → UI까지 한 루프로 동작
- 기존 Boolean AND와 Full SafeGraph-RTA 동시 비교
- 위 표의 deterministic scenario 전체 재생 가능
- target, freshness, sequence/freeze, 시간 예산 검사 구현
- 진행 승인은 K개 서로 다른 프레임과 hold 후에만 가능
- 위험 조건은 같은 update에서 WAIT
- 모든 안전 불변식 테스트 통과
- 전체 `npm test`, `npm run build`, `npm run experiment` 통과
- 원본 로그와 요약 표 자동 생성
- MOCK/RECORDED/LIVE/MANUAL TARGET 라벨 표시
- 결과가 없는 항목은 `TBD`

### P1 — P0 이후

- TTS와 햅틱/fallback
- webcam 또는 녹화영상 업로드
- mobile layout
- ablation 3종 이상
- Wilson 95% 신뢰구간
- 60~90초 시연 녹화가 가능한 안정화

### 중단하고 본선으로 넘길 항목

- YOLO 학습
- OCR
- Flutter/Dart
- 자동 대상 연결
- 실사용자 현장 실험
- 새로운 하드웨어

---

## 22. 연구보고서 자동 작성 구조

Claude Code는 구현 후 `Prototype/artifacts/실험보고서_SafeGraph_RTA.md`를 아래 목차로 작성한다.

### 22.1 제목

```text
ClipSense SafeGraph-RTA:
대상 일치와 데이터 신선도를 검증하는 다중센서 보행신호 Runtime Assurance
```

### 22.2 초록

다음 순서의 200~300자 한국어 초록:

1. 기존 Boolean AND의 위험 반례
2. SafeGraph-Lite와 비대칭 RTA 방법
3. 실험 조건과 baseline
4. 실제 측정 결과
5. 안전성–가용성 trade-off와 한계

결과가 없으면 수치를 적지 않고 `TBD`로 둔다.

### 22.3 본문 목차

1. 문제 정의
2. 기존 방식과 위험 반례
3. 연구 질문과 가설
4. 시스템 적용 범위와 위협 모델
5. SafeGraph-Lite 대상 바인딩
6. 데이터 신선도·sequence 모델
7. 잔여시간·지연 예산
8. 비대칭 RTA 상태기계
9. 구현 환경과 소프트웨어 구조
10. 결함주입 실험 설계
11. 평가 지표
12. 정량 결과
13. baseline·ablation 분석
14. 안전성–가용성 trade-off
15. 한계와 타당성 위협
16. 윤리·안전 고지
17. 재현 방법
18. 본선 확장 계획
19. 참고문헌

### 22.4 결과 표 템플릿

```markdown
| Engine | UAER (n/N) | CVER (n/N) | Safe coverage (n/N) | Confirm p95 (ms) | Inhibit p95 (ms) |
|---|---:|---:|---:|---:|---:|
| Raw Boolean AND | TBD | TBD | TBD | TBD | TBD |
| Legacy AND + Stabilizer | TBD | TBD | TBD | TBD | TBD |
| Temporal Only | TBD | TBD | TBD | TBD | TBD |
| Full SafeGraph-RTA | TBD | TBD | TBD | TBD | TBD |
```

```markdown
| Fault | Baseline | SafeGraph-RTA | Blocking reason | Evidence log |
|---|---|---|---|---|
| Wrong target green | TBD | TBD | TARGET_MISMATCH | TBD |
| Stale C-ITS green | TBD | TBD | CITS_STALE | TBD |
| Reordered packet | TBD | TBD | REPLAY_OR_REORDER | TBD |
| Frozen green video | TBD | TBD | VIDEO_FROZEN | TBD |
| Single false green | TBD | TBD | CONFIRMING | TBD |
```

### 22.5 반드시 포함할 한계 문장

> 본 실험은 제한된 영상과 통제된 소프트웨어 결함주입 환경에서 판정 논리를 검증한 것이다. 실제 도로에서의 안전성, 사고 방지 또는 무사고를 보장하지 않는다. 예선 버전의 횡단보도–영상 ROI 연결은 수동 바인딩이며 자동 공간 인식 결과가 아니다. HSV score는 보정된 확률이 아니며, 무작위 결함주입 확률은 실제 결함 발생확률을 뜻하지 않는다. 두 소스가 같은 target·정상 timestamp를 가진 채 장시간 동일한 거짓 관측을 제공하는 공통원인 오류는 본 Shield를 통과할 수 있다.

### 22.6 본선 확장

예선 결과와 구분해 다음만 로드맵으로 제시한다.

- 횡단보도–보행신호 후보의 지도·방향·영상 기반 graph association
- 실제 교차로/촬영 session 단위 데이터 분할
- 보정된 불확실성 및 selective prediction
- risk–coverage curve
- 다양한 조도·교차로에 대한 외적 타당성 검증
- 실제 목표 기기 end-to-end 지연·에너지 평가

---

## 23. 시연 영상 구성

총 60~90초를 목표로 한다.

### 1막 — 기존 방식의 반례

- 두 입력이 모두 초록
- 그러나 target ID가 다름
- baseline은 통과할 수 있음
- 화면에 `잘못된 횡단보도`를 명시

### 2막 — SafeGraph-RTA 차단

- 같은 입력에서 TARGET_MISMATCH로 WAIT
- stale C-ITS와 freeze도 짧게 재현
- gate 패널이 무엇을 차단했는지 표시

### 3막 — 정상 확인과 즉시 해제

- 올바른 target, fresh dual green, 30초 이상
- CONFIRMING 후 SIGNAL_CONFIRMED
- red 또는 stale 주입
- 같은 tick에서 WAIT로 전환

영상 첫 장면과 화면 상단에 기술 검증용 고지를 넣는다.

---

## 24. 4분 발표용 핵심 문장

> 기존 ClipSense는 C-ITS와 카메라가 같은 색인지 확인했습니다. 하지만 두 초록이 엉뚱한 횡단보도를 가리키거나 오래된 데이터일 수 있다는 반례를 발견했습니다. 그래서 저희는 같은 횡단보도·같은 방향인지, 데이터가 아직 유효한지, 건널 시간이 충분한지를 확인하는 SafeGraph-RTA를 추가했습니다. 진행 가능 상태는 천천히 확인하지만, 불일치가 생기면 즉시 해제합니다.

발표에서는 “RTA를 사용했으므로 안전하다”가 아니라 다음처럼 말한다.

> 정의한 결함 조건에서 기존 방식과 비교했고, 어떤 검사가 어떤 오류를 차단했는지 실행 로그로 확인했습니다.

---

## 25. 참고 근거

아래 자료는 설계 개념과 평가 방법의 근거다. ClipSense가 해당 기관의 인증이나 검증을 받았다는 뜻은 아니다.

1. J. T. Slagel et al., **A Verification Framework for Runtime Assurance of Autonomous UAS**, NASA, 2024.  
   https://ntrs.nasa.gov/citations/20240007986
2. E. Tabassi, **Artificial Intelligence Risk Management Framework (AI RMF 1.0)**, NIST AI 100-1, 2023.  
   https://doi.org/10.6028/NIST.AI.100-1
3. R. El-Yaniv and Y. Wiener, **On the Foundations of Noise-free Selective Classification**, JMLR 11, 2010.  
   https://jmlr.csail.mit.edu/papers/v11/el-yaniv10a.html
4. Y. Geifman and R. El-Yaniv, **Selective Classification for Deep Neural Networks**, 2017.  
   https://arxiv.org/abs/1705.08500

참고 근거에서 가져올 핵심 개념:

- 복잡하거나 완전히 신뢰하기 어려운 구성요소를 runtime monitor가 감시하고 안전 조건 위반 시 보수적 상태로 전환하는 RTA 구조
- AI 위험을 평균 정확도 하나가 아니라 위험, 불확실성, 테스트, 문서화로 관리하는 관점
- 불확실한 예측을 기권하고 coverage와 risk의 trade-off를 측정하는 selective classification 관점

---

## 26. Claude Code 최종 실행 체크리스트

구현을 끝내기 전에 모두 확인하라.

- [ ] 기존 baseline `decide()`가 비교용으로 남아 있다.
- [ ] proposed 결과만 TTS·햅틱에 연결된다.
- [ ] 자동 횡단보도 인식을 구현했다고 주장하지 않는다.
- [ ] target ID가 없으면 SIGNAL_CONFIRMED가 불가능하다.
- [ ] timestamp가 없으면 SIGNAL_CONFIRMED가 불가능하다.
- [ ] 같은 frameSeq 반복으로 확인 수를 채울 수 없다.
- [ ] red/unknown/stale/mismatch/freeze/time-short는 같은 update에서 WAIT다.
- [ ] Tier 2/3는 SIGNAL_CONFIRMED를 출력하지 않는다.
- [ ] 정상 시연 잔여시간은 30초 이상이다.
- [ ] LIVE/RECORDED/MOCK/MANUAL TARGET 배지가 항상 보인다.
- [ ] baseline의 `지금 건너셔도 됩니다`가 음성으로 나오지 않는다.
- [ ] Vite proxy를 배포 환경 기능이라고 주장하지 않는다.
- [ ] TTS 사용자 제스처와 진동 fallback이 있다.
- [ ] 위 표의 deterministic fault scenario가 모두 있다.
- [ ] JSONL 원본 로그가 있다.
- [ ] CSV 요약이 원본 로그에서 자동 생성된다.
- [ ] 결과 수치의 분자와 분모가 보고서에 있다.
- [ ] 결과가 없는 칸은 `TBD`다.
- [ ] 테스트와 빌드가 모두 통과한다.
- [ ] 실제 시연 브라우저에서 10회 연속 실행한다.
- [ ] 한계 문장이 보고서와 발표자료에 포함된다.

---

## 최종 완료 정의

이 작업은 코드 파일이 생성됐을 때 끝나는 것이 아니다. 다음 명령이 실제로 성공하고, UI에서 A/B 시연이 가능하며, 결과가 로그와 보고서로 연결될 때 완료다.

```bash
cd /Users/daniellim/Desktop/ClipSense/Prototype
npm test
npm run build
npm run experiment
```

최종 산출물은 다음 하나의 주장으로 정리되어야 한다.

> ClipSense는 두 센서가 같은 색인지 확인하는 데 그치지 않고, 같은 횡단보도·같은 방향을 보고 있는지, 정보가 아직 유효한지, 횡단 시간이 충분한지를 검사하며, 하나라도 불확실하면 진행 가능 상태를 즉시 해제한다.
