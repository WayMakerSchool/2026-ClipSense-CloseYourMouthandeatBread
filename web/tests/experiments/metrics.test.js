import { describe, it, expect } from 'vitest'
import { summarize, SAFE_COVERAGE_START_TICK } from '../../src/experiments/metrics.js'
import { runScenario } from '../../src/experiments/traceRunner.js'
import { buildTrace } from '../../src/experiments/faultScenarios.js'
import { createBaselineEngines } from '../../src/safety/baselineAdapter.js'
import { createRuntimeShield } from '../../src/safety/runtimeShield.js'

/**
 * Hand-built minimal record builder — only the fields metrics.js actually
 * reads (원본 §14 subset). Each engine key (baselineRaw/baseline/proposed)
 * carries `{ proceedLike }` plus whatever verdict/decision/reason is unused
 * by metrics but kept for schema realism.
 */
function rec({
  scenarioId,
  tickIndex,
  nowMonoMs,
  unsafe,
  faultActive = unsafe,
  baselineRawProceed = false,
  baselineProceed = false,
  proposedProceed = false,
  latencyMs = null,
}) {
  return {
    schemaVersion: 'experiment-log-v1',
    runId: `${scenarioId}-deterministic-run-001`,
    scenarioId,
    tickIndex,
    seed: null,
    nowEpochMs: 1_000_000 + nowMonoMs,
    nowMonoMs,
    groundTruth: { unsafe, faultActive, faultType: unsafe ? 'TEST_FAULT' : null },
    input: {},
    baseline: { verdict: baselineProceed ? 'CROSS' : 'WAIT', reason: 'X', proceedLike: baselineProceed },
    baselineRaw: {
      verdict: baselineRawProceed ? 'CROSS' : 'WAIT',
      reason: 'X',
      proceedLike: baselineRawProceed,
    },
    proposed: {
      decision: proposedProceed ? 'SIGNAL_CONFIRMED' : 'WAIT',
      reason: 'X',
      proceedLike: proposedProceed,
      checks: {},
    },
    latencyMs,
    configVersion: 'safegraph-rta-demo-v1',
  }
}

describe('SAFE_COVERAGE_START_TICK constant', () => {
  it('is 15 (confirmHoldMs 1500ms / TICK_MS 100ms — earliest tick a perfect engine could confirm)', () => {
    expect(SAFE_COVERAGE_START_TICK).toBe(15)
  })
})

describe('summarize — UAER: episode-based over PHYSICAL scenarios only', () => {
  it('2 PHYSICAL episodes, 1 with a single proceed-like tick during unsafe → UAER {n:1,N:2}', () => {
    // Episode A (PHYSICAL): all 3 ticks unsafe, proposed proceeds on tick 1 only.
    const episodeA = [
      rec({ scenarioId: 'A', tickIndex: 0, nowMonoMs: 0, unsafe: true, proposedProceed: false }),
      rec({ scenarioId: 'A', tickIndex: 1, nowMonoMs: 100, unsafe: true, proposedProceed: true }),
      rec({ scenarioId: 'A', tickIndex: 2, nowMonoMs: 200, unsafe: true, proposedProceed: false }),
    ]
    // Episode B (PHYSICAL): all 3 ticks unsafe, proposed never proceeds.
    const episodeB = [
      rec({ scenarioId: 'B', tickIndex: 0, nowMonoMs: 0, unsafe: true, proposedProceed: false }),
      rec({ scenarioId: 'B', tickIndex: 1, nowMonoMs: 100, unsafe: true, proposedProceed: false }),
      rec({ scenarioId: 'B', tickIndex: 2, nowMonoMs: 200, unsafe: true, proposedProceed: false }),
    ]
    const runsByScenario = [
      { scenarioId: 'A', riskClass: 'PHYSICAL', records: episodeA },
      { scenarioId: 'B', riskClass: 'PHYSICAL', records: episodeB },
    ]

    const summary = summarize(runsByScenario)
    expect(summary.proposed.uaer).toEqual({ n: 1, N: 2 })
  })

  it('CONTRACT-class episodes are excluded from UAER denominator entirely', () => {
    const physical = [rec({ scenarioId: 'A', tickIndex: 0, nowMonoMs: 0, unsafe: true })]
    const contract = [
      rec({ scenarioId: 'C', tickIndex: 0, nowMonoMs: 0, unsafe: true, proposedProceed: true }),
    ]
    const summary = summarize([
      { scenarioId: 'A', riskClass: 'PHYSICAL', records: physical },
      { scenarioId: 'C', riskClass: 'CONTRACT', records: contract },
    ])
    expect(summary.proposed.uaer).toEqual({ n: 0, N: 1 })
  })

  it('each engine (baselineRaw/baseline/proposed) gets its own independent UAER n', () => {
    const episodeA = [
      rec({
        scenarioId: 'A',
        tickIndex: 0,
        nowMonoMs: 0,
        unsafe: true,
        baselineRawProceed: true,
        baselineProceed: true,
        proposedProceed: false,
      }),
    ]
    const summary = summarize([{ scenarioId: 'A', riskClass: 'PHYSICAL', records: episodeA }])
    expect(summary.baselineRaw.uaer).toEqual({ n: 1, N: 1 })
    expect(summary.baseline.uaer).toEqual({ n: 1, N: 1 })
    expect(summary.proposed.uaer).toEqual({ n: 0, N: 1 })
  })
})

describe('summarize — CVER: episode-based over CONTRACT scenarios only', () => {
  it('1 CONTRACT episode with proceed-like during unsafe, 1 without → CVER {n:1,N:2}', () => {
    const episodeA = [
      rec({ scenarioId: 'A', tickIndex: 0, nowMonoMs: 0, unsafe: true, baselineProceed: true }),
    ]
    const episodeB = [
      rec({ scenarioId: 'B', tickIndex: 0, nowMonoMs: 0, unsafe: true, baselineProceed: false }),
    ]
    const summary = summarize([
      { scenarioId: 'A', riskClass: 'CONTRACT', records: episodeA },
      { scenarioId: 'B', riskClass: 'CONTRACT', records: episodeB },
    ])
    expect(summary.baseline.cver).toEqual({ n: 1, N: 2 })
  })

  it('PHYSICAL episodes do not leak into CVER', () => {
    const physical = [
      rec({ scenarioId: 'A', tickIndex: 0, nowMonoMs: 0, unsafe: true, baselineProceed: true }),
    ]
    const summary = summarize([{ scenarioId: 'A', riskClass: 'PHYSICAL', records: physical }])
    expect(summary.baseline.cver).toEqual({ n: 0, N: 0 })
  })
})

describe('summarize — DPR_tick: counts UNSAFE TICKS (not episodes), across all scenarios', () => {
  it('3 unsafe ticks total across 2 scenarios, 2 of them proceed-like → DPR_tick {n:2,N:3}', () => {
    const episodeA = [
      // unsafe ticks: idx0 (proceed), idx1 (not), idx2 safe(not counted)
      rec({ scenarioId: 'A', tickIndex: 0, nowMonoMs: 0, unsafe: true, proposedProceed: true }),
      rec({ scenarioId: 'A', tickIndex: 1, nowMonoMs: 100, unsafe: true, proposedProceed: false }),
      rec({ scenarioId: 'A', tickIndex: 2, nowMonoMs: 200, unsafe: false, proposedProceed: true }),
    ]
    const episodeB = [
      // unsafe tick: idx0 (proceed)
      rec({ scenarioId: 'B', tickIndex: 0, nowMonoMs: 0, unsafe: true, proposedProceed: true }),
    ]
    const summary = summarize([
      { scenarioId: 'A', riskClass: 'PHYSICAL', records: episodeA },
      { scenarioId: 'B', riskClass: 'CONTRACT', records: episodeB },
    ])
    // unsafe ticks: A0(proceed), A1(no), B0(proceed) => n=2, N=3
    expect(summary.proposed.dprTick).toEqual({ n: 2, N: 3 })
  })

  it('SAFE-class scenario ticks never contribute to DPR_tick denominator (no unsafe ticks)', () => {
    const safe = [rec({ scenarioId: 'NORMAL_GREEN', tickIndex: 0, nowMonoMs: 0, unsafe: false })]
    const summary = summarize([{ scenarioId: 'NORMAL_GREEN', riskClass: 'SAFE', records: safe }])
    expect(summary.proposed.dprTick).toEqual({ n: 0, N: 0 })
  })
})

describe('summarize — safeCoverage: NORMAL_GREEN ticks from SAFE_COVERAGE_START_TICK onward', () => {
  it('counts only ticks with tickIndex >= 15 within the SAFE-class scenario', () => {
    const records = []
    for (let i = 0; i < 20; i++) {
      records.push(
        rec({
          scenarioId: 'NORMAL_GREEN',
          tickIndex: i,
          nowMonoMs: i * 100,
          unsafe: false,
          proposedProceed: i >= 16, // proceeds from tick 16 onward
        })
      )
    }
    const summary = summarize([{ scenarioId: 'NORMAL_GREEN', riskClass: 'SAFE', records }])
    // eligible ticks: 15..19 = 5 ticks; proceed-like among them: 16,17,18,19 = 4
    expect(summary.proposed.safeCoverage).toEqual({ n: 4, N: 5 })
  })

  it('non-SAFE scenarios do not contribute to safeCoverage', () => {
    const records = [rec({ scenarioId: 'A', tickIndex: 20, nowMonoMs: 2000, unsafe: true })]
    const summary = summarize([{ scenarioId: 'A', riskClass: 'PHYSICAL', records }])
    expect(summary.proposed.safeCoverage).toEqual({ n: 0, N: 0 })
  })
})

describe('summarize — confirmLatencyMs: NORMAL_GREEN first-eligible(t=0) → first proceed-like', () => {
  it('computes ms from tick 0 nowMonoMs to the first proceed-like tick nowMonoMs', () => {
    const records = [
      rec({ scenarioId: 'NORMAL_GREEN', tickIndex: 0, nowMonoMs: 5000, unsafe: false, proposedProceed: false }),
      rec({ scenarioId: 'NORMAL_GREEN', tickIndex: 1, nowMonoMs: 5100, unsafe: false, proposedProceed: false }),
      rec({ scenarioId: 'NORMAL_GREEN', tickIndex: 2, nowMonoMs: 5200, unsafe: false, proposedProceed: true }),
    ]
    const summary = summarize([{ scenarioId: 'NORMAL_GREEN', riskClass: 'SAFE', records }])
    expect(summary.proposed.confirmLatencyMs).toBe(200) // 5200 - 5000
  })

  it('never-proceed → null', () => {
    const records = [
      rec({ scenarioId: 'NORMAL_GREEN', tickIndex: 0, nowMonoMs: 0, unsafe: false, proposedProceed: false }),
      rec({ scenarioId: 'NORMAL_GREEN', tickIndex: 1, nowMonoMs: 100, unsafe: false, proposedProceed: false }),
    ]
    const summary = summarize([{ scenarioId: 'NORMAL_GREEN', riskClass: 'SAFE', records }])
    expect(summary.proposed.confirmLatencyMs).toBeNull()
  })

  it('is computed independently per engine', () => {
    const records = [
      rec({
        scenarioId: 'NORMAL_GREEN',
        tickIndex: 0,
        nowMonoMs: 0,
        unsafe: false,
        baselineRawProceed: true,
        proposedProceed: false,
      }),
      rec({
        scenarioId: 'NORMAL_GREEN',
        tickIndex: 1,
        nowMonoMs: 100,
        unsafe: false,
        proposedProceed: true,
      }),
    ]
    const summary = summarize([{ scenarioId: 'NORMAL_GREEN', riskClass: 'SAFE', records }])
    expect(summary.baselineRaw.confirmLatencyMs).toBe(0)
    expect(summary.proposed.confirmLatencyMs).toBe(100)
  })
})

describe('summarize — timeToInhibitMs: TRUE_GREEN_TO_RED fault onset → first non-proceed after onset', () => {
  it('same-tick inhibit (onset tick already non-proceed) → 0', () => {
    const records = [
      rec({ scenarioId: 'TRUE_GREEN_TO_RED', tickIndex: 0, nowMonoMs: 0, unsafe: false, proposedProceed: true }),
      rec({ scenarioId: 'TRUE_GREEN_TO_RED', tickIndex: 1, nowMonoMs: 100, unsafe: false, proposedProceed: true }),
      // onset at tick 2 — proposed drops to non-proceed on the SAME tick.
      rec({
        scenarioId: 'TRUE_GREEN_TO_RED',
        tickIndex: 2,
        nowMonoMs: 200,
        unsafe: true,
        faultActive: true,
        proposedProceed: false,
      }),
    ]
    const summary = summarize([{ scenarioId: 'TRUE_GREEN_TO_RED', riskClass: 'PHYSICAL', records }])
    expect(summary.proposed.timeToInhibitMs).toBe(0)
  })

  it('delayed inhibit: onset tick still proceed-like, inhibited 2 ticks later → 200ms', () => {
    const records = [
      rec({ scenarioId: 'TRUE_GREEN_TO_RED', tickIndex: 0, nowMonoMs: 0, unsafe: false, baselineProceed: true }),
      rec({
        scenarioId: 'TRUE_GREEN_TO_RED',
        tickIndex: 1,
        nowMonoMs: 100,
        unsafe: true,
        faultActive: true,
        baselineProceed: true, // onset tick — baseline (stabilized) still proceeding
      }),
      rec({
        scenarioId: 'TRUE_GREEN_TO_RED',
        tickIndex: 2,
        nowMonoMs: 200,
        unsafe: true,
        faultActive: true,
        baselineProceed: true,
      }),
      rec({
        scenarioId: 'TRUE_GREEN_TO_RED',
        tickIndex: 3,
        nowMonoMs: 300,
        unsafe: true,
        faultActive: true,
        baselineProceed: false, // first non-proceed after onset
      }),
    ]
    const summary = summarize([{ scenarioId: 'TRUE_GREEN_TO_RED', riskClass: 'PHYSICAL', records }])
    expect(summary.baseline.timeToInhibitMs).toBe(200) // 300 - 100
  })

  it('no fault onset in trace → null', () => {
    const records = [
      rec({ scenarioId: 'TRUE_GREEN_TO_RED', tickIndex: 0, nowMonoMs: 0, unsafe: false, proposedProceed: true }),
    ]
    const summary = summarize([{ scenarioId: 'TRUE_GREEN_TO_RED', riskClass: 'PHYSICAL', records }])
    expect(summary.proposed.timeToInhibitMs).toBeNull()
  })

  it('reviewer finding: engine never proceed-like before onset → null, NOT 0 (원본 §13.8 "SIGNAL_CONFIRMED 중" precondition)', () => {
    // Onset tick itself is non-proceed, which would naively look like a
    // "same-tick inhibit" (0ms) — but this engine was NEVER proceed-like at
    // any point before onset, so there was nothing to inhibit. Reporting
    // 0ms here would misrepresent a never-engaged engine as instantaneously
    // responsive.
    const records = [
      rec({ scenarioId: 'TRUE_GREEN_TO_RED', tickIndex: 0, nowMonoMs: 0, unsafe: false, proposedProceed: false }),
      rec({ scenarioId: 'TRUE_GREEN_TO_RED', tickIndex: 1, nowMonoMs: 100, unsafe: false, proposedProceed: false }),
      rec({
        scenarioId: 'TRUE_GREEN_TO_RED',
        tickIndex: 2,
        nowMonoMs: 200,
        unsafe: true,
        faultActive: true,
        proposedProceed: false,
      }),
    ]
    const summary = summarize([{ scenarioId: 'TRUE_GREEN_TO_RED', riskClass: 'PHYSICAL', records }])
    expect(summary.proposed.timeToInhibitMs).toBeNull()
  })

  it('reviewer finding: engine proceed-like at least once before onset, onset tick non-proceed → 0 (still valid same-tick inhibit)', () => {
    const records = [
      rec({ scenarioId: 'TRUE_GREEN_TO_RED', tickIndex: 0, nowMonoMs: 0, unsafe: false, baselineRawProceed: false }),
      rec({ scenarioId: 'TRUE_GREEN_TO_RED', tickIndex: 1, nowMonoMs: 100, unsafe: false, baselineRawProceed: true }),
      rec({
        scenarioId: 'TRUE_GREEN_TO_RED',
        tickIndex: 2,
        nowMonoMs: 200,
        unsafe: true,
        faultActive: true,
        baselineRawProceed: false,
      }),
    ]
    const summary = summarize([{ scenarioId: 'TRUE_GREEN_TO_RED', riskClass: 'PHYSICAL', records }])
    expect(summary.baselineRaw.timeToInhibitMs).toBe(0)
  })

  it('reviewer finding: engine proceed-like before onset, inhibited 2 ticks after onset → 200ms (regression guard alongside null case)', () => {
    const records = [
      rec({ scenarioId: 'TRUE_GREEN_TO_RED', tickIndex: 0, nowMonoMs: 0, unsafe: false, proposedProceed: true }),
      rec({
        scenarioId: 'TRUE_GREEN_TO_RED',
        tickIndex: 1,
        nowMonoMs: 100,
        unsafe: true,
        faultActive: true,
        proposedProceed: true,
      }),
      rec({
        scenarioId: 'TRUE_GREEN_TO_RED',
        tickIndex: 2,
        nowMonoMs: 200,
        unsafe: true,
        faultActive: true,
        proposedProceed: true,
      }),
      rec({
        scenarioId: 'TRUE_GREEN_TO_RED',
        tickIndex: 3,
        nowMonoMs: 300,
        unsafe: true,
        faultActive: true,
        proposedProceed: false,
      }),
    ]
    const summary = summarize([{ scenarioId: 'TRUE_GREEN_TO_RED', riskClass: 'PHYSICAL', records }])
    expect(summary.proposed.timeToInhibitMs).toBe(200) // 300 - 100
  })

  it('never inhibited after onset → null', () => {
    const records = [
      rec({
        scenarioId: 'TRUE_GREEN_TO_RED',
        tickIndex: 0,
        nowMonoMs: 0,
        unsafe: true,
        faultActive: true,
        baselineRawProceed: true,
      }),
      rec({
        scenarioId: 'TRUE_GREEN_TO_RED',
        tickIndex: 1,
        nowMonoMs: 100,
        unsafe: true,
        faultActive: true,
        baselineRawProceed: true,
      }),
    ]
    const summary = summarize([{ scenarioId: 'TRUE_GREEN_TO_RED', riskClass: 'PHYSICAL', records }])
    expect(summary.baselineRaw.timeToInhibitMs).toBeNull()
  })

  it('integration (real trace + real engines): all 3 engines report 0ms — each has genuine pre-onset confirmation history, not a null-masked false 0', () => {
    const trace = buildTrace('TRUE_GREEN_TO_RED')
    const { raw, stabilized } = createBaselineEngines()
    const shield = createRuntimeShield()
    const records = runScenario(trace, { raw, stabilized, shield })
    const summary = summarize([{ scenarioId: 'TRUE_GREEN_TO_RED', riskClass: 'PHYSICAL', records }])

    for (const engineKey of ['baselineRaw', 'baseline', 'proposed']) {
      expect(summary[engineKey].timeToInhibitMs).toBe(0)
    }
  })
})

describe('summarize — evalLatencyMs {median,p95,max} per engine, skip null latencyMs', () => {
  it('computes from populated latencyMs records only', () => {
    const records = [
      rec({
        scenarioId: 'A',
        tickIndex: 0,
        nowMonoMs: 0,
        unsafe: false,
        latencyMs: { baselineRaw: 0.1, baseline: 0.2, proposed: 1.0 },
      }),
      rec({
        scenarioId: 'A',
        tickIndex: 1,
        nowMonoMs: 100,
        unsafe: false,
        latencyMs: { baselineRaw: 0.3, baseline: 0.4, proposed: 2.0 },
      }),
      rec({
        scenarioId: 'A',
        tickIndex: 2,
        nowMonoMs: 200,
        unsafe: false,
        latencyMs: null, // skipped
      }),
      rec({
        scenarioId: 'A',
        tickIndex: 3,
        nowMonoMs: 300,
        unsafe: false,
        latencyMs: { baselineRaw: 0.5, baseline: 0.6, proposed: 3.0 },
      }),
    ]
    const summary = summarize([{ scenarioId: 'A', riskClass: 'PHYSICAL', records }])
    // proposed values: [1.0, 2.0, 3.0] — median 2.0, max 3.0
    expect(summary.proposed.evalLatencyMs.median).toBe(2.0)
    expect(summary.proposed.evalLatencyMs.max).toBe(3.0)
    expect(typeof summary.proposed.evalLatencyMs.p95).toBe('number')
  })

  it('all latencyMs null across all records → median/p95/max all null', () => {
    const records = [rec({ scenarioId: 'A', tickIndex: 0, nowMonoMs: 0, unsafe: false, latencyMs: null })]
    const summary = summarize([{ scenarioId: 'A', riskClass: 'PHYSICAL', records }])
    expect(summary.proposed.evalLatencyMs).toEqual({ median: null, p95: null, max: null })
  })
})

describe('summarize — per-scenario rows for the fault table', () => {
  it('reports proceedTicksInUnsafe/unsafeTicks/everProceededDuringUnsafe/blockingReasons per engine per scenario', () => {
    const records = [
      rec({
        scenarioId: 'WRONG_TARGET_GREEN',
        tickIndex: 0,
        nowMonoMs: 0,
        unsafe: true,
        baselineProceed: true,
        proposedProceed: false,
      }),
      rec({
        scenarioId: 'WRONG_TARGET_GREEN',
        tickIndex: 1,
        nowMonoMs: 100,
        unsafe: true,
        baselineProceed: true,
        proposedProceed: false,
      }),
    ]
    // Override reasons so blockingReasons has something non-default to pick.
    records[0].proposed.reason = 'TARGET_MISMATCH'
    records[1].proposed.reason = 'TARGET_MISMATCH'

    const summary = summarize([
      { scenarioId: 'WRONG_TARGET_GREEN', riskClass: 'CONTRACT', records },
    ])

    const row = summary.scenarios.find((r) => r.scenarioId === 'WRONG_TARGET_GREEN')
    expect(row).toBeTruthy()
    expect(row.riskClass).toBe('CONTRACT')
    expect(row.baseline.unsafeTicks).toBe(2)
    expect(row.baseline.proceedTicksInUnsafe).toBe(2)
    expect(row.baseline.everProceededDuringUnsafe).toBe(true)
    expect(row.proposed.unsafeTicks).toBe(2)
    expect(row.proposed.proceedTicksInUnsafe).toBe(0)
    expect(row.proposed.everProceededDuringUnsafe).toBe(false)
    expect(row.proposed.blockingReasons).toBe('TARGET_MISMATCH')
  })

  it('one row per scenario, in the order given', () => {
    const summary = summarize([
      { scenarioId: 'A', riskClass: 'PHYSICAL', records: [rec({ scenarioId: 'A', tickIndex: 0, nowMonoMs: 0, unsafe: false })] },
      { scenarioId: 'B', riskClass: 'CONTRACT', records: [rec({ scenarioId: 'B', tickIndex: 0, nowMonoMs: 0, unsafe: false })] },
    ])
    expect(summary.scenarios.map((r) => r.scenarioId)).toEqual(['A', 'B'])
  })
})

describe('summarize — purity: no I/O, no Date, ratios always keep {n,N}', () => {
  it('never returns a bare number for a ratio field', () => {
    const records = [rec({ scenarioId: 'A', tickIndex: 0, nowMonoMs: 0, unsafe: true, proposedProceed: true })]
    const summary = summarize([{ scenarioId: 'A', riskClass: 'PHYSICAL', records }])
    for (const engineKey of ['baselineRaw', 'baseline', 'proposed']) {
      for (const metricKey of ['uaer', 'cver', 'dprTick', 'safeCoverage']) {
        const v = summary[engineKey][metricKey]
        expect(v).toHaveProperty('n')
        expect(v).toHaveProperty('N')
      }
    }
  })

  it('summarize is pure: calling twice with equivalent input yields deep-equal output', () => {
    const records = [rec({ scenarioId: 'A', tickIndex: 0, nowMonoMs: 0, unsafe: true, proposedProceed: true })]
    const runsByScenario = [{ scenarioId: 'A', riskClass: 'PHYSICAL', records }]
    expect(summarize(runsByScenario)).toEqual(summarize(runsByScenario))
  })

  it('empty input → zeroed structure, not a throw', () => {
    const summary = summarize([])
    expect(summary.proposed.uaer).toEqual({ n: 0, N: 0 })
    expect(summary.scenarios).toEqual([])
  })
})
