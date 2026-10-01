/**
 * Legacy Boolean-AND baseline adapter (원본설계서 §11, 스펙 §2.6).
 *
 * Wraps the pre-existing v1 engine (src/core/decisionEngine.js `decide()`
 * and src/core/stabilizer.js `createStabilizer()`) UNMODIFIED for A/B
 * comparison against SafeGraph-RTA. Two engines are exposed:
 *
 * - raw: decide() applied every tick with no temporal stabilization.
 * - stabilized: decide() + the existing 1.5s asymmetric stabilizer
 *   (CROSS/CAUTION require holdMs of continuous agreement to confirm;
 *   WAIT/WARNING confirm immediately — see src/core/stabilizer.js).
 *
 * The stabilizer's ignorance of target identity changes is a DOCUMENTED
 * baseline limitation (원본 §11.1) — it is preserved here, not fixed.
 *
 * Mapping from the RTA tick input shape (target/cits/vision/user/crosswalk/
 * clock) to decide()'s input shape:
 *   tier      = tickInput.cits?.available === true ? 1 : 2
 *   cits      = { color, remainingSec, available }        (IDs dropped)
 *   vision    = { color, confidence: vision.score }        (IDs dropped)
 *   user      = tickInput.user                              (passed through)
 *   crosswalk = tickInput.crosswalk                         (passed through,
 *               including marginSec — decide()'s requiredCrossingSec spreads
 *               crosswalk over user, so marginSec flows through unchanged)
 *
 * The baseline NEVER sees target IDs, timestamps, or sequence numbers — that
 * blindness is the research point (H1): a legacy Boolean-AND engine cannot
 * detect wrong-target, stale, reordered, or frozen signals because those
 * fields are never part of its input contract.
 */
import { decide } from '../core/decisionEngine.js'
import { createStabilizer } from '../core/stabilizer.js'

/**
 * Maps an RTA tick input to the legacy decide() input shape.
 * @param {object} tickInput
 * @returns {object}
 */
function toDecideInput(tickInput) {
  const { cits, vision, user, crosswalk } = tickInput ?? {}
  const tier = cits?.available === true ? 1 : 2

  return {
    tier,
    cits: cits
      ? { color: cits.color, remainingSec: cits.remainingSec, available: cits.available }
      : undefined,
    vision: vision ? { color: vision.color, confidence: vision.score } : undefined,
    user,
    crosswalk,
  }
}

/**
 * @param {object} result decide() output { verdict, message, hapticPattern, reason }
 * @returns {{ verdict: string, reason: string, proceedLike: boolean }}
 */
function toEngineOutput(result) {
  return {
    verdict: result.verdict,
    reason: result.reason,
    proceedLike: result.verdict === 'CROSS',
  }
}

/**
 * Creates the two legacy baseline engines for A/B comparison.
 * @returns {{ raw: { update(tickInput: object, nowMonoMs: number): object },
 *             stabilized: { update(tickInput: object, nowMonoMs: number): object } }}
 */
export function createBaselineEngines() {
  const stabilizer = createStabilizer()

  return {
    raw: {
      update(tickInput) {
        const result = decide(toDecideInput(tickInput))
        return toEngineOutput(result)
      },
    },
    stabilized: {
      update(tickInput, nowMonoMs) {
        const result = decide(toDecideInput(tickInput))
        const { result: confirmed } = stabilizer.update(result, nowMonoMs)
        // Before any commit, stabilizer.update returns { result: null, changed: false }.
        if (!confirmed) {
          return { verdict: 'WAIT', reason: 'CONFIRMING', proceedLike: false }
        }
        return toEngineOutput(confirmed)
      },
    },
  }
}
