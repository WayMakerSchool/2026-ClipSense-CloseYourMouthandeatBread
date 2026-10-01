# ClipSense 프로토타입 설계서

- 날짜: 2026-07-23
- 목적: 제8회 한국코드페어 SW공모전 2차 예선심사 제출용 시제품
- 마감: 2026-07-26 23:59 (시연영상 + 발표 PPT/PDF 제출)
- 발표: 4분, Zoom 화면공유. 시연영상은 심사 전 위원 사전 시청

## 1. 배경과 목표

ClipSense는 옷깃 클립 카메라(ESP32-S3)와 경찰청 C-ITS 실시간 신호 데이터, 비전 AI를
교차(이중) 검증하여 시각장애인의 횡단보도 횡단을 음성·진동으로 보조하는 시스템이다.

이 프로토타입이 심사에서 증명해야 하는 것 (구현 완성도 25점):

1. 실제 C-ITS API에서 실시간 신호·잔여시간 수신 (API 키 발급·호출 성공 상태)
2. 카메라 영상에서 신호등 색 판별 (비전 AI)
3. **두 소스 불일치 시 즉시 "대기" 판정 (Fail-Safe)** — 작품의 정체성
4. 잔여시간 < 필요 횡단시간이면 초록불이어도 "대기"
5. Tier 1 → 2 → 3 자동 전환 (C-ITS 장애/무신호 환경)

서면 제출물과의 정합성: 요약서에 "현재 React+Vite+PWA로 프로토타입 개발 중
(목표 아키텍처: Flutter 네이티브)"로 기재되어 있으므로 본 프로토타입은 React+Vite+PWA로
구현한다. Flutter는 향후 목표로 유지.

## 2. 기술 스택

| 항목 | 선택 | 비고 |
|------|------|------|
| 프레임워크 | React 18 + Vite (JavaScript) | 서면 기재와 일치. TS 미사용(3일 완주 우선) |
| PWA | vite-plugin-pwa 기본 설정 | manifest + 설치 가능 수준. 오프라인 캐시 미구현 |
| 비전 | Canvas + HSV 색상 분석 (주력) / TensorFlow.js COCO-SSD (여유 시 보조) | |
| 음성 | Web Speech API (ko-KR TTS) | |
| 진동 | Vibration API (폰 실동작, 데스크톱은 패턴 시각화) | |
| 테스트 | Vitest — `core/` 순수 로직만 | |
| C-ITS 연동 | Vite dev server proxy (API 키 은닉 + CORS 우회) | |

## 3. 아키텍처

```
[영상 입력]  내장 카메라 ─┐
             ESP32 스트림 ─┴─→ 비전 판별기 (신호등 색) ─┐
                                                       ├─→ 판정 엔진 ─→ TTS + 진동 + 화면
[C-ITS]  실호출 / 모의(mock) ──────────────────────────┘   (Fail-Safe)
```

```
Prototype/
├── src/
│   ├── core/                    # 순수 로직 — 브라우저 API 의존 0, Vitest 대상
│   │   ├── decisionEngine.js    # 이중검증 + Fail-Safe 판정
│   │   ├── tierResolver.js      # Tier 1/2/3 자동 결정
│   │   └── crossingTime.js      # 필요 횡단시간 = 거리/보행속도 + 여유
│   ├── sources/                 # 외부 입력 어댑터 (런타임 교체 가능)
│   │   ├── citsClient.js        # C-ITS 실호출, 실패 시 오류 반환 → Tier 2 강등
│   │   ├── mockCits.js          # 시연 시나리오용 모의 신호
│   │   └── videoSource.js       # [내장 카메라 | ESP32 MJPEG] 토글
│   ├── vision/
│   │   └── signalDetector.js    # HSV 신호등 색 판별 → {color, confidence}
│   ├── feedback/
│   │   ├── tts.js               # 발화 큐 관리 (같은 안내 반복 방지)
│   │   └── haptic.js            # 상황별 진동 패턴
│   ├── ui/
│   │   ├── CameraView.jsx       # 카메라 뷰 + 판별 영역 오버레이
│   │   ├── VerifyPanel.jsx      # C-ITS/비전/Tier/잔여·필요시간 실시간 표시
│   │   ├── GuidePanel.jsx       # 판정 결과 초대형 고대비 표시
│   │   └── ScenarioBar.jsx      # 시연 시나리오 원클릭 주입 + 영상 소스 토글
│   └── App.jsx
├── tests/core/                  # 판정 엔진 테스트
└── vite.config.js               # C-ITS 프록시 설정
```

설계 원칙:

- **core/는 순수 함수**: 판정 로직을 테스트로 증명 ("Fail-Safe는 주장이 아니라 테스트로 검증")
- **sources/는 어댑터**: C-ITS 실호출↔모의, 내장카메라↔ESP32를 런타임 교체.
  하드웨어·네트워크 리스크가 소프트웨어 완주를 막지 않는다

## 4. 판정 엔진 (decisionEngine)

입력/출력:

```js
decide({
  tier,                    // 1 | 2 | 3
  cits:   { color, remainingSec, available },
  vision: { color, confidence },
  user:   { walkingSpeed },      // 기본 0.6 m/s (고령자·중복장애 기준)
  crosswalk: { lengthM },        // 기본 10 m (시연용 조정 가능)
})
→ { verdict, message, hapticPattern, reason }
```

`verdict`: `CROSS` | `CAUTION` | `WARNING` | `WAIT`

판정 규칙 (작품설명서 표1과 1:1 대응):

| Tier | 판정 | 조건 | 안내 문구 |
|------|------|------|-----------|
| 1 | CROSS | C-ITS 초록 AND 비전 초록(conf ≥ 0.6) AND remainingSec ≥ lengthM/속도 + 2초 | "지금 건너셔도 됩니다" |
| 1 | WAIT | 위 조건 미충족 전부 (불일치, 시간부족, 데이터 결측 등) | 사유별: "시간이 부족합니다" / "신호 정보가 일치하지 않습니다. 대기하세요" |
| 2 | CAUTION | 비전 초록 AND conf ≥ 0.75 (단독이므로 더 엄격) | "초록불로 보입니다. 주변 확인 후 진행하세요" |
| 2 | WAIT | 그 외 | "신호를 확인할 수 없습니다. 대기하세요" |
| 3 | WARNING | 무신호 모드 진입 시 | "신호 없는 횡단보도입니다. 차량에 주의하세요" |
| 3 | WAIT | 기본 | 〃 |

핵심 결정:

1. **기본값 WAIT**: 함수 마지막 줄이 `return WAIT`. 어떤 조건에도 안 걸리면,
   입력이 비면, 예외가 나면 무조건 대기.
2. **잔여시간 완주 검증**: 여유 마진 2초. 설명서 테스트 시나리오(0.6m/s, 잔여 12초
   진입 시 대기) 재현 가능.
3. **비대칭 히스테리시스**: CROSS/CAUTION 발화는 동일 판정 연속 ≥ 1.5초 유지 시에만.
   WAIT 전환은 즉시. 안전 방향은 빠르게, 허가 방향은 신중하게.

## 5. tierResolver

```
C-ITS 응답 정상 (available)     → Tier 1
C-ITS 타임아웃·오류·미커버       → Tier 2   # 수동 전환 아님. 어댑터 실패 = 자동 강등
사용자가 무신호 모드 선택        → Tier 3
```

## 6. 비전 판별 (signalDetector)

1. 프레임 상단 60% 영역에서 HSV 변환 → 초록/빨강 픽셀 군집 검출
2. 군집 크기·밀집도로 confidence(0~1) 산출
3. 반환: `{ color: 'green'|'red'|'unknown', confidence }` — unknown이면 판정 엔진이 WAIT

- TF.js COCO-SSD는 2일차 여유 시 traffic light 박스 검출 보조로만 추가 (실패해도 HSV 단독 시연 가능)
- 시연 리허설 기본: 모니터에 신호등 이미지/영상을 띄워 카메라로 비춤 (조도 변수 제거)

## 7. C-ITS 연동 (citsClient)

- 실호출: Vite dev proxy 경유. API 키는 `.env.local` (git 미포함)
- 파싱: 보행 신호 상태 + 잔여시간 → `{ color, remainingSec, available }`
- 오류·타임아웃(3초) 시 `available: false` → Tier 2 강등
- **[사용자 제공 필요]** 실제 엔드포인트 URL, 성공 응답 JSON 샘플, 테스트한 교차로 ID
- mockCits: 시연 시나리오별 신호 시퀀스 재생 (화면에 "모의 신호 주입 중" 배지 상시 표시)

## 8. UI (화면 1장)

```
┌────────────────────────────────────────────┐
│ ⚠️ 기술 검증용 시연 — 실제 보행 판단 사용 불가 │  ← 상시 노출 (위험성 검토 P/F 대응)
├──────────────┬─────────────────────────────┤
│ 📷 CameraView │ VerifyPanel                  │
│  판별영역     │  C-ITS: 🟢 초록 잔여 18초     │
│  오버레이     │  비전AI: 🟢 초록 conf 0.87    │
│              │  Tier 1 │ 필요시간 18.7초      │
├──────────────┴─────────────────────────────┤
│ GuidePanel: "지금 건너셔도 됩니다"            │  ← 초대형 고대비 + TTS·진동 상태
├────────────────────────────────────────────┤
│ ScenarioBar: [Tier1][불일치][시간부족]        │
│ [API끊김→T2][무신호T3] │ 영상:[내장|ESP32]    │
└────────────────────────────────────────────┘
```

- 실관객은 심사위원 — 설명서의 "고대비 보조 UI(동행인·개발 검증용)" 명분과 일치하는 검증 화면
- VerifyPanel이 주인공: 두 소스가 따로 보이다가 판정에서 합쳐지는 과정을 실시간 노출
- 안전 고지는 앱 화면과 시연영상 첫 장면 모두에 삽입

## 9. 시연 영상 3막 (약 90초)

| 막 | 장면 | 증명 |
|----|------|------|
| 1막 정상 | 실제 C-ITS 수신 → 비전 초록 일치 → 잔여 충분 → CROSS | 이중 검증 성립 (실데이터) |
| 2막 Fail-Safe ★ | ① 비전 초록 + 모의 C-ITS 빨강 → 즉시 WAIT ② 초록 일치 + 잔여 8초 < 필요 18.7초 → WAIT | 불일치·시간부족 시 무조건 대기 |
| 3막 Tier 강등 | 네트워크 차단 → Tier 2 CAUTION / 무신호 → Tier 3 WARNING | 어떤 환경에서도 동작 |

## 10. 테스트 계획 (Vitest, core만)

- 불일치 조합 전수: C-ITS 초록×비전 빨강, 역방향, conf 미달, null/undefined 입력 → 전부 WAIT
- 잔여시간 경계값: 필요 18.67초일 때 잔여 18.6 → WAIT, 18.7 → CROSS
- Tier 강등: available=false → Tier 2, 무신호 → Tier 3
- 히스테리시스: 1프레임 튐 → 발화 없음, WAIT 전환 → 즉시

## 11. 범위 제외 (YAGNI)

- 정조준 Lock-on·가상 안전 복도 (설명서상 "향후 계획")
- GPS 20m 접근 감지 (실내 시연 불가 → ScenarioBar 버튼 대체)
- PWA 오프라인 캐시, 스마트워치 연동, STT 조작
- ESP32 실물 연동은 **보너스**: videoSource에 MJPEG URL 꽂는 자리만 마련. 셋업 성공 시 추가 녹화, 실패 시 내장 카메라로 진행 (일정에 미포함)

## 12. 성공 기준

1. `npm run dev`로 구동, 내장 카메라만으로 3막 시나리오 전부 재현 가능
2. core 테스트 전부 통과 (불일치 → WAIT 전수 검증)
3. 실제 C-ITS 호출 1회 이상 성공 장면 확보 (스크린샷/녹화)
4. 시연영상 녹화 가능 상태 (7/25까지), 제출 7/26