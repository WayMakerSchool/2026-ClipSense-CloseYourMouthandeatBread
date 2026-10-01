import { describe, it, expect } from 'vitest'
import {
  TICK_MS,
  DURATION_MS,
  SCENARIOS,
  SCENARIO_IDS,
  buildTrace,
} from '../../src/experiments/faultScenarios.js'
import {
  validateTargetContext,
  validateCitsObservation,
  validateVisionObservation,
  validateClock,
} from '../../src/safety/contracts.js'
import { createRuntimeShield } from '../../src/safety/runtimeShield.js'

const EXPECTED_RISK_CLASS = {
  NORMAL_GREEN: 'SAFE',
  SINGLE_FALSE_GREEN: 'PHYSICAL',
  TIME_SHORT: 'PHYSICAL',
  TRUE_GREEN_TO_RED: 'PHYSICAL',
  PERSISTENT_COMMON_CAUSE: 'PHYSICAL',
  WRONG_TARGET_GREEN: 'CONTRACT',
  STALE_CITS_GREEN: 'CONTRACT',
  REORDERED_PACKET: 'CONTRACT',
  FROZEN_GREEN_VIDEO: 'CONTRACT',
  CAMERA_OCCLUDED: 'CONTRACT',
  TARGET_SWITCH_MID_CONFIRM: 'CONTRACT',
}

describe('faultScenarios — module constants', () => {
  it('TICK_MS is 100 and DURATION_MS is 10000', () => {
    expect(TICK_MS).toBe(100)
    expect(DURATION_MS).toBe(10000)
  })

  it('SCENARIO_IDS lists exactly the 11 scenarios from 원본 §12 with correct riskClass', () => {
    expect([...SCENARIO_IDS].sort()).toEqual(Object.keys(EXPECTED_RISK_CLASS).sort())
    expect(SCENARIO_IDS.length).toBe(11)
    for (const id of SCENARIO_IDS) {
      expect(SCENARIOS[id].riskClass).toBe(EXPECTED_RISK_CLASS[id])
      expect(typeof SCENARIOS[id].label).toBe('string')
      expect(SCENARIOS[id].label.length).toBeGreaterThan(0)
      expect(typeof SCENARIOS[id].description).toBe('string')
      expect(SCENARIOS[id].description.length).toBeGreaterThan(0)
    }
  })
})

describe('faultScenarios — buildTrace() basic shape (all 11 scenarios)', () => {
  for (const id of Object.keys(EXPECTED_RISK_CLASS)) {
    it(`${id}: produces 100 ticks with scenarioId/riskClass metadata`, () => {
      const trace = buildTrace(id)
      expect(trace.scenarioId).toBe(id)
      expect(trace.riskClass).toBe(EXPECTED_RISK_CLASS[id])
      expect(trace.ticks.length).toBe(100)
      trace.ticks.forEach((tick, idx) => {
        expect(tick.tickIndex).toBe(idx)
        expect(typeof tick.clock.nowEpochMs).toBe('number')
        expect(typeof tick.clock.nowMonoMs).toBe('number')
        expect(tick.target).toBeTruthy()
        expect(tick.cits).toBeTruthy()
        expect(tick.vision).toBeTruthy()
        expect(tick.user).toEqual({ walkingSpeedMps: 0.6 })
        expect(tick.crosswalk).toEqual({ lengthM: 10, marginSec: 2 })
        expect(typeof tick.groundTruth.unsafe).toBe('boolean')
        expect(typeof tick.groundTruth.faultActive).toBe('boolean')
        expect(
          tick.groundTruth.faultType === null || typeof tick.groundTruth.faultType === 'string'
        ).toBe(true)
      })
    })
  }

  it('unknown scenarioId throws', () => {
    expect(() => buildTrace('NOT_A_SCENARIO')).toThrow()
  })
})

describe('faultScenarios — determinism', () => {
  for (const id of Object.keys(EXPECTED_RISK_CLASS)) {
    it(`${id}: two buildTrace() calls deep-equal`, () => {
      expect(buildTrace(id)).toEqual(buildTrace(id))
    })
  }
})

describe('faultScenarios — NORMAL_GREEN passes S1 contract validators (spot-check tick 0/50/99)', () => {
  const trace = buildTrace('NORMAL_GREEN')
  for (const idx of [0, 50, 99]) {
    it(`tick ${idx} passes all four validators`, () => {
      const tick = trace.ticks[idx]
      expect(validateTargetContext(tick.target).ok).toBe(true)
      expect(validateCitsObservation(tick.cits).ok).toBe(true)
      expect(validateVisionObservation(tick.vision).ok).toBe(true)
      expect(validateClock(tick.clock).ok).toBe(true)
    })
  }

  it('groundTruth.unsafe is false for every tick', () => {
    for (const tick of trace.ticks) {
      expect(tick.groundTruth.unsafe).toBe(false)
      expect(tick.groundTruth.faultActive).toBe(false)
    }
  })
})

describe('faultScenarios — normal-scenario cits/vision advance freshly (sourceEpoch/seq/frameSeq strictly increase)', () => {
  it('NORMAL_GREEN: cits.seq is non-decreasing and increases at least once across the trace; sourceEpochMs strictly increases per tick that updates', () => {
    const trace = buildTrace('NORMAL_GREEN')
    const seqs = trace.ticks.map((t) => t.cits.seq)
    const sourceEpochs = trace.ticks.map((t) => t.cits.sourceEpochMs)
    for (let i = 1; i < seqs.length; i++) {
      expect(seqs[i]).toBeGreaterThanOrEqual(seqs[i - 1])
    }
    expect(seqs[99]).toBeGreaterThan(seqs[0])
    for (let i = 1; i < sourceEpochs.length; i++) {
      expect(sourceEpochs[i]).toBeGreaterThan(sourceEpochs[i - 1])
    }
  })

  it('NORMAL_GREEN: vision.frameSeq strictly increases every tick, mediaTimeMs strictly increases every tick', () => {
    const trace = buildTrace('NORMAL_GREEN')
    for (let i = 1; i < trace.ticks.length; i++) {
      expect(trace.ticks[i].vision.frameSeq).toBeGreaterThan(trace.ticks[i - 1].vision.frameSeq)
      expect(trace.ticks[i].vision.mediaTimeMs).toBeGreaterThan(trace.ticks[i - 1].vision.mediaTimeMs)
      expect(trace.ticks[i].vision.capturedAtMonoMs).toBeGreaterThan(
        trace.ticks[i - 1].vision.capturedAtMonoMs
      )
    }
  })

  it('NORMAL_GREEN: all sourceMode fields are MOCK (cits and vision) per spec default (스펙 §2.7: "sourceMode 전부 MOCK")', () => {
    const trace = buildTrace('NORMAL_GREEN')
    for (const tick of trace.ticks) {
      expect(tick.cits.sourceMode).toBe('MOCK')
      expect(tick.vision.sourceMode).toBe('MOCK')
    }
  })
})

describe('faultScenarios — groundTruth fault windows match documented onsets', () => {
  it('WRONG_TARGET_GREEN: unsafe=true for every tick, cits target IDs AND vision.roiBindingId differ from target throughout (원본 §12 "C-ITS/ROI가 초록")', () => {
    const trace = buildTrace('WRONG_TARGET_GREEN')
    for (const tick of trace.ticks) {
      expect(tick.groundTruth.unsafe).toBe(true)
      expect(tick.groundTruth.faultActive).toBe(true)
      const citsMismatched =
        tick.cits.crosswalkId !== tick.target.crosswalkId ||
        tick.cits.movementId !== tick.target.movementId
      expect(citsMismatched).toBe(true)
      expect(tick.vision.roiBindingId).not.toBe(tick.target.roiBindingId)
    }
  })

  it('STALE_CITS_GREEN: cits stops advancing at tick 20 (t=2000ms); unsafe becomes true once source age exceeds 2000ms limit', () => {
    const trace = buildTrace('STALE_CITS_GREEN')
    const frozenSeq = trace.ticks[20].cits.seq
    const frozenSourceEpoch = trace.ticks[20].cits.sourceEpochMs
    for (let i = 21; i < 100; i++) {
      expect(trace.ticks[i].cits.seq).toBe(frozenSeq)
      expect(trace.ticks[i].cits.sourceEpochMs).toBe(frozenSourceEpoch)
    }
    // Before freeze: fresh, unsafe should be false. Once age (nowEpochMs - sourceEpochMs)
    // exceeds maxCitsSourceAgeMs (2000ms), ground truth flips to unsafe.
    expect(trace.ticks[0].groundTruth.unsafe).toBe(false)
    expect(trace.ticks[20].groundTruth.unsafe).toBe(false)
    const staleTick = trace.ticks.find(
      (t) => t.clock.nowEpochMs - t.cits.sourceEpochMs > 2000
    )
    expect(staleTick).toBeTruthy()
    expect(staleTick.groundTruth.unsafe).toBe(true)
    expect(trace.ticks[99].groundTruth.unsafe).toBe(true)
    expect(trace.ticks[99].groundTruth.faultActive).toBe(true)
  })

  it('REORDERED_PACKET: from tick 20 (t=2000ms) a lower-seq packet is injected; unsafe from that tick onward', () => {
    const trace = buildTrace('REORDERED_PACKET')
    for (let i = 0; i < 20; i++) {
      expect(trace.ticks[i].groundTruth.unsafe).toBe(false)
    }
    expect(trace.ticks[20].cits.seq).toBeLessThan(trace.ticks[19].cits.seq)
    for (let i = 20; i < 100; i++) {
      expect(trace.ticks[i].groundTruth.unsafe).toBe(true)
      expect(trace.ticks[i].groundTruth.faultActive).toBe(true)
    }
  })

  it('REORDERED_PACKET: injected seq is STRICTLY decreasing every tick of the fault window (not a constant replay)', () => {
    // A constant repeated seq only fails sequenceValid on the FIRST injected
    // tick — history.lastCitsSeq then latches onto that same value, so
    // `cits.seq < lastCitsSeq` never re-triggers on subsequent ticks. Strict
    // per-tick decrease is required so REPLAY_OR_REORDER fires every tick of
    // the unsafe window (reviewer-caught regression, see task-S5-report.md).
    const trace = buildTrace('REORDERED_PACKET')
    for (let i = 21; i < 100; i++) {
      expect(trace.ticks[i].cits.seq).toBeLessThan(trace.ticks[i - 1].cits.seq)
    }
  })

  it('REORDERED_PACKET: driving the actual runtime shield across the full trace yields ZERO SIGNAL_CONFIRMED in the unsafe window (ticks 20-99)', () => {
    // This is the direct regression test for the reviewer finding: the shield
    // must never re-confirm once reordering starts, because SafeGraph-RTA's
    // expected behavior for this scenario is WAIT (원본 §12 "SafeGraph 예상: WAIT").
    const trace = buildTrace('REORDERED_PACKET')
    const shield = createRuntimeShield()
    let confirmedInUnsafeWindow = 0
    trace.ticks.forEach((tick, i) => {
      const out = shield.update(tick)
      if (i >= 20 && out.decision === 'SIGNAL_CONFIRMED') confirmedInUnsafeWindow++
    })
    expect(confirmedInUnsafeWindow).toBe(0)
  })

  it('FROZEN_GREEN_VIDEO: vision frameSeq/mediaTimeMs freeze at tick 20 (t=2000ms); unsafe once frozen duration exceeds freezeTimeoutMs', () => {
    const trace = buildTrace('FROZEN_GREEN_VIDEO')
    const frozenFrameSeq = trace.ticks[20].vision.frameSeq
    const frozenMediaTime = trace.ticks[20].vision.mediaTimeMs
    for (let i = 21; i < 100; i++) {
      expect(trace.ticks[i].vision.frameSeq).toBe(frozenFrameSeq)
      expect(trace.ticks[i].vision.mediaTimeMs).toBe(frozenMediaTime)
    }
    expect(trace.ticks[20].groundTruth.unsafe).toBe(false)
    expect(trace.ticks[99].groundTruth.unsafe).toBe(true)
    expect(trace.ticks[99].groundTruth.faultActive).toBe(true)
  })

  it('SINGLE_FALSE_GREEN: cits red throughout, vision red except ONE green tick at t=3000ms (tick 30, score .9); unsafe throughout', () => {
    const trace = buildTrace('SINGLE_FALSE_GREEN')
    for (const tick of trace.ticks) {
      expect(tick.cits.color).toBe('red')
      expect(tick.groundTruth.unsafe).toBe(true)
    }
    for (let i = 0; i < 100; i++) {
      if (i === 30) {
        expect(trace.ticks[i].vision.color).toBe('green')
        expect(trace.ticks[i].vision.score).toBe(0.9)
      } else {
        expect(trace.ticks[i].vision.color).toBe('red')
      }
    }
  })

  it('CAMERA_OCCLUDED: vision unknown + quality 0.2 throughout; unsafe throughout', () => {
    const trace = buildTrace('CAMERA_OCCLUDED')
    for (const tick of trace.ticks) {
      expect(tick.vision.color).toBe('unknown')
      expect(tick.vision.quality).toBe(0.2)
      expect(tick.groundTruth.unsafe).toBe(true)
    }
  })

  it('TIME_SHORT: green but remainingSec fixed at 8s; unsafe throughout', () => {
    const trace = buildTrace('TIME_SHORT')
    for (const tick of trace.ticks) {
      expect(tick.cits.color).toBe('green')
      expect(tick.vision.color).toBe('green')
      expect(tick.cits.remainingSec).toBe(8)
      expect(tick.groundTruth.unsafe).toBe(true)
    }
  })

  it('TARGET_SWITCH_MID_CONFIRM: target changes at tick 30 (t=3000ms); unsafe from that tick onward', () => {
    const trace = buildTrace('TARGET_SWITCH_MID_CONFIRM')
    for (let i = 0; i < 30; i++) {
      expect(trace.ticks[i].groundTruth.unsafe).toBe(false)
    }
    expect(trace.ticks[30].target.crosswalkId).not.toBe(trace.ticks[29].target.crosswalkId)
    for (let i = 30; i < 100; i++) {
      expect(trace.ticks[i].groundTruth.unsafe).toBe(true)
      expect(trace.ticks[i].groundTruth.faultActive).toBe(true)
    }
  })

  it('TRUE_GREEN_TO_RED: both flip to red at tick 60 (t=6000ms); unsafe only from the flip', () => {
    const trace = buildTrace('TRUE_GREEN_TO_RED')
    for (let i = 0; i < 60; i++) {
      expect(trace.ticks[i].cits.color).toBe('green')
      expect(trace.ticks[i].vision.color).toBe('green')
      expect(trace.ticks[i].groundTruth.unsafe).toBe(false)
    }
    for (let i = 60; i < 100; i++) {
      expect(trace.ticks[i].cits.color).toBe('red')
      expect(trace.ticks[i].vision.color).toBe('red')
      expect(trace.ticks[i].groundTruth.unsafe).toBe(true)
      expect(trace.ticks[i].groundTruth.faultActive).toBe(true)
    }
  })

  it('PERSISTENT_COMMON_CAUSE: both green, valid target, fresh timestamps for the entire trace, yet unsafe=true throughout (residual-risk case)', () => {
    const trace = buildTrace('PERSISTENT_COMMON_CAUSE')
    for (const tick of trace.ticks) {
      expect(tick.cits.color).toBe('green')
      expect(tick.vision.color).toBe('green')
      expect(tick.cits.crosswalkId).toBe(tick.target.crosswalkId)
      expect(tick.cits.movementId).toBe(tick.target.movementId)
      // fresh timestamps: within configured limits
      expect(tick.clock.nowEpochMs - tick.cits.sourceEpochMs).toBeLessThanOrEqual(2000)
      expect(tick.groundTruth.unsafe).toBe(true)
      expect(tick.groundTruth.faultActive).toBe(true)
    }
  })
})
