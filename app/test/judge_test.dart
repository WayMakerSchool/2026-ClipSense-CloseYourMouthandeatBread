import 'package:flutter_test/flutter_test.dart';
import 'package:clip_sense/signals/signal_reading.dart';
import 'package:clip_sense/signals/judge.dart';

SignalReading api(
  SignalColor color, {
  double? remain = 30.0,
  int fresh = 100,
}) => SignalReading(color, remain, SignalSource.api, freshMs: fresh);
SignalReading vis(SignalColor color, {double? remain, int fresh = 100}) =>
    SignalReading(color, remain, SignalSource.vision, freshMs: fresh);

void main() {
  test('둘 다 초록 → walk', () {
    expect(
      decide(api(SignalColor.green, remain: 30), vis(SignalColor.green)),
      Decision.walk,
    );
  });

  test('API초록·비전빨강 → wait', () {
    expect(decide(api(SignalColor.green), vis(SignalColor.red)), Decision.wait);
  });
  test('API빨강·비전초록 → wait', () {
    expect(decide(api(SignalColor.red), vis(SignalColor.green)), Decision.wait);
  });
  test('API초록·비전점멸 → wait', () {
    expect(
      decide(api(SignalColor.green), vis(SignalColor.clearance)),
      Decision.wait,
    );
  });
  test('API점멸·비전초록 → wait', () {
    expect(
      decide(api(SignalColor.clearance), vis(SignalColor.green)),
      Decision.wait,
    );
  });

  test('둘 다 빨강 → wait', () {
    expect(decide(api(SignalColor.red), vis(SignalColor.red)), Decision.wait);
  });

  test('잔여 부족 → wait', () {
    expect(
      decide(
        api(SignalColor.green, remain: 3.0),
        vis(SignalColor.green),
        needSec: 7.0,
      ),
      Decision.wait,
    );
  });

  test('잔여 정보 없음 → wait', () {
    expect(
      decide(
        api(SignalColor.green, remain: null),
        vis(SignalColor.green, remain: null),
        needSec: 7.0,
      ),
      Decision.wait,
    );
  });

  test('한쪽 stale → wait', () {
    expect(
      decide(
        api(SignalColor.green, remain: 30, fresh: 5000),
        vis(SignalColor.green),
        staleMs: 2000,
      ),
      Decision.wait,
    );
  });

  test('둘 다 unknown → unknown', () {
    expect(
      decide(
        api(SignalColor.unknown, remain: null),
        vis(SignalColor.unknown, remain: null),
      ),
      Decision.unknown,
    );
  });

  test('비전 단독 초록 → walk (allowSingleSource)', () {
    expect(
      decide(null, vis(SignalColor.green, remain: 30), allowSingleSource: true),
      Decision.walk,
    );
  });

  test('단일 소스 비허용 → wait', () {
    expect(
      decide(
        null,
        vis(SignalColor.green, remain: 30),
        allowSingleSource: false,
      ),
      Decision.wait,
    );
  });

  test('비전 단독 빨강 → wait', () {
    expect(
      decide(null, vis(SignalColor.red), allowSingleSource: true),
      Decision.wait,
    );
  });

  test('둘 다 null → unknown', () {
    expect(decide(null, null), Decision.unknown);
  });

  test('단일 소스 초록·잔여없음 → wait', () {
    expect(
      decide(
        null,
        vis(SignalColor.green, remain: null),
        allowSingleSource: true,
      ),
      Decision.wait,
    );
  });

  // 안전 정책(사용자 확정): 기본 엄격 — 카메라 unknown이면 API 초록도 wait
  test('기본: 비전 unknown이면 API 초록이어도 wait', () {
    expect(
      decide(
        api(SignalColor.green, remain: 30),
        vis(SignalColor.unknown, remain: null),
      ),
      Decision.wait,
    );
  });
  test('기본: API unknown이면 비전 초록이어도 wait', () {
    expect(
      decide(
        api(SignalColor.unknown, remain: null),
        vis(SignalColor.green, remain: 30),
      ),
      Decision.wait,
    );
  });
  test('기본: 비전 stale이면 API 초록이어도 wait', () {
    expect(
      decide(
        api(SignalColor.green, remain: 30),
        vis(SignalColor.green, remain: 30, fresh: 5000),
      ),
      Decision.wait,
    );
  });
  test('기본: API null이면 비전 초록이어도 wait', () {
    expect(decide(null, vis(SignalColor.green, remain: 30)), Decision.wait);
  });

  group('판정 근거', () {
    test('둘 다 초록이지만 잔여 부족이면 이유를 보존한다', () {
      final result = evaluate(
        api(SignalColor.green, remain: 3),
        vis(SignalColor.green),
      );
      expect(result.decision, Decision.wait);
      expect(result.reason, DecisionReason.remainingInsufficient);
    });

    test('API와 비전 색이 다르면 불일치 이유다', () {
      final result = evaluate(api(SignalColor.green), vis(SignalColor.red));
      expect(result.decision, Decision.wait);
      expect(result.reason, DecisionReason.conflict);
    });

    test('API 없음·카메라 초록(엄격) → wait, 이유는 API 불가', () {
      final result = evaluate(null, vis(SignalColor.green, remain: 30));
      expect(result.decision, Decision.wait);
      expect(result.reason, DecisionReason.apiUnavailable);
    });
  });

  // 한쪽 소스만 불가일 때 이유를 소스별로 나눈다 — 실기기에서 카메라 미인식과
  // API 미응답이 같은 문구로 들리면 사용자가 무엇을 고쳐야 할지(신호등을 향할지,
  // 그냥 기다릴지) 알 수 없다. 결정은 그대로 wait(안전 정책 불변).
  group('소스별 불가 이유 (엄격 모드)', () {
    test('API 초록·카메라 unknown → wait, 카메라 불가', () {
      final result = evaluate(
        api(SignalColor.green, remain: 30),
        vis(SignalColor.unknown, remain: null),
      );
      expect(result.decision, Decision.wait);
      expect(result.reason, DecisionReason.cameraUnavailable);
    });

    test('API 초록·카메라 없음(null) → wait, 카메라 불가', () {
      final result = evaluate(api(SignalColor.green, remain: 30), null);
      expect(result.decision, Decision.wait);
      expect(result.reason, DecisionReason.cameraUnavailable);
    });

    test('API 초록·카메라 stale → wait, 카메라 불가', () {
      final result = evaluate(
        api(SignalColor.green, remain: 30),
        vis(SignalColor.green, remain: 30, fresh: 5000),
      );
      expect(result.decision, Decision.wait);
      expect(result.reason, DecisionReason.cameraUnavailable);
    });

    test('API 빨강·카메라 unknown → wait, 카메라 불가 (API 색과 무관)', () {
      final result = evaluate(
        api(SignalColor.red, remain: null),
        vis(SignalColor.unknown, remain: null),
      );
      expect(result.decision, Decision.wait);
      expect(result.reason, DecisionReason.cameraUnavailable);
    });

    test('카메라 초록·API unknown → wait, API 불가', () {
      final result = evaluate(
        api(SignalColor.unknown, remain: null),
        vis(SignalColor.green, remain: 30),
      );
      expect(result.decision, Decision.wait);
      expect(result.reason, DecisionReason.apiUnavailable);
    });

    test('카메라 초록·API stale → wait, API 불가', () {
      final result = evaluate(
        api(SignalColor.green, remain: 30, fresh: 5000),
        vis(SignalColor.green, remain: 30),
      );
      expect(result.decision, Decision.wait);
      expect(result.reason, DecisionReason.apiUnavailable);
    });

    test('allowSingleSource=true면 소스 불가 이유가 아니라 단일 소스 판정', () {
      final result = evaluate(
        api(SignalColor.green, remain: 30),
        vis(SignalColor.unknown, remain: null),
        allowSingleSource: true,
      );
      expect(result.decision, Decision.walk);
      expect(result.reason, DecisionReason.ready);
    });

    // 문구는 마침표 없이 두고 화면·음성이 조합 시 마침표를 붙인다(기존 이유
    // 문구 관례). 조합 결과에 지정 문구가 글자 그대로 들어가는지는
    // speech_text_test·guidance_screen_test가 고정한다.
    test('문구: 카메라 불가 → 신호등을 향하라는 안내', () {
      expect(
        decisionReasonText(DecisionReason.cameraUnavailable),
        '카메라가 신호등을 찾지 못했습니다. 신호등을 향해 주세요',
      );
    });

    test('문구: API 불가 → 신호 정보를 아직 못 받음', () {
      expect(
        decisionReasonText(DecisionReason.apiUnavailable),
        '신호 정보를 아직 받지 못했습니다',
      );
    });
  });

  // 카메라 권한 거부는 "신호등을 향하라"로는 못 고친다 — 설정에서 허용해야
  // 한다. 이 이유는 judge가 아니라 컨트롤러가 VisionSource 상태를 보고 매핑한다
  // (evaluate는 판독값만 보므로 권한 여부를 알 수 없고, 판정 로직은 불변).
  group('카메라 권한 거부 이유', () {
    test('문구: 설정에서 카메라를 허용하라는 안내(끝 마침표 없음)', () {
      expect(
        decisionReasonText(DecisionReason.cameraDenied),
        '카메라 권한이 없습니다. 설정에서 카메라를 허용해 주세요',
      );
    });

    // 컨트롤러가 소스 상태를 보고 바꿔 넣는 이유들. judge 는 판독값만 보므로 이
    // 값을 만들 수 없어야 한다(만들면 "설정을 확인하라"가 엉뚱한 상황에 나온다).
    const controllerOnlyReasons = {
      DecisionReason.cameraDenied,
      DecisionReason.clipUnreachable,
      DecisionReason.clipTokenRejected,
      DecisionReason.cameraStarting,
      DecisionReason.cameraStalled,
      DecisionReason.apiKeyMissing,
    };

    test(
      'evaluate는 컨트롤러 전용 이유(cameraDenied·clipUnreachable·clipTokenRejected·cameraStarting·cameraStalled·apiKeyMissing)를 절대 반환하지 않는다',
      () {
        const colors = SignalColor.values;
        final readings = <SignalReading?>[null];
        for (final color in colors) {
          for (final remain in [null, 3.0, 30.0]) {
            for (final fresh in [0, 5000]) {
              readings.add(api(color, remain: remain, fresh: fresh));
              readings.add(vis(color, remain: remain, fresh: fresh));
            }
          }
        }
        for (final a in readings) {
          for (final v in readings) {
            for (final single in [false, true]) {
              final result = evaluate(a, v, allowSingleSource: single);
              expect(
                controllerOnlyReasons.contains(result.reason),
                isFalse,
                reason:
                    '${result.reason} api=$a vision=$v allowSingleSource=$single',
              );
            }
          }
        }
      },
    );
  });

  group('비정상 수치 fail-safe', () {
    test('NaN·Infinity·음수 잔여시간은 walk 근거가 아니다', () {
      for (final malformed in [double.nan, double.infinity, -1.0]) {
        final result = evaluate(
          api(SignalColor.green, remain: malformed),
          vis(SignalColor.green),
        );
        expect(result.decision, Decision.wait);
        expect(result.reason, DecisionReason.remainingUnavailable);
      }
    });

    test('음수 신선도는 사용할 수 없는 판정이다 (API 쪽이 빠짐)', () {
      final result = evaluate(
        api(SignalColor.green, remain: 30, fresh: -1),
        vis(SignalColor.green, remain: 30),
      );
      expect(result.decision, Decision.wait);
      expect(result.reason, DecisionReason.apiUnavailable);
    });
  });

  group('잔여시간 출처 정책 (카메라 숫자는 거부권만)', () {
    test('API 잔여 없음이면 카메라 숫자만으로 walk 하지 않는다', () {
      final result = evaluate(
        api(SignalColor.green, remain: null),
        vis(SignalColor.green, remain: 20),
      );
      expect(result.decision, Decision.wait);
      expect(result.reason, DecisionReason.remainingUnavailable);
    });

    test('API 잔여 충분해도 카메라 숫자가 더 짧으면 wait', () {
      final result = evaluate(
        api(SignalColor.green, remain: 20),
        vis(SignalColor.green, remain: 3),
      );
      expect(result.decision, Decision.wait);
      expect(result.reason, DecisionReason.remainingInsufficient);
    });

    test('API 잔여 충분·카메라 숫자 없음 → walk', () {
      final result = evaluate(
        api(SignalColor.green, remain: 20),
        vis(SignalColor.green, remain: null),
      );
      expect(result.decision, Decision.walk);
      expect(result.reason, DecisionReason.ready);
    });
  });

  test('문구: 카메라 준비 중 / 영상 정지(끝 마침표 없음 — 화면·음성이 조합)', () {
    expect(decisionReasonText(DecisionReason.cameraStarting), '카메라를 준비하는 중입니다');
    expect(
      decisionReasonText(DecisionReason.cameraStalled),
      '카메라 영상이 멈췄습니다. 화면을 두 번 눌러 다시 시작해 주세요',
    );
  });
}
