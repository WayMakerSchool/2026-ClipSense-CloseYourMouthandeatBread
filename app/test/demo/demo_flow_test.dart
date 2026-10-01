// 시연 하네스 — scripts/run_demo_flow.sh 가 실행한다. 직접 실행할 일은 없다.
//
// 실제 앱 코드 경로를 그대로 쓴다:
//   클립 카메라 시뮬레이터(실제 신호등 프레임) → ClipVisionSource → VisionPipeline
//   → GuidanceController(judge) → FeedbackController(음성 문장)
// 바꾸는 것은 입력뿐이다. API 판독은 DEMO_API 로 고른다.
//   nokey    : 키 미설정 그대로(앱 기본 동작)
//   scripted : 키 없이 쓰는 "가정된 API 값". 초록 20초에서 실제 시간만큼 줄어들다 빨강.
//              출력에 SCRIPTED 로 표시되며 실측값이 아니다.
//   live     : 서울 T-Data 실서버(TDATA_KEY 필요). 2026-10 현재 기존 API 는 5분 1회 제한.
//
// 기본 `flutter test` 에서는 건너뛴다(외부 프로세스 의존).
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:clip_sense/app/guidance_controller.dart';
import 'package:clip_sense/clip/clip_vision_source.dart';
import 'package:clip_sense/feedback/feedback_controller.dart';
import 'package:clip_sense/feedback/haptic_output.dart';
import 'package:clip_sense/feedback/speech_output.dart';
import 'package:clip_sense/signals/judge.dart';
import 'package:clip_sense/signals/signal_reading.dart';
import 'package:flutter_test/flutter_test.dart';

const kSimUrl = String.fromEnvironment('CLIP_SIM_URL');
const kSimToken = String.fromEnvironment('CLIP_SIM_TOKEN');
const kApiMode = String.fromEnvironment('DEMO_API', defaultValue: 'scripted');
const kSeconds = int.fromEnvironment('DEMO_SECONDS', defaultValue: 25);
const kItst = String.fromEnvironment('DEMO_ITST', defaultValue: '1537');
const kDir = String.fromEnvironment('DEMO_DIR', defaultValue: 'ne');
const kLiveKey = String.fromEnvironment('TDATA_KEY');
const kFault = String.fromEnvironment('DEMO_FAULT'); // 예: freeze
const kFaultAt = int.fromEnvironment('DEMO_FAULT_AT', defaultValue: 0);
const kFaultFor = int.fromEnvironment('DEMO_FAULT_FOR', defaultValue: 5);

final Stopwatch _clock = Stopwatch();
String _ts() =>
    '${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(1).padLeft(5)}s';
void _line(String s) => print('│ $s');

class _Speech implements SpeechOutput {
  @override
  Future<void> speak(String text) async => _line('${_ts()}  🔊 "$text"');
}

class _Haptic implements HapticOutput {
  @override
  Future<void> play(Decision d) async {}
}

String _reading(SignalReading? r) {
  if (r == null) return '—';
  final remain = r.remainSec == null
      ? ''
      : ' ${r.remainSec!.toStringAsFixed(1)}s';
  return '${r.color.name}$remain';
}

Future<void> _setFault(Uri base, String mode) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(base.replace(path: '/__sim/fault'));
    final body = utf8.encode(jsonEncode({'mode': mode}));
    req.headers.contentType = ContentType.json;
    req.contentLength = body.length;
    req.add(body);
    await (await req.close()).drain<void>();
  } finally {
    client.close();
  }
}

void main() {
  final enabled = kSimUrl.isNotEmpty && kSimToken.isNotEmpty;

  test(
    'demo flow',
    () async {
      final base = Uri.parse(kSimUrl);
      final vision = ClipVisionSource(baseUrl: base, token: kSimToken);
      _clock.start();

      Future<SignalReading> scripted(
        String itstId,
        String direction,
        String apiKey, {
        required int nowMs,
      }) async {
        final left = 20.0 - _clock.elapsedMilliseconds / 1000.0;
        return SignalReading(
          left > 0 ? SignalColor.green : SignalColor.red,
          left > 0 ? left : null,
          SignalSource.api,
          freshMs: 300,
          raw: 'SCRIPTED',
        );
      }

      final controller = GuidanceController(
        feedback: FeedbackController(_Speech(), _Haptic()),
        itstId: kItst,
        direction: kDir,
        vision: vision,
        fetch: kApiMode == 'scripted' ? scripted : null,
        apiKey: kApiMode == 'live' ? kLiveKey : '',
      );

      final apiLabel = switch (kApiMode) {
        'scripted' => 'API(가정)',
        'live' => 'API(실서버)',
        _ => 'API(키 없음)',
      };
      _line('시간    ${apiLabel.padRight(12)} 카메라            판정      사유');
      controller.addListener(() {
        _line(
          '${_ts()}  ${_reading(controller.lastApiReading).padRight(12)} '
          '${_reading(controller.lastVisionReading).padRight(10)}'
          '[${(controller.visionStatus?.name ?? '-').padRight(9)}] '
          '${controller.decision.name.toUpperCase().padRight(8)} '
          '${decisionReasonText(controller.reason)}',
        );
      });

      controller.start();
      if (kFault.isNotEmpty && kFaultAt > 0) {
        await Future<void>.delayed(Duration(seconds: kFaultAt));
        _line('${_ts()}  ⚡ 장애 주입: $kFault');
        await _setFault(base, kFault);
        await Future<void>.delayed(Duration(seconds: kFaultFor));
        _line('${_ts()}  ⚡ 장애 해제');
        await _setFault(base, 'none');
        final rest = kSeconds - kFaultAt - kFaultFor;
        if (rest > 0) await Future<void>.delayed(Duration(seconds: rest));
      } else {
        await Future<void>.delayed(const Duration(seconds: kSeconds));
      }
      controller.stop();
      await vision.stop();
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: enabled ? false : 'scripts/run_demo_flow.sh 로 실행하는 시연 하네스',
  );
}
