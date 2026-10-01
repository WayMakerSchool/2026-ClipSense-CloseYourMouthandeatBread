# 🚦 ClipSense

> 실시간 신호 데이터와 옷깃 클립 카메라가 **둘 다 초록일 때만** "지금 건너셔도 됩니다"라고 말해 주는 시각장애인 횡단보도 안전 도우미

<!-- 대표 이미지나 시연 GIF가 있다면 여기에 넣어주세요. -->

> ⚠️ 연구·공모전용 보조 프로토타입입니다. 음향신호기나 사용자의 현장 판단을 대체하지 않습니다.

<br>

## 📖 프로젝트 소개

- **기간**: 2026.07.13 ~ 진행 중
- **프로젝트**: 2026 모두의 창업 프로젝트 · 제24회 임베디드SW경진대회 자유공모
- **소개**: 신호등이 있는 횡단보도 세 곳 중 두 곳에는 음향신호기가 없습니다(2021년 국정감사, 11만 7,484곳 중 3만 9,811곳만 설치). 그곳에서 시각장애인은 신호가 초록인지, 몇 초 남았는지 모른 채 건너야 합니다. ClipSense는 서울시 실시간 보행신호 데이터와 옷깃에 꽂는 카메라를 **함께** 확인해, 두 정보가 모두 초록이고 남은 시간이 충분할 때만 건너라고 안내합니다. 하나라도 불확실하면 **이유와 함께** 기다리라고 말합니다.

<br>

## ✨ 주요 기능

| 기능 | 설명 |
| :-- | :-- |
| 이중 검증 판정 | 신호 데이터 초록 + 카메라 초록 + 남은 시간 7초 이상 + 두 정보 모두 2초 이내 최신일 때만 "지금 건너셔도 됩니다, 15초 남았습니다" |
| 이유를 말하는 대기 안내 | "초록불이 곧 끝납니다", "안전하게 건널 시간이 부족합니다", "카메라가 신호등을 찾지 못했습니다" 등 다음 행동을 알려 줌 |
| 실시간 신호 연동 | 서울 T-Data C-ITS API로 교차로 방향별 보행신호 색과 잔여시간(0.1초 단위)을 받아 통신 지연만큼 다시 계산 |
| 카메라 신호등 판독 | 딥러닝 없이 HSV 색 검출 + 형태 검증 + 상태 머신으로 빨강·초록·점멸을 오프라인 판독 |
| 옷깃 클립 카메라 | XIAO ESP32S3 Sense가 신호등을 찍어 Wi-Fi로 전송. 두 손이 자유로움 |
| 이상 상태 감지 | 오래된 데이터, 멈춘 카메라, 재부팅된 기기, 순서가 뒤바뀐 사진을 잡아내 "확인 불가"로 처리 |
| GPS 교차로 선택 | 가장 가까운 지원 교차로를 찾고, 방향은 큰 버튼으로 선택(스크린리더 지원) |
| 펌웨어 시뮬레이터 | 실기기 없이 앱을 끝까지 검증. 사진 멈춤·촬영 실패·재부팅·지연 등 7가지 고장 주입 |

<br>

## 🛠 기술 스택

- **언어**: Dart, Python, C++ (Arduino)
- **프레임워크 / 라이브러리**: Flutter 3.35, OpenCV, package:image, flutter_tts, geolocator, ESP32 Arduino core 3.3
- **하드웨어**: Seeed XIAO ESP32S3 Sense (OV2640 카메라)
- **데이터**: 서울 T-Data 신호제어기 신호 잔여시간 정보서비스(C-ITS)
- **도구**: Git, GitHub Actions(CI), arduino-cli, VS Code

<br>

## 👥 팀원

| <img src="https://github.com/daniellim2022.png" width="100"> | <img src="https://github.com/깃허브아이디.png" width="100"> |
| :--: | :--: |
| [daniellim2022](https://github.com/daniellim2022) | [이름](https://github.com/깃허브아이디) |
| 앱·판정 엔진·신호 데이터 연동·카메라 프로그램 | 하드웨어 조립·현장 측정·발표 |

<br>

## ▶️ 실행 방법

```bash
# 1. 저장소 받기
git clone https://github.com/daniellim2022/ClipSense.git
cd ClipSense

# 2. 모바일 앱 (T-Data API 키 필요, 키는 코드에 넣지 말고 실행할 때 주입)
cd app
flutter pub get
flutter test
flutter run --dart-define=TDATA_KEY='발급받은_API_키'

# 2-1. 옷깃 클립 카메라를 쓸 때 (같은 Wi-Fi의 카메라 주소)
flutter run --dart-define=TDATA_KEY='...' --dart-define=CLIP_CAM_HOST=192.168.0.42

# 3. 실기기 없이 펌웨어 시뮬레이터로 확인
cd ..
python3 scripts/clip_cam_sim.py              # 가짜 클립 카메라 실행
python3 scripts/check_clip_cam_contract.py   # 카메라 통신 규칙 24개 검사

# 4. Python 부스 데모 (웹캠 한 대로 오프라인 시연)
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
./run_demo.sh                    # Windows: run_demo.bat
.venv/bin/python scripts/run_unit_tests.py
```

펌웨어 빌드와 업로드는 [firmware/README.md](firmware/README.md), 앱의 카메라 조준·접근성은 [app/README.md](app/README.md)를 참고해 주세요.

<br>

## 📁 폴더 구조

```
.
├── app/                      # Flutter 모바일 앱
│   ├── lib/
│   │   ├── app/              # 화면, 판정 루프(GuidanceController), GPS 교차로 선택
│   │   ├── signals/          # T-Data API, 이중 검증 판정(judge)
│   │   ├── vision/           # 색 검출, 상태 머신, 잔여시간 숫자 판독
│   │   ├── camera/           # 폰 카메라 입력
│   │   ├── clip/             # 옷깃 클립 카메라 연동(스냅샷·신선도 검사)
│   │   └── feedback/         # 음성(TTS)·진동 안내
│   └── test/                 # 자동 테스트 578개 + 골든 테스트 데이터
├── firmware/clipsense_cam/   # XIAO ESP32S3 클립 카메라 펌웨어
├── scripts/                  # 시뮬레이터, 계약 검사, 측정·테스트 스크립트
├── main.py, detector.py ...  # Python 부스 데모와 판정 모듈
├── assets/voice/             # 오프라인 안내 음성
├── .github/workflows/ci.yml  # Python·Flutter·펌웨어 자동 검증
└── README.md
```

<br>

## ✅ 현재 상태

| 구분 | 상태 |
| :-- | :-- |
| 모바일 앱, 판정 엔진 | 구현 완료, 자동 테스트 578개 통과 |
| 서울 T-Data 연동 | 실제 API 호출로 신호색·잔여시간 확인 |
| 카메라 판독 | 실제 신호등 영상 1편과 변형 영상, 합성 영상으로 검증 |
| 클립 카메라 펌웨어 | 구현·컴파일 완료, **실기기 미검증** |
| 사용자 현장 테스트 | **미실시** (다음 단계) |

<br>

## 🤝 협업 규칙

- **브랜치**
  - `develop`: 개발용 기본 브랜치. 모든 작업은 여기서 시작해요.
  - `feat/기능이름`, `fix/버그이름`: `develop`에서 만들어서 작업하고, PR로 `develop`에 합쳐요.
  - `main`: 발표나 배포할 때만 `develop`을 합쳐요.
- **커밋 메시지**: `feat: 로그인 기능 추가`, `fix: 버튼 클릭 오류 수정`, `docs: README 수정`
- **비밀값**: T-Data API 키, 클립 카메라 토큰, `firmware/secrets.h`는 절대 커밋하지 않아요. 실행할 때 `--dart-define`이나 환경변수로 넣어요.
- **안전 규칙**: 판정 규칙(`judge`)을 바꾸는 PR은 골든 테스트(`judge_cases.json`)가 통과해야 합쳐요.
