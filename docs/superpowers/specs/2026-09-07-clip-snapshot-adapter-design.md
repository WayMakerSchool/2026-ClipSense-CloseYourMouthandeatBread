# 클립 카메라 Snapshot Adapter 설계·검증 기록 (2026-09-07)

## 왜 이 조각인가

2026-09-01 펌웨어 설계서의 "다음 단계 3. 판정 계층에 Snapshot Adapter 연결"이
비어 있었다. 펌웨어는 `/capture`로 JPEG과 신선도 헤더를 내보내는데, 앱은 폰
카메라만 썼다 — 작품명의 "Clip"이 판정에 닿지 않는 상태. 이 조각으로
`CLIP_CAM_HOST`를 주면 클립 카메라 스냅샷이 T-Data와 엄격 AND로 결합된다.

같은 세션에서 먼저 고친 안전 결함: 컨트롤러가 요청 **전** 시각으로 API 신선도와
잔여시간을 판정해, 응답이 늦으면(타임아웃 5초) 오래된 값이 "2초 이내"로 통과하고
잔여시간이 과대평가됐다. 판정 직전에 fetch 소요 시간만큼 다시 늙힌다
(`SignalReading.aged`, `kStaleMs` 명시).

**범위 밖:** 실기기(폰·보드) 실행, 왕복 시간·fps·인식 거리 측정, HSV 재튜닝,
mDNS 해석, 설정 화면, 펌웨어 시뮬레이터(다음 조각), Python 미러.

## 구성 (`app/lib/clip/`, 폰 카메라와 판정 코드를 공유)

```
/capture ──ClipSnapshotClient──▶ ClipFetchOk(meta, jpeg, rtt) | ClipFetchFailed(failure)
                                        │
                     ClipFreshnessTracker.observe(meta, rtt, receivedMono)
                                        │ accepted / sameFrame / replayOrReorder (+bootChanged)
                     decodeJpegToRoiBgr(jpeg, kClipRoiFrac=0.25)   ← image 패키지(순수 Dart)
                                        │
                     VisionPipeline.process(roi, t = captureUptimeUs/1e6)   ← 폰 카메라와 동일
                                        │
                     ClipVisionSource.latestReading (freshMs = mono − capturedAtMono)
                                        ▼
                     GuidanceController → judge.evaluate(api, vision, staleMs: kStaleMs)
```

| 파일 | 역할 |
|---|---|
| `clip_contract.dart` | 헤더 이름·경로·schemaVersion (펌웨어 `http_api.cpp`와 같은 문자열) |
| `clip_snapshot.dart` | `parseClipHeaders` → `ClipCaptureMeta` 또는 null. 대소문자 무시, 십진 숫자만, uint64, `response < capture` 거부, 서버 나이는 올림 |
| `clip_freshness.dart` | `ClipFreshnessTracker`: 새 frameSeq·촬영시각 증가만 accepted, 같은 프레임은 신선도 미갱신, 역전은 거부(고수위 유지), bootId 변경만 이력 폐기 |
| `clip_snapshot_client.dart` | 요청마다 `http.Client` 생성·close(타임아웃이 소켓을 실제로 끊음), 401/403·409·503·매체타입·헤더·본문 분류, 던지지 않음 |
| `jpeg_frame.dart` | `decodeJpegToRoiBgr` (실패 → null) |
| `clip_vision_source.dart` | `VisionSource` 구현. 250ms 순차 폴링, 상태·진단, `clipBaseUri` |
| `app/vision_source_factory.dart` | `CLIP_CAM_HOST` 비면 폰 카메라, 잘못된 host는 throw |
| `vision/vision_pipeline.dart` | 검출→상태머신→숫자→판독 추출(폰·클립 공용, 손상 프레임은 리셋 후 rethrow) |

## 안전 규칙

- 판정 규칙(`judge.evaluate`)은 손대지 않았다. 새 상태는 전부 wait/unknown 으로만 간다.
- `freshMs` = 폰 단조 시계 − (수신 시각 − rtt − 서버 프레임 나이). 같은 frameSeq는
  신선도를 갱신하지 않으므로 정지한 카메라는 2초 뒤 judge에서 탈락하고, 소스도
  판독을 지우고 파이프라인을 리셋한다.
- accepted가 아닌 모든 결과(409·503·timeout·transport·헤더/매체/본문 불량·역전·
  디코드 실패·손상 프레임)는 판독 unknown + 파이프라인 리셋 → 정전 뒤 정상 프레임
  한 장으로 GREEN이 부활하지 않는다(디바운스 8장 재통과, 약 2초).
- 상태머신 시각은 기기 촬영 uptime(같은 bootId 안에서 단조 증가). 수신·처리 시각은
  점멸 판정에 쓰지 않는다.
- 401/403 → `failed` + `token_rejected`, 폴링 중단, 음성 "기기 토큰 설정을 확인해
  주세요"(`DecisionReason.clipTokenRejected`). timeout/transport → `unreachable`,
  음성 "전원과 Wi-Fi 연결을 확인해 주세요"(`clipUnreachable`). 결정은 둘 다 wait.
- 잔여시간 기준은 여전히 API. 80x60 ROI에서는 7세그 숫자를 읽지 못하므로 클립
  경로는 잔여 거부권을 내지 않는다.

## ROI 실측 (기본값 0.25의 근거)

`scripts/dump_clip_qvga_fixture.py`: 실클립(1280x720)을 중앙 4:3(960x720)으로 잘라
INTER_AREA로 320x240, cv2 JPEG q80. 프레임 20(점등)·34(점멸 소등).

| ROI | 20 점등 | 34 소등 | 판단 |
|---|---|---|---|
| 1.0 (320x240) | no_blob 0.40% | no_blob 0.36% | 전체 프레임은 임계 0.5%를 못 넘음 |
| 0.5 (160x120) | GREEN 1.12% | **GREEN 0.82%** | 소등을 초록으로 읽음 → 점멸 놓침, 불가 |
| 0.25 (80x60) | GREEN 3.40% | NONE 0.00% | 채택 |

`scripts/measure_clip_frame_size.py`(16:9를 눌러 줄인 84프레임 전수)는 0.5가 더 많은
프레임을 잡지만(59/84 vs 42/84) 위 소등 결과 때문에 채택하지 않았다. 옷깃 카메라는
조준이 없으므로 0.25는 램프가 크롭 밖으로 나가는 프레임이 늘어난다 — 못 보면
대기(안전 방향). 보드 확보 후 VGA+50% 프로필과 함께 다시 측정한다.

## 검증 표

| 항목 | 상태 |
|---|---|
| 헤더 파서·신선도 추적기 단위 테스트 | 통과 (MockClient·소문자 키 포함) |
| 스냅샷 클라이언트 루프백 `dart:io` HttpServer 왕복 (ok/503/응답 없음→타임아웃 후 복구) | 통과 |
| JPEG 코덱 왕복(실클립 ROI, MAE<4, GREEN 유지) | 통과 |
| QVGA fixture 기하(위 표) | 통과 |
| ClipVisionSource 시나리오(정지·503·409·역전·재부팅·토큰·응답없음·디코드 실패·stop 늦은 응답·루프 비중첩) | 통과 |
| 컨트롤러⊕클립 통합(8장→walk, 정지→2초 뒤 wait, 응답없음→연결 확인 음성, 재부팅, API 빨강) | 통과 |
| 촬영 대본 장면(클립 전원 꺼짐·토큰 불일치) | 통과 |
| 폰 카메라 경로 회귀(파이프라인 추출 전후 동일) | 통과 |
| Android 평문 http · iOS 로컬 네트워크 · macOS 엔타이틀먼트 | **작성만, 실기기 미검증** |
| 실제 보드 `/capture` JPEG(OV2640/OV3660)·RTT·fps·인식 거리·발열 | **미측정** |
| 폰 실행(권한·TTS·TalkBack) | **미검증** |

## 다음 조각

1. `scripts/clip_cam_sim.py` — 표준 라이브러리 HTTP 서버로 펌웨어 계약을 흉내(QVGA
   전체 프레임 JPEG, 503/정지/재부팅/토큰 오류 주입) → 앱 끝단·macOS 스모크.
2. 카메라 정지 감시(폰·클립 공용 `stalled` 상태와 "카메라 영상이 멈췄습니다" 안내).
3. Python 미러(`clip_snapshot.py`, 신선도 골든 JSON을 Dart와 공유, 부스 데모 `--clip-host`).
4. 덱·보고서 정합(클립 어댑터 구현 반영, 테스트 수, "차량 소리 감지" 표기 제거).
5. 펌웨어: bootId 엔트로피(RF 초기화 전 `esp_random()`) 보강 검토.
