/**
 * Episode-based safety metrics (원본설계서 §13, 스펙 §2.8).
 *
 * Pure functions only — no I/O, no Date/performance.now(), no randomness.
 * All ratios are returned as `{ n, N }` pairs; the quotient is never
 * precomputed alone (global constraint: "보고서 수치는 로그 산출값만" +
 * spec §2.8 "모든 비율은 분자/분모 보존").
 *
 * `summarize(runsByScenario)` consumes the array shape produced by running
 * every scenario's trace through `runScenario()` (traceRunner.js):
 *   runsByScenario = [{ scenarioId, riskClass, records }, ...]
 * where `records` is the 원본 §14-schema array for that one scenario/episode.
 *
 * episode = one scenario run in its entirety (스펙 §2.8: "episode = 시나리오
 * 1회"). UAER/CVER denominators count EPISODES (one number per scenario in
 * the matching riskClass), not ticks.
 */

const ENGINE_KEYS = ['baselineRaw', 'baseline', 'proposed']

// SAFE_COVERAGE_START_TICK — earliest tick index (0-based, TICK_MS=100ms)
// at which a PERFECT engine could possibly have reached proceed-like status
// on the NORMAL_GREEN trace, given RTA_CONFIG_V1.confirmHoldMs = 1500ms.
// 1500ms / 100ms = 15 ticks of hold are required once confirmation begins;
// since NORMAL_GREEN's dual-green condition already holds at tick 0 and
// distinct green frames accumulate one per tick (well under
// minDistinctGreenFrames=5 by tick 15), confirmHoldMs is the binding
// constraint. Ticks before this index are excluded from Safe Coverage
// because ANY engine — including a hypothetical perfect one bound by the
// same hold requirement — is structurally unable to be proceed-like yet;
// counting them would penalize confirmation latency twice (once via
// confirmLatencyMs, again via a Safe Coverage denominator no engine could
// satisfy). This is a documented, fixed constant, not derived per-run.
export const SAFE_COVERAGE_START_TICK = 15

function median(sorted) {
  const len = sorted.length
  if (len === 0) return null
  const mid = Math.floor(len / 2)
  return len % 2 === 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
}

function p95(sorted) {
  if (sorted.length === 0) return null
  const idx = Math.min(sorted.length - 1, Math.ceil(0.95 * sorted.length) - 1)
  return sorted[Math.max(0, idx)]
}

function evalLatencyStats(allRecords, engineKey) {
  const values = allRecords
    .map((r) => r.latencyMs)
    .filter((l) => l !== null && l !== undefined)
    .map((l) => l[engineKey])
    .filter((v) => typeof v === 'number' && Number.isFinite(v))
    .sort((a, b) => a - b)

  if (values.length === 0) {
    return { median: null, p95: null, max: null }
  }
  return {
    median: median(values),
    p95: p95(values),
    max: values[values.length - 1],
  }
}

/**
 * UAER/CVER: episode-based. For each episode (scenario run) in the target
 * riskClass, n increments if that engine had >=1 proceed-like tick during
 * any unsafe tick of that episode; N is the count of episodes in that
 * riskClass — regardless of whether the engine ever proceeded.
 */
function episodeRate(runsByScenario, riskClass, engineKey) {
  const matching = runsByScenario.filter((run) => run.riskClass === riskClass)
  let n = 0
  for (const run of matching) {
    const everProceededDuringUnsafe = run.records.some(
      (r) => r.groundTruth.unsafe && r[engineKey].proceedLike
    )
    if (everProceededDuringUnsafe) n += 1
  }
  return { n, N: matching.length }
}

function dprTick(runsByScenario, engineKey) {
  let n = 0
  let N = 0
  for (const run of runsByScenario) {
    for (const r of run.records) {
      if (!r.groundTruth.unsafe) continue
      N += 1
      if (r[engineKey].proceedLike) n += 1
    }
  }
  return { n, N }
}

function safeCoverage(runsByScenario, engineKey) {
  let n = 0
  let N = 0
  for (const run of runsByScenario) {
    if (run.riskClass !== 'SAFE') continue
    for (const r of run.records) {
      if (r.tickIndex < SAFE_COVERAGE_START_TICK) continue
      N += 1
      if (r[engineKey].proceedLike) n += 1
    }
  }
  return { n, N }
}

/**
 * confirmLatencyMs: from the SAFE-class (NORMAL_GREEN) scenario(s), the
 * elapsed ms between the first tick's nowMonoMs (t=0, "조건 최초 성립") and
 * the first proceed-like tick's nowMonoMs. null if the engine never
 * proceeds anywhere in the SAFE-class records.
 */
function confirmLatencyMs(runsByScenario, engineKey) {
  for (const run of runsByScenario) {
    if (run.riskClass !== 'SAFE') continue
    const records = run.records
    if (records.length === 0) continue
    const t0 = records[0].nowMonoMs
    const firstProceed = records.find((r) => r[engineKey].proceedLike)
    if (firstProceed) return firstProceed.nowMonoMs - t0
  }
  return null
}

/**
 * timeToInhibitMs: from the TRUE_GREEN_TO_RED-shaped scenario(s) (identified
 * by riskClass PHYSICAL + a groundTruth.faultActive transition), the elapsed
 * ms between the fault onset tick and the first non-proceed-like tick at or
 * after onset. 0 if the onset tick itself is already non-proceed-like.
 *
 * Return value meaning:
 *   number  — ms from onset to first inhibited tick (0 = same-tick inhibit)
 *   null    — NOT MEASURABLE: either (a) no fault onset in the records,
 *             (b) the engine was never proceed-like at any point BEFORE
 *             onset (원본 §13.8 defines this metric as measured from
 *             "SIGNAL_CONFIRMED 중" — there is nothing to inhibit if the
 *             engine never confirmed pre-onset; reporting 0ms in that case
 *             would misrepresent an engine that never engaged as
 *             instantaneously responsive — reviewer finding), or (c) the
 *             engine is never inhibited after onset.
 */
function timeToInhibitMs(runsByScenario, engineKey) {
  const run = runsByScenario.find((r) => r.scenarioId === 'TRUE_GREEN_TO_RED')
  if (!run) return null
  const records = run.records
  const onsetIdx = records.findIndex((r) => r.groundTruth.faultActive)
  if (onsetIdx === -1) return null

  const wasEverProceedingBeforeOnset = records
    .slice(0, onsetIdx)
    .some((r) => r[engineKey].proceedLike)
  if (!wasEverProceedingBeforeOnset) return null

  for (let i = onsetIdx; i < records.length; i++) {
    if (!records[i][engineKey].proceedLike) {
      return records[i].nowMonoMs - records[onsetIdx].nowMonoMs
    }
  }
  return null
}

function topReason(records, engineKey) {
  const unsafeRecords = records.filter((r) => r.groundTruth.unsafe)
  const counts = new Map()
  for (const r of unsafeRecords) {
    const reason = r[engineKey].reason
    counts.set(reason, (counts.get(reason) ?? 0) + 1)
  }
  let best = null
  let bestCount = -1
  for (const [reason, count] of counts) {
    if (count > bestCount) {
      best = reason
      bestCount = count
    }
  }
  return best
}

function scenarioEngineRow(records, engineKey) {
  const unsafeRecords = records.filter((r) => r.groundTruth.unsafe)
  const proceedTicksInUnsafe = unsafeRecords.filter((r) => r[engineKey].proceedLike).length
  return {
    proceedTicksInUnsafe,
    unsafeTicks: unsafeRecords.length,
    everProceededDuringUnsafe: proceedTicksInUnsafe > 0,
    blockingReasons: topReason(records, engineKey),
  }
}

function scenarioRows(runsByScenario) {
  return runsByScenario.map((run) => {
    const row = { scenarioId: run.scenarioId, riskClass: run.riskClass }
    for (const engineKey of ENGINE_KEYS) {
      row[engineKey] = scenarioEngineRow(run.records, engineKey)
    }
    return row
  })
}

/**
 * @param {Array<{ scenarioId: string, riskClass: string, records: object[] }>} runsByScenario
 * @returns {object} per-engine metrics (baselineRaw/baseline/proposed) + scenarios[] rows
 */
export function summarize(runsByScenario) {
  const runs = runsByScenario ?? []
  const allRecords = runs.flatMap((run) => run.records)

  const summary = { scenarios: scenarioRows(runs) }

  for (const engineKey of ENGINE_KEYS) {
    summary[engineKey] = {
      uaer: episodeRate(runs, 'PHYSICAL', engineKey),
      cver: episodeRate(runs, 'CONTRACT', engineKey),
      dprTick: dprTick(runs, engineKey),
      safeCoverage: safeCoverage(runs, engineKey),
      confirmLatencyMs: confirmLatencyMs(runs, engineKey),
      timeToInhibitMs: timeToInhibitMs(runs, engineKey),
      evalLatencyMs: evalLatencyStats(allRecords, engineKey),
    }
  }

  return summary
}
