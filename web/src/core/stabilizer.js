/**
 * 비대칭 히스테리시스: 허가 방향(CROSS/CAUTION)은 holdMs 연속 유지 시에만
 * 확정하고, 안전 방향(WAIT/WARNING)은 즉시 확정한다.
 */
const IMMEDIATE = new Set(['WAIT', 'WARNING'])

export function createStabilizer({ holdMs = 1500 } = {}) {
  let current = null
  let candidate = null
  let candidateSince = null

  const commit = (result) => {
    const changed =
      !current || current.verdict !== result.verdict || current.message !== result.message
    current = result
    candidate = null
    candidateSince = null
    return { result: current, changed }
  }

  return {
    update(result, nowMs) {
      if (!result) return { result: current, changed: false }

      if (IMMEDIATE.has(result.verdict)) return commit(result)

      // CROSS/CAUTION: holdMs 연속 유지 검사
      if (!candidate || candidate.verdict !== result.verdict) {
        candidate = result
        candidateSince = nowMs
        return { result: current, changed: false }
      }
      if (nowMs - candidateSince >= holdMs) return commit(result)
      return { result: current, changed: false }
    },
  }
}
