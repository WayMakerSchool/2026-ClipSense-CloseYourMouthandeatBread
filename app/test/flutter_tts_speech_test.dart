import 'package:clip_sense/feedback/speech_output.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// 플랫폼 채널 대신 호출만 기록하는 FlutterTts. 생성자는 채널 핸들러만 등록하므로
/// 테스트 바인딩만 있으면 하드웨어 없이 만들 수 있다.
class _RecordingTts extends FlutterTts {
  final List<String> calls = [];
  String? language;
  bool? sharedInstance;
  IosTextToSpeechAudioCategory? category;
  List<IosTextToSpeechAudioCategoryOptions>? options;
  IosTextToSpeechAudioMode? mode;

  /// null이 아니면 모든 설정 호출이 이 에러로 실패한다.
  final Object? failWith;

  _RecordingTts({this.failWith});

  Future<dynamic> _record(String name) async {
    calls.add(name);
    if (failWith != null) throw failWith!;
    return 1;
  }

  @override
  Future<dynamic> setLanguage(String language) {
    this.language = language;
    return _record('setLanguage');
  }

  @override
  Future<dynamic> setSharedInstance(bool sharedSession) {
    sharedInstance = sharedSession;
    return _record('setSharedInstance');
  }

  @override
  Future<dynamic> setIosAudioCategory(
    IosTextToSpeechAudioCategory category,
    List<IosTextToSpeechAudioCategoryOptions> options, [
    IosTextToSpeechAudioMode mode = IosTextToSpeechAudioMode.defaultMode,
  ]) {
    this.category = category;
    this.options = options;
    this.mode = mode;
    return _record('setIosAudioCategory');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('기존 동작 고정: 생성 시 ko-KR 로케일을 설정한다', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final tts = _RecordingTts();
    expect(FlutterTtsSpeech(tts), isA<SpeechOutput>());
    await pumpEventQueue();
    expect(tts.language, 'ko-KR');
  });

  test('iOS: 무음 스위치를 무시하는 playback 세션을 켠다', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final tts = _RecordingTts();
    FlutterTtsSpeech(tts);
    await pumpEventQueue();

    expect(tts.sharedInstance, isTrue);
    expect(tts.category, IosTextToSpeechAudioCategory.playback);
    expect(tts.mode, IosTextToSpeechAudioMode.voicePrompt);
    expect(
      tts.options,
      contains(IosTextToSpeechAudioCategoryOptions.duckOthers),
    );
    // 카테고리를 정한 뒤 세션을 활성화해야 playback이 적용된 상태로 켜진다.
    expect(
      tts.calls.indexOf('setIosAudioCategory'),
      lessThan(tts.calls.indexOf('setSharedInstance')),
    );
  });

  test('Android: iOS 전용 오디오 세션 API를 호출하지 않는다', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final tts = _RecordingTts();
    FlutterTtsSpeech(tts);
    await pumpEventQueue();

    expect(tts.sharedInstance, isNull);
    expect(tts.category, isNull);
    expect(tts.calls, ['setLanguage']);
  });

  test('iOS 세션 설정 실패는 삼켜 앱을 죽이지 않는다', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final tts = _RecordingTts(
      failWith: PlatformException(code: 'audio_session'),
    );
    expect(() => FlutterTtsSpeech(tts), returnsNormally);
    // 삼키지 않은 Future 에러가 있으면 flutter_test가 이 테스트를 실패시킨다.
    await pumpEventQueue();
    expect(tts.calls, contains('setIosAudioCategory'));
  });
}
