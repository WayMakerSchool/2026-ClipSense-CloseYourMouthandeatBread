/**
 * Trace runner — replays a deterministic scenario trace through all three
 * comparison engines and emits one 원본설계서 §14 JSONL-schema record per
 * tick (스펙 §2.8).
 *
 * Caller's responsibility: `engines = { raw, stabilized, shield }` MUST be
 * fresh instances created for this specific scenario run (e.g. via
 * `createBaselineEngines()` + `createRuntimeShield()` called immediately
 * before `runScenario`). Each engine is stateful (stabilizer hold timers,
 * shield confirmation accumulation) — reusing an instance across scenarios
 * would leak state between runs and break determinism.
 *
 * No Date.now()/performance.now() here (global constraint: clock injection
 * only). Latency is measured by an injected `measureLatency(fn) → { result, ms }`
 * wrapper; when omitted, `latencyMs` is `null` on every record.
 */

const NULL_LATENCY = null

function toEngineInput(tick) {
  return {
    target: tick.target,
    cits: tick.cits,
    vision: tick.vision,
    user: tick.user,
    crosswalk: tick.crosswalk,
    clock: tick.clock,
  }
}

// 원본 §14 record.input schema — target/cits/vision/user/crosswalk only;
// nowEpochMs/nowMonoMs are already top-level record fields, so `clock` is
// deliberately excluded here (not duplicated).
function toRecordInput(tick) {
  return {
    target: tick.target,
    cits: tick.cits,
    vision: tick.vision,
    user: tick.user,
    crosswalk: tick.crosswalk,
  }
}

function toProposedRecord(shieldOutput) {
  return {
    decision: shieldOutput.decision,
    reason: shieldOutput.reason,
    proceedLike: shieldOutput.decision === 'SIGNAL_CONFIRMED',
    checks: shieldOutput.checks,
  }
}

/**
 * Runs one scenario trace through the three comparison engines.
 *
 * @param {{ scenarioId: string, riskClass: string, ticks: object[] }} trace
 * @param {{ raw: {update: Function}, stabilized: {update: Function}, shield: {update: Function} }} engines
 *   Fresh instances — see module doc.
 * @param {{ measureLatency?: (fn: () => any) => { result: any, ms: number } }} [options]
 * @returns {object[]} one 원본 §14-schema record per tick
 */
export function runScenario(trace, engines, { measureLatency } = {}) {
  const { scenarioId, ticks } = trace
  const { raw, stabilized, shield } = engines
  const runId = `${scenarioId}-deterministic-run-001`

  return ticks.map((tick) => {
    const tickInput = toEngineInput(tick)
    const nowMonoMs = tick.clock.nowMonoMs

    let baselineRawOut
    let baselineOut
    let proposedOut
    let latencyMs = NULL_LATENCY

    if (measureLatency) {
      const rawMeasured = measureLatency(() => raw.update(tickInput, nowMonoMs))
      const baselineMeasured = measureLatency(() => stabilized.update(tickInput, nowMonoMs))
      const proposedMeasured = measureLatency(() => shield.update(tickInput))

      baselineRawOut = rawMeasured.result
      baselineOut = baselineMeasured.result
      proposedOut = proposedMeasured.result
      latencyMs = {
        baselineRaw: rawMeasured.ms,
        baseline: baselineMeasured.ms,
        proposed: proposedMeasured.ms,
      }
    } else {
      baselineRawOut = raw.update(tickInput, nowMonoMs)
      baselineOut = stabilized.update(tickInput, nowMonoMs)
      proposedOut = shield.update(tickInput)
    }

    return {
      schemaVersion: 'experiment-log-v1',
      runId,
      scenarioId,
      tickIndex: tick.tickIndex,
      seed: null, // 결정론 trace — random seed 불필요
      nowEpochMs: tick.clock.nowEpochMs,
      nowMonoMs: tick.clock.nowMonoMs,
      groundTruth: tick.groundTruth,
      input: toRecordInput(tick),
      baseline: {
        verdict: baselineOut.verdict,
        reason: baselineOut.reason,
        proceedLike: baselineOut.proceedLike,
      },
      baselineRaw: {
        verdict: baselineRawOut.verdict,
        reason: baselineRawOut.reason,
        proceedLike: baselineRawOut.proceedLike,
      },
      proposed: toProposedRecord(proposedOut),
      latencyMs,
      configVersion: proposedOut.configVersion,
    }
  })
}
