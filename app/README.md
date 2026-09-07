# Clip Sense 모바일 앱

서울 T-Data 보행신호와 휴대전화 카메라 판정을 함께 확인해 한국어 음성·진동으로
안내하는 Flutter 프로토타입이다. **API와 카메라가 모두 초록이고 잔여시간이 충분할
때만** `건너세요`를 낸다. 어느 한쪽이 없거나 오래됐거나 서로 다르면 안전하게
`기다리세요` 또는 `확인 불가`로 물러난다. 잔여시간의 기준은 API이고, 카메라가 읽은
7세그 숫자는 그보다 짧을 때만 `기다리세요`로 작용하는 거부권이다(API 잔여가 없으면
카메라 숫자만으로 건너지 않는다).

> 이 앱은 연구·공모전용 보조 프로토타입이다. 공식 음향신호기나 사용자의 현장 판단을
> 대체하지 않으며, 실제 횡단의 유일한 근거로 사용하면 안 된다.

## 실행

필요한 것은 Flutter 3.35 이상(Dart 3.9 이상), Android/iOS 실기기, 승인된 서울
T-Data API 키다.

```bash
cd app
flutter pub get
flutter run --dart-define=TDATA_KEY='발급받은_API_키'
```

API 키는 소스나 `.env`에 저장하지 않는다. 키가 비어 있거나 API·카메라가 실패하면
앱은 보행 허용을 내지 않는다. 카메라와 위치 권한은 앱이 처음 필요로 할 때 OS가
요청한다.

사용 흐름은 다음과 같다.

1. GPS로 100m 안의 지원 교차로를 찾는다.
2. 실제로 건널 횡단보도 방향을 큰 버튼에서 선택한다.
3. 휴대전화 뒤 카메라를 보행 신호등으로 향하고, 신호등이 영상 **중앙 4분의 1**
   (가로·세로 25%, `kRoiFrac`) 안에 들어오도록 맞춘다. 검출은 이 영역만 본다.
4. 화면을 탭해 안내를 시작한다. 다시 탭하거나 이전 화면으로 나가면 카메라와 1초
   판단 루프가 정지한다.

현재 공식 좌표로 등록된 교차로는 청계2가(1850), 정동(1537), 국일관(1620)이다.
좌표·이름은 서울 T-Data `교차로 MAP 정보` 2024-11-14 배포 CSV로 검증했다.

## 클립 카메라 소스 (옷깃 클립 ESP32S3, 실기기 미검증)

`CLIP_CAM_HOST`를 주면 폰 카메라 대신 [클립 카메라 펌웨어](../firmware/README.md)의
`/capture` JPEG 스냅샷을 판정에 쓴다. 주지 않으면 폰 카메라가 기본이다.

```bash
flutter run \
  --dart-define=TDATA_KEY='발급받은_API_키' \
  --dart-define=CLIP_CAM_HOST=192.168.4.1 \
  --dart-define=CLIP_CAM_TOKEN='펌웨어 secrets.h 의 CLIP_DEVICE_TOKEN'
```

동작(`lib/clip/`): 250ms 간격 폴링(이전 요청이 끝나기 전엔 새 요청 없음, 800ms
타임아웃은 연결을 실제로 끊음) → 계약 헤더(`X-Frame-Seq`·`X-Capture-Uptime-Us`·
`X-Response-Uptime-Us`·`X-Boot-Id`)로 신선도·정지·재부팅 추적 → 새 프레임만
JPEG 디코드(순수 Dart) → 중앙 25% ROI → 폰 카메라와 같은 판정 파이프라인.

안전 규칙은 폰 카메라보다 엄격하다.

| 상황 | 동작 |
|---|---|
| 같은 `frameSeq` 반복(카메라 정지) | 신선도를 갱신하지 않음 → 2초 지나면 판정 불가·이력 리셋 |
| 503/409/타임아웃/헤더 불량/순서 역전/디코드 실패 | 즉시 판독 unknown + 디바운스 이력 리셋(정상 프레임 한 장으로 초록 복귀 금지) |
| `bootId` 변경(재부팅) | 이력 폐기 |
| 401/403(토큰 불일치) | `failed`, 폴링 중단(같은 토큰 재시도 안 함) |
| 응답 없음 | `unreachable` → 음성 "클립 카메라에 연결할 수 없습니다. 전원과 Wi-Fi 연결을 확인해 주세요" |

알아 둘 것:

- 초록 확정에는 accepted 프레임 8장(`debounceFrames`)이 필요해 250ms 폴링이면 최소
  약 2초 걸린다. 점멸(초당 1~2회)은 4Hz 샘플링에서 놓칠 수 있으므로 점멸 판정은
  T-Data의 clearance 상태(엄격 AND)에 기댄다.
- ROI 25%(QVGA → 80x60)의 근거: 실클립을 4:3으로 잘라 QVGA로 줄인 실측
  (`scripts/dump_clip_qvga_fixture.py`, fixture `test/fixtures/clip_qvga_*.jpg`)에서
  전체 프레임은 점등에도 no_blob(초록 0.40% < 0.5%), 50%는 점멸 **소등** 프레임에서도
  GREEN(0.82%)이라 점멸을 놓치고, 25%는 점등 GREEN 3.4% / 소등 NONE이었다.
  80x60에서는 7세그먼트 숫자를 읽을 수 없으므로 클립 경로는 잔여시간 거부권을
  내지 않는다(잔여시간 기준은 원래 API).
- Android 평문 http 허용(`res/xml/network_security_config.xml`), iOS
  `NSLocalNetworkUsageDescription`·`NSAllowsLocalNetworking`, macOS `network.client`
  엔타이틀먼트는 **작성만 됐고 실기기에서 확인되지 않았다**.
- 검증 범위: MockClient, 루프백 `dart:io` HttpServer, 스크립트 카메라, cv2 인코딩 JPEG
  fixture. 실제 보드·폰·OV2640 JPEG·왕복 시간·초당 프레임·인식 거리는 **미측정**.
  `.local` 이름은 OS 해석에 맡기며 Android에서는 IP를 쓰는 것이 안전하다.

## 구조

```text
GPS → 최근접 교차로·방향 선택
폰 카메라 YUV420/BGRA ─┐
클립 카메라 /capture JPEG ┴→ 중앙 ROI BGR → 색/점멸/숫자 판독 ┐
서울 T-Data 실시간 보행신호 API                              ├→ 엄격 AND 판단
                                                              └→ 화면·한국어 TTS·진동
```

- `lib/camera/`: 프레임 변환, 폰 카메라 스트림, 최신 비전 판정
- `lib/clip/`: 클립 카메라 HTTP 계약(헤더 파서·신선도 추적·스냅샷 클라이언트·JPEG 디코드·소스)
- `lib/vision/`: HSV 색 검출, 상태 머신, 7-세그먼트 판독, 소스 공용 판정 파이프라인
- `lib/signals/`: T-Data 파싱, 표준 판정 타입, 이중 판단 엔진
- `lib/app/`: GPS 선택, 1초 안내 루프, 접근성 화면
- `lib/feedback/`: 한국어 TTS와 상태별 진동

## 자동 검증

```bash
cd app
flutter test
flutter analyze
```

프레임 변환 테스트는 YUV plane stride·pixel stride와 iOS BGRA row padding까지
검증한다. 카메라 하드웨어, OS 권한, TTS, 진동은 플러그인 경계라 아래 실기기 검증도
반드시 수행한다.

## Android 릴리스 서명

릴리스가 실수로 debug 키로 서명되지 않도록, 서명 설정이 없으면 release 빌드는
명시적으로 실패한다. `android/key.properties.example`을
`android/key.properties`로 복사하고 비공개 keystore 경로·암호를 넣은 뒤 빌드한다.

```bash
flutter build appbundle --release --dart-define=TDATA_KEY='배포용_API_키'
```

`key.properties`, `*.jks`, `*.keystore`는 Git에서 제외된다. `--dart-define` 값은 앱
바이너리에서 추출될 수 있으므로 T-Data 측 사용 제한과 배포용 키 회전 정책을 별도로
적용해야 한다.

## 실기기 출고 체크리스트

- 카메라·위치 권한 허용/거부/재시도 흐름이 모두 안전하게 동작한다.
- 세 지원 교차로에서 GPS 선택 이름과 실제 위치가 일치한다.
- 각 노출 방향이 T-Data의 실제 횡단보도 방향과 일치한다.
- 맑음·흐림·야간·역광에서 빨강/초록/점멸을 촬영하고 오인식률을 기록한다.
- 렌즈를 가리거나 앱을 백그라운드로 보내면 2초 안에 보행 허용이 사라진다.
- API 네트워크를 끊거나 카메라 권한을 거부하면 `건너세요`가 나오지 않는다.
- API와 카메라가 불일치할 때 `기다리세요`가 나오고 한국어 TTS·진동이 전달된다.
- 화면 읽기(TalkBack/VoiceOver)에서 방향 버튼, 상태 live region, 시작/정지 조작이
  중복 없이 읽힌다.
- 릴리스 빌드에서도 `TDATA_KEY` 주입 여부와 키 사용 제한·재발급 정책을 확인한다.

실환경 HSV 값과 프레임 처리 주기는 촬영 기기·거리·조명에 따라 달라진다. 자동 테스트가
통과해도 위 체크리스트를 통과하기 전에는 현장 배포 완료로 간주하지 않는다.
