import { describe, it, expect, vi } from 'vitest'
import { runScenario } from '../../src/experiments/traceRunner.js'
import { buildTrace } from '../../src/experiments/faultScenarios.js'
import { createBaselineEngines } from '../../src/safety/baselineAdapter.js'
import { createRuntimeShield } from '../../src/safety/runtimeShield.js'

/**
 * Minimal fake engines for schema/spy tests — real engines are exercised in
 * the integration test at the bottom of this file (원본 §14 스키마 + H1 facts).
 */
function makeFakeEngines() {
  const raw = { update: vi.fn(() => ({ verdict: 'CROSS', reason: 'DUAL_GREEN_TIME_OK', proceedLike: true })) }
  const stabilized = {
    update: vi.fn(() => ({ verdict: 'WAIT', reason: 'CONFIRMING', proceedLike: false })),
  }
  const shield = {
    update: vi.fn(() => ({
      decision: 'VERIFYING',
      state: 'CONFIRMING',
      reason: 'CONFIRMING',
      message: 'msg',
      checks: { inputValid: true },
      failedChecks: [],
      ages: { citsSourceAgeMs: 1, citsReceiveAgeMs: 1, visionAgeMs: 1 },
      effectiveRemainingSec: 10,
      requiredCrossingSec: 5,
      confirmation: { distinctGreenFrames: 1, confirmingSinceMonoMs: 100 },
      configVersion: 'safegraph-rta-demo-v1',
    })),
  }
  return { raw, stabilized, shield }
}

describe('runScenario — record schema completeness (원본 §14) on NORMAL_GREEN trace', () => {
  const trace = buildTrace('NORMAL_GREEN')
  const engines = makeFakeEngines()
  const records = runScenario(trace, engines)

  it('returns one record per tick', () => {
    expect(records.length).toBe(trace.ticks.length)
  })

  for (const idx of [0, 50]) {
    it(`tick ${idx}: record has full 원본 §14 schema`, () => {
      const rec = records[idx]
      const tick = trace.ticks[idx]

      expect(rec.schemaVersion).toBe('experiment-log-v1')
      expect(rec.runId).toBe('NORMAL_GREEN-deterministic-run-001')
      expect(rec.scenarioId).toBe('NORMAL_GREEN')
      expect(rec.tickIndex).toBe(idx)
      expect(rec.seed).toBeNull()
      expect(rec.nowEpochMs).toBe(tick.clock.nowEpochMs)
      expect(rec.nowMonoMs).toBe(tick.clock.nowMonoMs)
      expect(rec.groundTruth).toEqual(tick.groundTruth)
      expect(rec.input).toEqual({
        target: tick.target,
        cits: tick.cits,
        vision: tick.vision,
        user: tick.user,
        crosswalk: tick.crosswalk,
      })

      expect(rec.baseline).toEqual({ verdict: 'WAIT', reason: 'CONFIRMING', proceedLike: false })
      expect(rec.baselineRaw).toEqual({
        verdict: 'CROSS',
        reason: 'DUAL_GREEN_TIME_OK',
        proceedLike: true,
      })

      expect(rec.proposed).toEqual({
        decision: 'VERIFYING',
        reason: 'CONFIRMING',
        proceedLike: false,
        checks: { inputValid: true },
      })

      expect(rec.latencyMs).toBeNull()
      expect(rec.configVersion).toBe('safegraph-rta-demo-v1')
    })
  }
})

describe('runScenario — proposed.proceedLike is true only when shield decision is SIGNAL_CONFIRMED', () => {
  it('SIGNAL_CONFIRMED decision maps to proceedLike true', () => {
    const trace = buildTrace('NORMAL_GREEN')
    const engines = makeFakeEngines()
    engines.shield.update = vi.fn(() => ({
      decision: 'SIGNAL_CONFIRMED',
      state: 'SIGNAL_CONFIRMED',
      reason: 'SAFEGRAPH_CONFIRMED',
      message: 'msg',
      checks: {},
      failedChecks: [],
      ages: {},
      effectiveRemainingSec: 10,
      requiredCrossingSec: 5,
      confirmation: { distinctGreenFrames: 5, confirmingSinceMonoMs: 100 },
      configVersion: 'safegraph-rta-demo-v1',
    }))
    const records = runScenario({ ...trace, ticks: [trace.ticks[0]] }, engines)
    expect(records[0].proposed.proceedLike).toBe(true)
  })

  it('baseline.proceedLike is true only when verdict is CROSS', () => {
    const trace = buildTrace('NORMAL_GREEN')
    const engines = makeFakeEngines()
    engines.stabilized.update = vi.fn(() => ({
      verdict: 'CAUTION',
      reason: 'SOMETHING',
      proceedLike: false,
    }))
    const records = runScenario({ ...trace, ticks: [trace.ticks[0]] }, engines)
    expect(records[0].baseline.proceedLike).toBe(false)
  })
})

describe('runScenario — engines called once per tick with that tick input (spy)', () => {
  it('raw/stabilized/shield each called exactly TICK_COUNT times, args match tick input', () => {
    const trace = buildTrace('NORMAL_GREEN')
    const engines = makeFakeEngines()
    runScenario(trace, engines)

    expect(engines.raw.update).toHaveBeenCalledTimes(trace.ticks.length)
    expect(engines.stabilized.update).toHaveBeenCalledTimes(trace.ticks.length)
    expect(engines.shield.update).toHaveBeenCalledTimes(trace.ticks.length)

    // Spot check tick 0 and tick 50 call args.
    for (const idx of [0, 50]) {
      const tick = trace.ticks[idx]
      const expectedInput = {
        target: tick.target,
        cits: tick.cits,
        vision: tick.vision,
        user: tick.user,
        crosswalk: tick.crosswalk,
        clock: tick.clock,
      }
      expect(engines.raw.update.mock.calls[idx][0]).toEqual(expectedInput)
      expect(engines.stabilized.update.mock.calls[idx][0]).toEqual(expectedInput)
      expect(engines.stabilized.update.mock.calls[idx][1]).toBe(tick.clock.nowMonoMs)
      expect(engines.shield.update.mock.calls[idx][0]).toEqual(expectedInput)
    }
  })
})

describe('runScenario — latency measurement is injected, never computed via a clock inside src/', () => {
  it('measureLatency absent → latencyMs is null for every record', () => {
    const trace = buildTrace('NORMAL_GREEN')
    const engines = makeFakeEngines()
    const records = runScenario(trace, engines)
    for (const rec of records) {
      expect(rec.latencyMs).toBeNull()
    }
  })

  it('measureLatency given → latencyMs.{baselineRaw,baseline,proposed} populated from the injected wrapper', () => {
    const trace = buildTrace('NORMAL_GREEN')
    const engines = makeFakeEngines()
    let call = 0
    const measureLatency = (fn) => {
      call += 1
      const result = fn()
      return { result, ms: call * 0.1 }
    }
    const records = runScenario({ ...trace, ticks: [trace.ticks[0]] }, engines, { measureLatency })

    expect(records[0].latencyMs).not.toBeNull()
    expect(typeof records[0].latencyMs.baselineRaw).toBe('number')
    expect(typeof records[0].latencyMs.baseline).toBe('number')
    expect(typeof records[0].latencyMs.proposed).toBe('number')
    // measureLatency must actually wrap each of the three engine calls (3 calls for 1 tick).
    expect(call).toBe(3)
  })

  it('measureLatency wrapper result is used as the actual engine output (not discarded)', () => {
    const trace = buildTrace('NORMAL_GREEN')
    const engines = makeFakeEngines()
    const measureLatency = (fn) => ({ result: fn(), ms: 1.23 })
    const records = runScenario({ ...trace, ticks: [trace.ticks[0]] }, engines, { measureLatency })
    expect(records[0].baseline).toEqual({ verdict: 'WAIT', reason: 'CONFIRMING', proceedLike: false })
    expect(records[0].latencyMs.baseline).toBe(1.23)
  })
})

describe('runScenario — no core clock usage; caller-provided fresh engine instances only (documented contract)', () => {
  it('does not throw when given fresh real engines (raw/stabilized/shield) over a short real trace', () => {
    const trace = buildTrace('NORMAL_GREEN')
    const { raw, stabilized } = createBaselineEngines()
    const shield = createRuntimeShield()
    expect(() => runScenario(trace, { raw, stabilized, shield })).not.toThrow()
  })
})

describe('runScenario — integration: REAL traces through REAL engines (H1-critical facts)', () => {
  function realEngines() {
    const { raw, stabilized } = createBaselineEngines()
    const shield = createRuntimeShield()
    return { raw, stabilized, shield }
  }

  it('WRONG_TARGET_GREEN: baseline (stabilized) proceeds at least once during unsafe, proposed never does', () => {
    const trace = buildTrace('WRONG_TARGET_GREEN')
    const records = runScenario(trace, realEngines())

    const unsafeRecords = records.filter((r) => r.groundTruth.unsafe)
    expect(unsafeRecords.length).toBeGreaterThan(0)

    const baselineEverProceeded = unsafeRecords.some((r) => r.baseline.proceedLike)
    const proposedEverProceeded = unsafeRecords.some((r) => r.proposed.proceedLike)

    expect(baselineEverProceeded).toBe(true)
    expect(proposedEverProceeded).toBe(false)
  })

  it('NORMAL_GREEN: proposed reaches SIGNAL_CONFIRMED (proceed-like) at some point', () => {
    const trace = buildTrace('NORMAL_GREEN')
    const records = runScenario(trace, realEngines())
    expect(records.some((r) => r.proposed.proceedLike)).toBe(true)
  })

  it('TRUE_GREEN_TO_RED: proposed time-to-inhibit is 0ms (same-tick WAIT on fault onset)', () => {
    const trace = buildTrace('TRUE_GREEN_TO_RED')
    const records = runScenario(trace, realEngines())

    const onsetIdx = records.findIndex((r) => r.groundTruth.faultActive)
    expect(onsetIdx).toBeGreaterThan(-1)
    // Proposed must already be non-proceed-like at the exact onset tick.
    expect(records[onsetIdx].proposed.proceedLike).toBe(false)
    // And prior to onset, proposed must have been proceed-like at least once
    // (otherwise "inhibit" is vacuous — nothing was being inhibited).
    const beforeOnset = records.slice(0, onsetIdx)
    expect(beforeOnset.some((r) => r.proposed.proceedLike)).toBe(true)
  })
})
