/**
 * 시나리오 트레이스 재앵커링 (스펙 §2.10 — 시나리오 모드는 buildTrace()를
 * 실시간으로 재생하지만, safety tick은 항상 실제 clock을 쓴다).
 *
 * 문제: faultScenarios.js의 트레이스 timestamp는 고정 앵커
 * (BASE_EPOCH=1784780000000 / BASE_MONO=1_000_000) 기준이다. safety tick이
 * 매번 `Date.now()`/`performance.now()`로 만드는 진짜 clock과 그대로
 * 비교하면 citsSourceAgeMs/citsReceiveAgeMs/visionAgeMs가 수백만~십억 ms로
 * 계산되어 CITS_STALE/VISION_STALE에 영구 고정된다(재현 버그, 리뷰 지적).
 *
 * 해법: 트레이스 재생을 시작하는 실시간 순간에 offset(실시간 − 트레이스
 * 시각)을 한 번 계산해 두고, 매 tick의 관측값을 복사할 때 offset을 더해
 * "지금 막 도착한 관측"처럼 보이게 만든다. safety tick 자체는 계속 실제
 * clock을 쓰므로, 재생이 멈추면(모드 전환 등) age가 자연히 증가해 WAIT로
 * 강등되는 스펙 §2.10 속성이 그대로 보존된다 — tick.clock을 그대로 쓰는
 * 방식은 이 속성을 깨뜨리므로 채택하지 않는다.
 *
 * 어떤 필드에 offset을 더하는가: clock(nowEpochMs/nowMonoMs)과 직접
 * 비교되는 timestamp만이 대상이다 (safeGraphChecks.js 참조):
 *   - cits.sourceEpochMs    (vs clock.nowEpochMs → citsSourceAgeMs)
 *   - cits.receivedAtMonoMs (vs clock.nowMonoMs  → citsReceiveAgeMs)
 *   - vision.capturedAtMonoMs (vs clock.nowMonoMs → visionAgeMs)
 * `vision.mediaTimeMs`와 `seq`/`frameSeq`는 runtimeShield 안에서 서로 다른
 * tick끼리만 비교되고(단조 증가/정지 판정, videoAdvancing) clock과는 전혀
 * 비교되지 않으므로 offset을 더하지 않고 트레이스 원본 값 그대로 둔다 —
 * 균등한 트레이스 내부 간격을 그대로 유지해야 STALE_CITS_GREEN의 "얼어붙은
 * sourceEpochMs", FROZEN_GREEN_VIDEO의 "얼어붙은 mediaTimeMs" 같은 결함
 * 시맨틱이 보존된다.
 */

/**
 * @param {{ nowEpochMs: number, nowMonoMs: number }} traceStartClock trace.ticks[0].clock
 * @param {{ nowEpochMs: number, nowMonoMs: number }} [realClock] 기본값은 실제 clock
 * @returns {{ epochOffsetMs: number, monoOffsetMs: number }}
 */
export function computeReplayOffset(traceStartClock, realClock = { nowEpochMs: Date.now(), nowMonoMs: performance.now() }) {
  return {
    epochOffsetMs: realClock.nowEpochMs - traceStartClock.nowEpochMs,
    monoOffsetMs: realClock.nowMonoMs - traceStartClock.nowMonoMs,
  }
}

/**
 * 트레이스 tick 하나의 cits/vision 관측을 재앵커링한 얕은 복사본으로
 * 변환한다. target/user/crosswalk/groundTruth/tickIndex는 시간과 무관하므로
 * 손대지 않는다(호출측이 그대로 재사용).
 * @param {object} tick trace.ticks[i]
 * @param {{ epochOffsetMs: number, monoOffsetMs: number }} offset
 * @returns {{ cits: object, vision: object }}
 */
export function reanchorTick(tick, offset) {
  const { epochOffsetMs, monoOffsetMs } = offset
  return {
    cits: {
      ...tick.cits,
      sourceEpochMs: tick.cits.sourceEpochMs + epochOffsetMs,
      receivedAtMonoMs: tick.cits.receivedAtMonoMs + monoOffsetMs,
    },
    vision: {
      ...tick.vision,
      capturedAtMonoMs: tick.vision.capturedAtMonoMs + monoOffsetMs,
      // mediaTimeMs는 의도적으로 미변경 — 위 파일 헤더 주석 참조.
    },
  }
}
