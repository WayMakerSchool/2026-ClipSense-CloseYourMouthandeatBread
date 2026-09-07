// 클립 프레임 신선도·진행 추적기. 규칙(하드웨어 보고서 §10.4·§11.3):
//   conservativeAgeMs = rttMs + serverFrameAgeMs
//   capturedAtMonoMs  = receivedMonoMs - conservativeAgeMs
//   새 frameSeq일 때만 관측 갱신 / 같은 프레임은 신선도를 갱신하지 않음 /
//   sequence 역전은 replayOrReorder(고수위 유지) / bootId 변경은 이력 즉시 폐기.
import 'package:clip_sense/clip/clip_freshness.dart';
import 'package:clip_sense/clip/clip_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

ClipCaptureMeta meta({
  int seq = 1,
  int capture = 1000000,
  int response = 1012000,
  String boot = 'boot-a',
}) => ClipCaptureMeta(
  frameSeq: seq,
  captureUptimeUs: capture,
  responseUptimeUs: response,
  bootId: boot,
);

void main() {
  test('첫 프레임은 accepted, 보수적 나이 = rtt + 서버 프레임 나이', () {
    final t = ClipFreshnessTracker();
    final o = t.observe(meta(), rttMs: 84, receivedMonoMs: 5000);
    expect(o.verdict, ClipFrameVerdict.accepted);
    expect(o.bootChanged, isFalse);
    expect(o.conservativeAgeMs, 84 + 12);
    expect(o.capturedAtMonoMs, 5000 - 96);
  });

  test('같은 frameSeq·같은 촬영시각은 sameFrame — 신선도 갱신 없음', () {
    final t = ClipFreshnessTracker();
    t.observe(meta(), rttMs: 10, receivedMonoMs: 1000);
    final o = t.observe(meta(), rttMs: 10, receivedMonoMs: 3000);
    expect(o.verdict, ClipFrameVerdict.sameFrame);
    expect(o.capturedAtMonoMs, isNull);
  });

  test('frameSeq가 증가하고 촬영시각도 증가하면 accepted', () {
    final t = ClipFreshnessTracker();
    t.observe(
      meta(seq: 1, capture: 100, response: 100),
      rttMs: 0,
      receivedMonoMs: 0,
    );
    final o = t.observe(
      meta(seq: 2, capture: 250000, response: 251000),
      rttMs: 5,
      receivedMonoMs: 300,
    );
    expect(o.verdict, ClipFrameVerdict.accepted);
    expect(o.capturedAtMonoMs, 300 - 5 - 1);
  });

  group('replayOrReorder', () {
    test('frameSeq 역전', () {
      final t = ClipFreshnessTracker();
      t.observe(meta(seq: 5, capture: 500), rttMs: 0, receivedMonoMs: 0);
      final o = t.observe(
        meta(seq: 4, capture: 600),
        rttMs: 0,
        receivedMonoMs: 10,
      );
      expect(o.verdict, ClipFrameVerdict.replayOrReorder);
      expect(o.capturedAtMonoMs, isNull);
    });

    test('frameSeq는 증가했는데 촬영시각이 뒤로 가면(같은 boot) 거부', () {
      final t = ClipFreshnessTracker();
      t.observe(
        meta(seq: 5, capture: 500, response: 500),
        rttMs: 0,
        receivedMonoMs: 0,
      );
      final o = t.observe(
        meta(seq: 6, capture: 400, response: 400),
        rttMs: 0,
        receivedMonoMs: 10,
      );
      expect(o.verdict, ClipFrameVerdict.replayOrReorder);
    });

    test('같은 frameSeq인데 촬영시각이 다르면(원자성 위반) 거부', () {
      final t = ClipFreshnessTracker();
      t.observe(
        meta(seq: 5, capture: 500, response: 500),
        rttMs: 0,
        receivedMonoMs: 0,
      );
      final o = t.observe(
        meta(seq: 5, capture: 900, response: 900),
        rttMs: 0,
        receivedMonoMs: 10,
      );
      expect(o.verdict, ClipFrameVerdict.replayOrReorder);
    });

    test('거부된 프레임은 고수위를 낮추지 않는다(다음 정상 프레임 기준 유지)', () {
      final t = ClipFreshnessTracker();
      t.observe(
        meta(seq: 5, capture: 500, response: 500),
        rttMs: 0,
        receivedMonoMs: 0,
      );
      t.observe(
        meta(seq: 3, capture: 300, response: 300),
        rttMs: 0,
        receivedMonoMs: 10,
      );
      // seq 4는 고수위(5)보다 낮으므로 여전히 거부.
      expect(
        t
            .observe(
              meta(seq: 4, capture: 400, response: 400),
              rttMs: 0,
              receivedMonoMs: 20,
            )
            .verdict,
        ClipFrameVerdict.replayOrReorder,
      );
      expect(
        t
            .observe(
              meta(seq: 6, capture: 600, response: 600),
              rttMs: 0,
              receivedMonoMs: 30,
            )
            .verdict,
        ClipFrameVerdict.accepted,
      );
    });
  });

  group('bootId 변경', () {
    test('이력을 즉시 폐기하고 새 boot의 첫 프레임을 accepted로 받는다', () {
      final t = ClipFreshnessTracker();
      t.observe(
        meta(seq: 900, capture: 90000000, response: 90000000, boot: 'a'),
        rttMs: 0,
        receivedMonoMs: 0,
      );
      // 재부팅: seq·uptime 모두 0 근처로 돌아온다 — 역전이 아니라 새 이력.
      final o = t.observe(
        meta(seq: 1, capture: 1000, response: 1000, boot: 'b'),
        rttMs: 0,
        receivedMonoMs: 100,
      );
      expect(o.verdict, ClipFrameVerdict.accepted);
      expect(o.bootChanged, isTrue);
      expect(o.capturedAtMonoMs, 100);
    });

    test('uptime 역행만으로는 리셋하지 않는다(bootId 같으면 거부)', () {
      final t = ClipFreshnessTracker();
      t.observe(
        meta(seq: 900, capture: 90000000, response: 90000000),
        rttMs: 0,
        receivedMonoMs: 0,
      );
      final o = t.observe(
        meta(seq: 901, capture: 1000, response: 1000),
        rttMs: 0,
        receivedMonoMs: 100,
      );
      expect(o.verdict, ClipFrameVerdict.replayOrReorder);
      expect(o.bootChanged, isFalse);
    });
  });

  test('음수 rtt는 0으로 보고(시계 오류), 나이를 줄이지 않는다', () {
    final t = ClipFreshnessTracker();
    final o = t.observe(meta(), rttMs: -50, receivedMonoMs: 1000);
    expect(o.conservativeAgeMs, 12);
    expect(o.capturedAtMonoMs, 988);
  });

  test('reset() 뒤에는 어떤 프레임이든 첫 프레임처럼 받는다', () {
    final t = ClipFreshnessTracker();
    t.observe(
      meta(seq: 5, capture: 500, response: 500),
      rttMs: 0,
      receivedMonoMs: 0,
    );
    t.reset();
    final o = t.observe(
      meta(seq: 2, capture: 200, response: 200),
      rttMs: 0,
      receivedMonoMs: 10,
    );
    expect(o.verdict, ClipFrameVerdict.accepted);
    expect(o.bootChanged, isFalse);
  });

  test('accepted 관측만 lastAccepted에 남는다', () {
    final t = ClipFreshnessTracker();
    expect(t.lastAccepted, isNull);
    t.observe(
      meta(seq: 1, capture: 100, response: 100),
      rttMs: 0,
      receivedMonoMs: 0,
    );
    expect(t.lastAccepted?.frameSeq, 1);
    t.observe(
      meta(seq: 1, capture: 100, response: 100),
      rttMs: 0,
      receivedMonoMs: 5,
    );
    t.observe(
      meta(seq: 0, capture: 50, response: 50),
      rttMs: 0,
      receivedMonoMs: 6,
    );
    expect(t.lastAccepted?.frameSeq, 1);
  });
}
