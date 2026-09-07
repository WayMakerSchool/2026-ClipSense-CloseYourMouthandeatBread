import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/signals/judge.dart';
import 'package:clip_sense/feedback/speech_output.dart';

void main() {
  test('walk 문구', () {
    expect(speechText(Decision.walk), '지금 건너셔도 됩니다');
  });

  test('walk + 잔여시간(반올림 정수 초)', () {
    expect(
      speechText(Decision.walk, remainSec: 15.0),
      '지금 건너셔도 됩니다, 15초 남았습니다',
    );
  });

  test('walk 잔여시간 반올림', () {
    expect(
      speechText(Decision.walk, remainSec: 14.6),
      '지금 건너셔도 됩니다, 15초 남았습니다',
    );
  });

  test('wait 문구', () {
    expect(speechText(Decision.wait), '기다리세요');
  });

  test('wait는 판정 근거를 함께 안내한다', () {
    expect(
      speechText(Decision.wait, reason: DecisionReason.remainingInsufficient),
      '안전하게 건널 시간이 부족합니다. 기다리세요',
    );
  });

  // 한쪽 소스 불가 — 지정 문구(마침표 포함)가 글자 그대로 들어간다.
  test('wait + 카메라 불가: 신호등을 향하라는 안내', () {
    expect(
      speechText(Decision.wait, reason: DecisionReason.cameraUnavailable),
      '카메라가 신호등을 찾지 못했습니다. 신호등을 향해 주세요. 기다리세요',
    );
  });

  // 권한 거부는 사용자가 설정에서 고쳐야 한다 — 미인식 문구와 구분해서 말한다.
  test('wait + 카메라 권한 거부: 설정에서 허용하라는 안내', () {
    expect(
      speechText(Decision.wait, reason: DecisionReason.cameraDenied),
      '카메라 권한이 없습니다. 설정에서 카메라를 허용해 주세요. 기다리세요',
    );
  });

  test('wait + API 불가: 신호 정보를 아직 못 받음', () {
    expect(
      speechText(Decision.wait, reason: DecisionReason.apiUnavailable),
      '신호 정보를 아직 받지 못했습니다. 기다리세요',
    );
  });

  // 정지 안내(탭·백그라운드). 전맹 사용자는 멈춘 것을 화면으로 알 수 없다.
  test('정지 안내 문구(글자 그대로 고정)', () {
    expect(kStoppedSpeechText, '안내를 멈췄습니다. 다시 시작하려면 화면을 한 번 누르세요.');
  });

  test('API 키 누락은 일반 신호 장애와 구분한다', () {
    expect(
      speechText(Decision.unknown, reason: DecisionReason.apiKeyMissing),
      'T-Data API 키가 설정되지 않았습니다. 대기하세요',
    );
  });

  test('unknown 문구에 행동 지시(대기) 포함', () {
    final text = speechText(Decision.unknown);
    expect(text, '신호를 확인할 수 없습니다. 대기하세요');
    expect(text.contains('대기'), isTrue);
  });

  test('walk가 아니면 remainSec 무시', () {
    expect(speechText(Decision.wait, remainSec: 15.0), '기다리세요');
    expect(
      speechText(Decision.unknown, remainSec: 15.0),
      '신호를 확인할 수 없습니다. 대기하세요',
    );
  });

  test('wait + 클립 카메라 연결 불가 → 이유를 먼저 말한다', () {
    expect(
      speechText(Decision.wait, reason: DecisionReason.clipUnreachable),
      '클립 카메라에 연결할 수 없습니다. 전원과 Wi-Fi 연결을 확인해 주세요. 기다리세요',
    );
  });
}
