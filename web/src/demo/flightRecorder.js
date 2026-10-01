/**
 * Live-demo flight recorder (스펙 §W2.1).
 *
 * Pure, testable, no I/O — records every safety-tick entry produced by
 * App.jsx's 100ms loop into an in-memory ring buffer, and can serialize the
 * buffer to JSONL (one JSON object per line) for download.
 *
 * latencyStats() mirrors src/experiments/metrics.js's nearest-rank p95
 * approach (same `Math.ceil(0.95 * n) - 1` index, same even/odd median) so
 * the on-screen E2E readout uses the identical arithmetic already validated
 * by the offline experiment pipeline — no second definition of "p95" to
 * drift out of sync.
 */

function median(sortedValues) {
  const len = sortedValues.length
  if (len === 0) return null
  const mid = Math.floor(len / 2)
  return len % 2 === 0 ? (sortedValues[mid - 1] + sortedValues[mid]) / 2 : sortedValues[mid]
}

function p95(sortedValues) {
  if (sortedValues.length === 0) return null
  const idx = Math.min(sortedValues.length - 1, Math.ceil(0.95 * sortedValues.length) - 1)
  return sortedValues[Math.max(0, idx)]
}

/**
 * @param {object} [params]
 * @param {number} [params.maxEntries=30000] ring-buffer capacity — oldest
 *   entries are dropped once exceeded (a multi-hour demo session must not
 *   grow memory unbounded).
 * @returns {{ record(entry: object): void, toJsonl(): string, count(): number, latencyStats(): {n: number, medianMs: number|null, p95Ms: number|null} }}
 */
export function createFlightRecorder({ maxEntries = 30000 } = {}) {
  const cap = Number.isFinite(maxEntries) && maxEntries > 0 ? Math.floor(maxEntries) : 30000
  /** @type {object[]} */
  let entries = []

  function record(entry) {
    if (entry === null || entry === undefined || typeof entry !== 'object') return
    entries.push(entry)
    if (entries.length > cap) {
      // Rollover: drop oldest entries down to capacity. Slice (not shift-loop)
      // keeps this O(overflow) instead of O(n) per call in the steady state.
      entries = entries.slice(entries.length - cap)
    }
  }

  function toJsonl() {
    return entries.map((e) => JSON.stringify(e)).join('\n')
  }

  function count() {
    return entries.length
  }

  function latencyStats() {
    const values = entries
      .map((e) => e.e2eMs)
      .filter((v) => v !== null && v !== undefined && typeof v === 'number' && Number.isFinite(v))
      .sort((a, b) => a - b)

    return {
      n: values.length,
      medianMs: median(values),
      p95Ms: p95(values),
    }
  }

  return { record, toJsonl, count, latencyStats }
}
