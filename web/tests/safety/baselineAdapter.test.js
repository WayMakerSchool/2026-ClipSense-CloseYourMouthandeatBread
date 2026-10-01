import { describe, it, expect } from 'vitest'
import { createBaselineEngines } from '../../src/safety/baselineAdapter.js'

// ---- tick input builder (mirrors tests/safety/runtimeShield.test.js helper) ----
const TICK_MS = 100
const BASE_MONO = 1_000_000
const BASE_EPOCH = 1784780000000

function makeTargetContext(overrides = {}) {
  return {
    intersectionId: 'demo-int-001',
    crosswalkId: 'demo-cw-north-01',
    movementId: 'demo-ped-move-01',
    direction: 'NORTHBOUND',
    roiBindingId: 'roi-ped-north-01',
    bindingMethod: 'MANUAL_DEMO',
    ...overrides,
  }
}

function makeTick(i, overrides = {}) {
  const nowMonoMs = BASE_MONO + i * TICK_MS
  const nowEpochMs = BASE_EPOCH + i * TICK_MS
  const target = makeTargetContext(overrides.target)

  const cits = {
    available: true,
    color: 'green',
    remainingSec: 35,
    intersectionId: target.intersectionId,
    crosswalkId: target.crosswalkId,
    movementId: target.movementId,
    direction: target.direction,
    sourceEpochMs: nowEpochMs - 200,
    receivedAtMonoMs: nowMonoMs - 100,
    seq: 100 + i,
    sourceMode: 'MOCK',
    ...overrides.cits,
  }

  const vision = {
    color: 'green',
    score: 0.9,
    quality: 0.8,
    roiBindingId: target.roiBindingId,
    capturedAtMonoMs: nowMonoMs - 50,
    frameSeq: 200 + i,
    mediaTimeMs: 5000 + i * TICK_MS,
    sourceMode: 'RECORDED',
    ...overrides.vision,
  }

  const clock = { nowEpochMs, nowMonoMs, ...overrides.clock }
  const user = { walkingSpeedMps: 0.6, ...overrides.user }
  const crosswalk = { lengthM: 10, marginSec: 2, ...overrides.crosswalk }

  return { target, cits, vision, user, crosswalk, clock, ...overrides.top }
}

describe('createBaselineEngines — factory shape', () => {
  it('returns raw and stabilized engines each exposing update()', () => {
    const engines = createBaselineEngines()
    expect(typeof engines.raw.update).toBe('function')
    expect(typeof engines.stabilized.update).toBe('function')
  })
})

describe('createBaselineEngines — dual green 35s (원본 §11, 스펙 §2.6)', () => {
  it('raw engine reaches CROSS/proceedLike=true immediately (tier1, no hold)', () => {
    const { raw } = createBaselineEngines()
    const tick = makeTick(0)
    const out = raw.update(tick, tick.clock.nowMonoMs)
    expect(out.verdict).toBe('CROSS')
    expect(out.reason).toBe('DUAL_GREEN_TIME_OK')
    expect(out.proceedLike).toBe(true)
  })

  it('stabilized engine does NOT reach CROSS before 1500ms of continuous green ticks', () => {
    const { stabilized } = createBaselineEngines()
    let out
    // Ticks at 100ms apart; before 1500ms elapsed since first candidate, must not confirm.
    for (let i = 0; i < 14; i++) {
      const tick = makeTick(i)
      out = stabilized.update(tick, tick.clock.nowMonoMs)
    }
    expect(out.verdict).not.toBe('CROSS')
    expect(out.proceedLike).toBe(false)
  })

  it('stabilized engine reaches CROSS/proceedLike=true once 1500ms of continuous green ticks elapse', () => {
    const { stabilized } = createBaselineEngines()
    let out
    // 16 ticks * 100ms = 1600ms >= 1500ms hold since first candidate tick (index 0 sets candidate).
    for (let i = 0; i < 16; i++) {
      const tick = makeTick(i)
      out = stabilized.update(tick, tick.clock.nowMonoMs)
    }
    expect(out.verdict).toBe('CROSS')
    expect(out.reason).toBe('DUAL_GREEN_TIME_OK')
    expect(out.proceedLike).toBe(true)
  })
})

describe('createBaselineEngines — cits red → both WAIT', () => {
  it('raw engine: cits red → WAIT, proceedLike=false', () => {
    const { raw } = createBaselineEngines()
    const tick = makeTick(0, { cits: { color: 'red' } })
    const out = raw.update(tick, tick.clock.nowMonoMs)
    expect(out.verdict).toBe('WAIT')
    expect(out.proceedLike).toBe(false)
  })

  it('stabilized engine: cits red → WAIT immediately (fail-safe direction is immediate), proceedLike=false', () => {
    const { stabilized } = createBaselineEngines()
    const tick = makeTick(0, { cits: { color: 'red' } })
    const out = stabilized.update(tick, tick.clock.nowMonoMs)
    expect(out.verdict).toBe('WAIT')
    expect(out.proceedLike).toBe(false)
  })

  it('stabilized engine: red arrives after CROSS was confirmed → demotes to WAIT immediately (asymmetric)', () => {
    const { stabilized } = createBaselineEngines()
    let out
    for (let i = 0; i < 16; i++) {
      const tick = makeTick(i)
      out = stabilized.update(tick, tick.clock.nowMonoMs)
    }
    expect(out.verdict).toBe('CROSS')

    const redTick = makeTick(16, { cits: { color: 'red' } })
    out = stabilized.update(redTick, redTick.clock.nowMonoMs)
    expect(out.verdict).toBe('WAIT')
    expect(out.proceedLike).toBe(false)
  })
})

describe('createBaselineEngines — tier mapping (스펙 §2.6)', () => {
  it('cits.available !== true → tier 2 (vision-only path), green+high score → CAUTION not CROSS', () => {
    const { raw } = createBaselineEngines()
    const tick = makeTick(0, { cits: { available: false } })
    const out = raw.update(tick, tick.clock.nowMonoMs)
    // tier 2 dual-green semantics never reach CROSS in decide() — CAUTION at best.
    expect(out.verdict).toBe('CAUTION')
    expect(out.proceedLike).toBe(false)
  })
})

describe('H1 evidence — baseline is blind to target/crosswalk ID mismatch (원본 §12 WRONG_TARGET_GREEN)', () => {
  it('cits/vision report a DIFFERENT crosswalkId/movementId than the bound target, but baseline still reaches CROSS (no ID field ever reaches decide())', () => {
    const { raw } = createBaselineEngines()
    const tick = makeTick(0, {
      target: { crosswalkId: 'demo-cw-north-01', movementId: 'demo-ped-move-01' },
      cits: { crosswalkId: 'ADJACENT-cw-east-02', movementId: 'ADJACENT-ped-move-02' },
    })
    const out = raw.update(tick, tick.clock.nowMonoMs)
    expect(out.verdict).toBe('CROSS')
    expect(out.proceedLike).toBe(true)
  })

  it('stabilized engine also confirms CROSS on a sustained wrong-target trace (target mismatch blindness preserved per 원본 §11.1)', () => {
    const { stabilized } = createBaselineEngines()
    let out
    for (let i = 0; i < 16; i++) {
      const tick = makeTick(i, {
        target: { crosswalkId: 'demo-cw-north-01', movementId: 'demo-ped-move-01' },
        cits: { crosswalkId: 'ADJACENT-cw-east-02', movementId: 'ADJACENT-ped-move-02' },
      })
      out = stabilized.update(tick, tick.clock.nowMonoMs)
    }
    expect(out.verdict).toBe('CROSS')
    expect(out.proceedLike).toBe(true)
  })
})

describe('createBaselineEngines — crossingTime threshold mapping (18.6667 marginSec via crosswalk spread)', () => {
  it('remainingSec just below required (18.6s < 18.667) → WAIT (TIME_SHORT)', () => {
    const { raw } = createBaselineEngines()
    const tick = makeTick(0, { cits: { remainingSec: 18.6 } })
    const out = raw.update(tick, tick.clock.nowMonoMs)
    expect(out.verdict).toBe('WAIT')
    expect(out.reason).toBe('TIME_SHORT')
    expect(out.proceedLike).toBe(false)
  })

  it('remainingSec just above required (18.7s >= 18.667) → CROSS', () => {
    const { raw } = createBaselineEngines()
    const tick = makeTick(0, { cits: { remainingSec: 18.7 } })
    const out = raw.update(tick, tick.clock.nowMonoMs)
    expect(out.verdict).toBe('CROSS')
    expect(out.proceedLike).toBe(true)
  })
})
