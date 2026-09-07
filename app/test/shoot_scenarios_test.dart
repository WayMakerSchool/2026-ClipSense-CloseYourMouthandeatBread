// 시연 영상 6장면 대본을 코드로 재현한다. 현장에서 그 장면을 만들었을 때 실제로
// 어떤 음성이 나오는지를 촬영 전에 고정하는 테스트다 — 대본과 코드가 어긋난 채
// 현장에 나가는 것을 막는 것이 목적.
//
// 장면(현장 체크리스트 STEP 4와 같은 순서):
//   1 둘 다 초록          → "지금 건너셔도 됩니다" + 잔여 초
//   2 초록 중 렌즈 가림    → 카메라만 사라짐 → "카메라가 신호등을 찾지 못했습니다"
//   3 초록 중 인터넷 끊김  → API만 사라짐   → "신호 정보를 아직 받지 못했습니다"
//   4 초록 점멸          → "초록불이 곧 끝납니다"
//   5 잔여 7초 미만       → "안전하게 건널 시간이 부족합니다"
//   6 빨간불             → "빨간불입니다"
// 추가: 카메라 권한 거부 / 탭으로 정지 / 클립 카메라 전원 꺼짐(연결 불가) / 클립 토큰 불일치
//       / 시작 직후 준비 중 / 카메라 정지(다시 시작 안내).
import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/app/guidance_controller.dart';
import 'package:clip_sense/camera/camera_vision_source.dart';
import 'package:clip_sense/feedback/feedback_controller.dart';
import 'package:clip_sense/feedback/haptic_output.dart';
import 'package:clip_sense/feedback/speech_output.dart';
import 'package:clip_sense/signals/judge.dart';
import 'package:clip_sense/signals/signal_reading.dart';

class _Speech implements SpeechOutput {
  final List<String> spoken = [];
  @override
  Future<void> speak(String text) async => spoken.add(text);
}

class _Haptic implements HapticOutput {
  final List<Decision> played = [];
  @override
  Future<void> play(Decision d) async => played.add(d);
}

/// 현장에서 조작하는 두 축(카메라가 보는 색 / 소스 상태)을 그대로 흉내 낸다.
class _Vision implements VisionSource {
  SignalReading reading;
  @override
  VisionSourceStatus status;
  @override
  VisionDiagnostics? diagnostics;

  _Vision(this.reading, {this.status = VisionSourceStatus.streaming});

  @override
  SignalReading get latestReading => reading;
  @override
  CameraController? get previewController => null;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
}

SignalReading _api(SignalColor color, {double? remain, int fresh = 0}) =>
    SignalReading(color, remain, SignalSource.api, freshMs: fresh);
SignalReading _cam(SignalColor color, {int fresh = 0}) =>
    SignalReading(color, null, SignalSource.vision, freshMs: fresh);

void main() {
  late _Speech speech;
  late _Haptic haptic;

  /// 한 장면을 실행하고, 그 장면에서 나온 마지막 음성을 돌려준다.
  Future<String> scene({
    required SignalReading api,
    required SignalReading camera,
    VisionSourceStatus status = VisionSourceStatus.streaming,
  }) async {
    final vision = _Vision(camera, status: status);
    final controller = GuidanceController(
      feedback: FeedbackController(speech, haptic),
      itstId: '1537',
      direction: 'ne',
      vision: vision,
      fetch: (itstId, direction, apiKey, {required nowMs}) async => api,
    );
    await controller.tickOnce();
    controller.dispose();
    return speech.spoken.last;
  }

  setUp(() {
    speech = _Speech();
    haptic = _Haptic();
  });

  test('장면 1: API·카메라 둘 다 초록, 잔여 15초 → 건너세요', () async {
    final said = await scene(
      api: _api(SignalColor.green, remain: 15),
      camera: _cam(SignalColor.green),
    );
    expect(said, contains('지금 건너셔도 됩니다'));
    expect(said, contains('15'));
    expect(haptic.played.last, Decision.walk);
  });

  test('장면 2: 초록 중 렌즈를 가리면 카메라 이유로 대기', () async {
    final said = await scene(
      api: _api(SignalColor.green, remain: 15),
      camera: _cam(SignalColor.unknown),
    );
    expect(said, contains('카메라가 신호등을 찾지 못했습니다'));
    expect(said, contains('기다리세요'));
    expect(haptic.played.last, Decision.wait);
  });

  test('장면 3: 초록 중 인터넷이 끊기면 API 이유로 대기', () async {
    final said = await scene(
      api: _api(SignalColor.unknown),
      camera: _cam(SignalColor.green),
    );
    expect(said, contains('신호 정보를 아직 받지 못했습니다'));
    expect(said, contains('기다리세요'));
  });

  test('장면 4: 초록 점멸 → 곧 끝난다고 안내', () async {
    final said = await scene(
      api: _api(SignalColor.clearance, remain: 4),
      camera: _cam(SignalColor.clearance),
    );
    expect(said, contains('초록불이 곧 끝납니다'));
  });

  test('장면 5: 잔여 7초 미만이면 시간 부족으로 대기', () async {
    final said = await scene(
      api: _api(SignalColor.green, remain: 5),
      camera: _cam(SignalColor.green),
    );
    expect(said, contains('안전하게 건널 시간이 부족합니다'));
  });

  test('장면 6: 둘 다 빨강 → 빨간불', () async {
    final said = await scene(
      api: _api(SignalColor.red),
      camera: _cam(SignalColor.red),
    );
    expect(said, contains('빨간불입니다'));
  });

  test('추가: 카메라 권한 거부는 설정 안내로 구분해 말한다', () async {
    final said = await scene(
      api: _api(SignalColor.green, remain: 15),
      camera: _cam(SignalColor.unknown),
      status: VisionSourceStatus.permissionDenied,
    );
    expect(said, contains('카메라 권한이 없습니다'));
    expect(said, contains('설정에서 카메라를 허용해'));
  });

  test('추가: 클립 카메라 전원이 꺼지면(연결 불가) 전원·Wi-Fi 확인 안내로 대기', () async {
    final said = await scene(
      api: _api(SignalColor.green, remain: 15),
      camera: _cam(SignalColor.unknown),
      status: VisionSourceStatus.unreachable,
    );
    expect(said, contains('클립 카메라에 연결할 수 없습니다'));
    expect(said, contains('기다리세요'));
    expect(haptic.played.last, Decision.wait);
  });

  test('추가: 클립 카메라 토큰이 틀리면 설정 확인 안내로 대기("향해 주세요"라고 하지 않음)', () async {
    final vision = _Vision(
      _cam(SignalColor.unknown),
      status: VisionSourceStatus.failed,
    )..diagnostics = const VisionDiagnostics(lastReason: 'token_rejected');
    final controller = GuidanceController(
      feedback: FeedbackController(speech, haptic),
      itstId: '1537',
      direction: 'ne',
      vision: vision,
      fetch: (itstId, direction, apiKey, {required nowMs}) async =>
          _api(SignalColor.green, remain: 15),
    );
    await controller.tickOnce();
    controller.dispose();
    expect(speech.spoken.last, contains('기기 토큰 설정을 확인해 주세요'));
    expect(speech.spoken.last, isNot(contains('향해 주세요')));
    expect(haptic.played.last, Decision.wait);
  });

  test('추가: 시작 직후 첫 안내는 준비 중("향해 주세요" 아님)', () async {
    final said = await scene(
      api: _api(SignalColor.green, remain: 15),
      camera: _cam(SignalColor.unknown),
      status: VisionSourceStatus.starting,
    );
    expect(said, '카메라를 준비하는 중입니다. 기다리세요');
    expect(haptic.played.last, Decision.wait);
  });

  test('추가: 카메라가 멈추면 다시 시작 안내', () async {
    final said = await scene(
      api: _api(SignalColor.green, remain: 15),
      camera: _cam(SignalColor.unknown),
      status: VisionSourceStatus.stalled,
    );
    expect(said, '카메라 영상이 멈췄습니다. 화면을 두 번 눌러 다시 시작해 주세요. 기다리세요');
    expect(said, isNot(contains('향해 주세요')));
    expect(haptic.played.last, Decision.wait);
  });

  test('추가: 촬영 중 화면을 탭해 정지하면 멈췄다고 말한다', () async {
    final vision = _Vision(_cam(SignalColor.green));
    final controller = GuidanceController(
      feedback: FeedbackController(speech, haptic),
      itstId: '1537',
      direction: 'ne',
      vision: vision,
      fetch: (itstId, direction, apiKey, {required nowMs}) async =>
          _api(SignalColor.green, remain: 15),
    );
    controller.start();
    await controller.tickOnce();
    expect(speech.spoken.last, contains('지금 건너셔도 됩니다'));

    controller.stop();
    await Future<void>.delayed(Duration.zero);
    expect(speech.spoken.last, kStoppedSpeechText);
    expect(speech.spoken.last, contains('안내를 멈췄습니다'));
    controller.dispose();
  });

  test('안전 회귀: 카메라가 초록이어도 API 잔여가 없으면 건너라고 하지 않는다', () async {
    final said = await scene(
      api: _api(SignalColor.green), // 잔여 null
      camera: _cam(SignalColor.green),
    );
    expect(said, isNot(contains('건너셔도')));
    expect(said, contains('남은 시간을 확인할 수 없습니다'));
  });
}
