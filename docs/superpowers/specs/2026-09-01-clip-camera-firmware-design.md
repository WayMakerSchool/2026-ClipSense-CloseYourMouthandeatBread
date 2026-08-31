# 클립 카메라 펌웨어 설계 (2026-09-01)

## 왜 이 조각인가

작품명의 "Clip"은 옷깃에 다는 클립형 카메라를 가리킨다. 지금까지 제출 플랫폼은
스마트폰(A안)이었고 클립 장치는 로드맵 5단계로 미착수였다. 하드웨어 설계·제작
보고서 v0.2(2026-07-23)가 펌웨어 사양을 확정해 둔 상태였으므로, 그 사양대로
구현해 "설계만 있고 코드가 없는" 간극을 메운다.

**범위 밖:** 실기기 검증, 케이스·클립 제작, 배터리 구성. 보드가 확보되기 전에는
컴파일 통과 이상을 주장하지 않는다.

## 역할 분담 — 펌웨어는 판정하지 않는다

```
[클립 카메라 (ESP32S3)]     [판정 계층 (폰/브라우저)]
 JPEG 획득                   신호 색·잔여시간 판정
 frameSeq 증가               freshness·sequence 검사
 captureUptimeUs 기록        C-ITS/T-Data 결합
 bootId 발급                 이중 검증 → 음성 안내
 실패를 실패로 보고           불확실 → 대기
```

이 경계가 핵심이다. 펌웨어가 "이 프레임은 괜찮다"를 판단하면, 판정 계층이
정지·재부팅·오래된 프레임을 알아챌 근거를 잃는다. 그래서 펌웨어는 **관측 사실만**
넘긴다.

## 안전 설계 결정 4가지

### 1. 획득 실패 시 캐시를 재전송하지 않는다

`esp_camera_fb_get()`이 실패하면 **503**을 반환한다. 마지막 성공 프레임을 대신
보내면 판정 계층은 카메라가 멈춘 것을 영원히 모른다. 응답이 없는 것이 잘못된
응답보다 안전하다.

### 2. 프레임과 메타데이터를 원자적으로 묶는다

```cpp
xSemaphoreTake(_mutex, ...);
camera_fb_t* fb = esp_camera_fb_get();
const uint64_t captureUptimeUs = esp_timer_get_time();
_frameSeq++;
// ... 세 값을 하나의 CaptureResult로 반환, release()까지 mutex 유지
```

동시 요청이 프레임버퍼를 경쟁하면 "이 JPEG의 촬영 시각"이 어긋난다. mutex를
`release()`까지 잡는 이유는 framebuffer를 반환하기 전에 다른 요청이 같은 버퍼를
가져가는 것을 막기 위해서다.

### 3. `frameSeq`는 획득 성공에만 증가한다

판정 계층이 정지(freeze)를 감지하는 유일한 근거다. 요청 수나 응답 수로 세면
카메라가 멈춰도 숫자가 올라가 정지를 숨긴다.

### 4. `bootId`는 부팅마다 바뀐다

uptime은 재부팅 시 0으로 돌아간다. `bootId`가 바뀌면 판정 계층이 프레임 진행
비교 이력을 폐기해야 하며, 그러지 않으면 "시간이 거꾸로 간" 것으로 보인다.

## 네트워크 상태기계

```
BOOT → STA_CONNECTING ─ 성공 ────→ STA_ACTIVE
                      └ 15초 초과 → AP_RECOVERY

STA_ACTIVE ─ 두절 → STA_RECONNECTING (5초 × 6회) ─ 실패 → AP_RECOVERY
```

연결이 끊겼을 때 펌웨어는 **아무 판단도 하지 않는다.** 카메라 관측이 도달 불가가
되면 판정 계층이 freshness 만료로 스스로 대기에 들어간다. SoftAP는 자동
failover가 아니라 사람이 붙는 복구 경로다 — 조용히 모드가 바뀌면 기기가 어디에
있는지 알 수 없기 때문에, AP로 내려간 뒤 STA를 자동 재시도하지 않는다.

## 보안 (예선 범위)

팀 전용 격리망 + 기기 토큰을 전제한 완화책이며 생산 보안이 아니다.

- 데이터 엔드포인트에 `X-Clip-Device-Token` 필수, 상수 시간 비교
- CORS는 설정된 origin만 — 와일드카드 금지
- 조준 화면·MJPEG 스트림 기본 비활성
- `/health`에 SSID·비밀번호 미반환
- 프레임 미저장, 촬영 중 LED 점등
- `secrets.h`는 gitignore

## 시간 계산 계약 (§10.4)

기기 uptime과 브라우저 monotonic clock은 다른 domain이라 직접 뺄 수 없다.

```
serverFrameAgeMs   = (responseUptimeUs - captureUptimeUs) / 1000
conservativeAgeMs  = requestRttMs + serverFrameAgeMs
capturedAtMonoMs   = responseReceivedMonoMs - conservativeAgeMs
```

헤더 누락·비유한값·`responseUptime < captureUptime`이면 프레임 무효.
이 값은 물리적 카메라→판정 지연이 아니라 **요청 기반 보수적 추정**이다.

## 검증

| 항목 | 상태 |
|---|---|
| 컴파일 (arduino-cli, esp32:esp32:XIAO_ESP32S3) | 통과 |
| 업로드·실기기 동작 | **미검증** (보드 없음) |
| 프레임 지연·실효 fps | **미측정** |
| Wi-Fi 재접속 실제 소요 | **미측정** |
| 연속 동작 발열 | **미측정** |

컴파일 통과와 기기 동작은 다른 주장이다. 실기기 확보 후 측정해 이 표를 갱신한다.

## 다음 단계

1. 보드 확보 → 업로드 → 부팅 로그로 센서 PID·PSRAM·해상도 확인
2. `/health`·`/capture` 실호출, 프레임 지연 측정
3. 판정 계층에 Snapshot Adapter 연결 (보고서 §11)
4. 케이스·클립 제작 (보고서 §7, 현재 `HOLD`)
