/**
 * Regression test for the S8 review fix: 시나리오 모드 재생 시 트레이스의
 * 고정 앵커(BASE_EPOCH/BASE_MONO) timestamp를 실제 clock과 그대로 비교하면
 * age가 수백만 ms로 튀어 CITS_STALE/VISION_STALE에 영구 고정되는 버그가
 * 있었다. computeReplayOffset/reanchorTick이 이를 실제로 고치는지, 순수
 * 함수 레벨에서 shield를 구동해 검증한다 (App.jsx의 useEffect 배선과
 * 동일한 재앵커링 로직 — 헤드리스로 재현 가능).
 */
import { describe, it, expect } from 'vitest'
import { buildTrace } from '../../src/experiments/faultScenarios.js'
import { createRuntimeShield } from '../../src/safety/runtimeShield.js'
import { computeReplayOffset, reanchorTick } from '../../src/ui/traceReplayClock.js'

// App.jsx의 safety tick과 동일하게 "실제 지금"을 한 번 고정해 재생 전체에
// 사용한다 (재생이 실시간보다 훨씬 빨리 도는 테스트 환경에서도 매 tick
// 100ms씩 증가한다고 가정 — 실제 setInterval 없이 shield를 직접 구동).
function driveTrace(scenarioId, { realNowEpochMs = Date.now(), realNowMonoMs = 10_000_000 } = {}) {
  const trace = buildTrace(scenarioId)
  const offset = computeReplayOffset(trace.ticks[0].clock, {
    nowEpochMs: realNowEpochMs,
    nowMonoMs: realNowMonoMs,
  })
  const shield = createRuntimeShield()
  const outputs = []

  for (const tick of trace.ticks) {
    const { cits, vision } = reanchorTick(tick, offset)
    // safety tick은 항상 "진짜 지금"으로 clock을 만든다 — 여기서는 트레이스
    // tick 간격(TICK_MS)만큼 실시간이 흘렀다고 시뮬레이션한다(App.jsx의
    // 100ms setInterval과 동일 카덴스).
    const clock = {
      nowEpochMs: realNowEpochMs + tick.tickIndex * 100,
      nowMonoMs: realNowMonoMs + tick.tickIndex * 100,
    }
    const out = shield.update({
      target: tick.target,
      cits,
      vision,
      user: tick.user,
      crosswalk: tick.crosswalk,
      clock,
    })
    outputs.push(out)
  }

  return outputs
}

describe('traceReplayClock — reanchorTick fixes real-clock vs trace-anchor mismatch', () => {
  it('NORMAL_GREEN: 재앵커링 후 shield가 SIGNAL_CONFIRMED에 도달한다', () => {
    const outputs = driveTrace('NORMAL_GREEN')
    const confirmedIndex = outputs.findIndex((o) => o.decision === 'SIGNAL_CONFIRMED')
    expect(confirmedIndex).toBeGreaterThan(-1)
    // 회귀 방지: 재앵커링 이전 버그는 전 tick이 CITS_STALE/VISION_STALE WAIT였다.
    const staleReasons = new Set(['CITS_STALE', 'VISION_STALE'])
    expect(outputs.every((o) => staleReasons.has(o.reason))).toBe(false)
    // 확정 이후에는 계속 SIGNAL_CONFIRMED를 유지해야 한다(정상 시나리오).
    expect(outputs.slice(confirmedIndex).every((o) => o.decision === 'SIGNAL_CONFIRMED')).toBe(true)
  })

  it('NORMAL_GREEN: 재앵커링 없이(트레이스 원본 clock 무시하고 진짜 clock만 쓰면) 영구 WAIT/stale이 재현된다 — 버그 재현 대조군', () => {
    const trace = buildTrace('NORMAL_GREEN')
    const shield = createRuntimeShield()
    const realNowEpochMs = Date.now()
    const realNowMonoMs = 10_000_000
    const outputs = trace.ticks.map((tick) =>
      shield.update({
        target: tick.target,
        cits: tick.cits, // 재앵커링 안 함 — 트레이스 고정 앵커 그대로
        vision: tick.vision,
        user: tick.user,
        crosswalk: tick.crosswalk,
        clock: { nowEpochMs: realNowEpochMs + tick.tickIndex * 100, nowMonoMs: realNowMonoMs + tick.tickIndex * 100 },
      })
    )
    expect(outputs.some((o) => o.decision === 'SIGNAL_CONFIRMED')).toBe(false)
    expect(outputs.every((o) => o.reason === 'CITS_STALE' || o.reason === 'VISION_STALE')).toBe(true)
  })

  it('WRONG_TARGET_GREEN: 재앵커링 후에도 전 구간 non-proceed + TARGET_MISMATCH가 대표 사유다', () => {
    const outputs = driveTrace('WRONG_TARGET_GREEN')
    expect(outputs.every((o) => o.decision !== 'SIGNAL_CONFIRMED')).toBe(true)
    expect(outputs.every((o) => o.reason === 'TARGET_MISMATCH')).toBe(true)
    expect(outputs.every((o) => o.failedChecks.includes('TARGET_MISMATCH'))).toBe(true)
  })

  it('mediaTimeMs는 재앵커링으로 변형되지 않는다 (clock과 비교되지 않는 상대값)', () => {
    const trace = buildTrace('NORMAL_GREEN')
    const offset = computeReplayOffset(trace.ticks[0].clock, { nowEpochMs: 9_999_999_999, nowMonoMs: 5_000_000 })
    const { vision } = reanchorTick(trace.ticks[5], offset)
    expect(vision.mediaTimeMs).toBe(trace.ticks[5].vision.mediaTimeMs)
    expect(vision.frameSeq).toBe(trace.ticks[5].vision.frameSeq)
  })

  it('루프 재시작(tick 0 재방문) 시점에 offset을 다시 잡으면 futureClockToleranceMs 초과 없이 재확정된다', () => {
    // 트레이스를 두 바퀴 재생하면서, 바퀴가 바뀔 때마다 App.jsx와 동일하게
    // offset을 그 순간 "지금"으로 재계산한다.
    const trace = buildTrace('NORMAL_GREEN')
    const shield = createRuntimeShield()
    let realNowEpochMs = Date.now()
    let realNowMonoMs = 20_000_000
    let offset = computeReplayOffset(trace.ticks[0].clock, { nowEpochMs: realNowEpochMs, nowMonoMs: realNowMonoMs })

    const outputs = []
    const LAPS = 2
    for (let lap = 0; lap < LAPS; lap++) {
      if (lap > 0) {
        // 두 번째 바퀴 시작 — 실시간은 계속 앞으로 흐르고, 트레이스는 tick 0으로 되돌아간다.
        realNowEpochMs += trace.ticks.length * 100
        realNowMonoMs += trace.ticks.length * 100
        offset = computeReplayOffset(trace.ticks[0].clock, { nowEpochMs: realNowEpochMs, nowMonoMs: realNowMonoMs })
      }
      for (const tick of trace.ticks) {
        const { cits, vision } = reanchorTick(tick, offset)
        const clock = {
          nowEpochMs: realNowEpochMs + tick.tickIndex * 100,
          nowMonoMs: realNowMonoMs + tick.tickIndex * 100,
        }
        outputs.push(
          shield.update({ target: tick.target, cits, vision, user: tick.user, crosswalk: tick.crosswalk, clock })
        )
      }
    }

    // 두 번째 바퀴에서도 CITS_STALE/VISION_STALE(미래 clock 초과로 인한
    // 재발)에 갇히지 않고 다시 SIGNAL_CONFIRMED에 도달해야 한다.
    const secondLap = outputs.slice(trace.ticks.length)
    expect(secondLap.some((o) => o.decision === 'SIGNAL_CONFIRMED')).toBe(true)
  })
})
