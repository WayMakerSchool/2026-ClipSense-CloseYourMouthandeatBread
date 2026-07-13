import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/signals/judge.dart';
import 'package:clip_sense/feedback/speech_output.dart';

void main() {
  test('walk 문구', () {
    expect(speechText(Decision.walk), '지금 건너셔도 됩니다');
  });

  test('walk + 잔여시간(반올림 정수 초)', () {
    expect(speechText(Decision.walk, remainSec: 15.0),
        '지금 건너셔도 됩니다, 15초 남았습니다');
  });

  test('walk 잔여시간 반올림', () {
    expect(speechText(Decision.walk, remainSec: 14.6),
        '지금 건너셔도 됩니다, 15초 남았습니다');
  });

  test('wait 문구', () {
    expect(speechText(Decision.wait), '기다리세요');
  });

  test('unknown 문구에 행동 지시(대기) 포함', () {
    final text = speechText(Decision.unknown);
    expect(text, '신호를 확인할 수 없습니다. 대기하세요');
    expect(text.contains('대기'), isTrue);
  });

  test('walk가 아니면 remainSec 무시', () {
    expect(speechText(Decision.wait, remainSec: 15.0), '기다리세요');
    expect(speechText(Decision.unknown, remainSec: 15.0),
        '신호를 확인할 수 없습니다. 대기하세요');
  });
}
