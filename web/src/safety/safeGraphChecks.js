/**
 * SafeGraph-Lite 즉시 검사 12종 (원본설계서 §8, 스펙 §2.4).
 *
 * 순수 함수 — 브라우저 API·Date.now()/performance.now() 직접 호출 금지, clock은 인자.
 * history는 읽기 전용으로만 참조한다. 갱신은 runtimeShield의 책임이다.
 */
import {
  validateTargetContext,
  validateCitsObservation,
  validateVisionObservation,
  validateClock,
  validateConfig,
} from './contracts.js'
import { REASONS } from './reasonCodes.js'
import { requiredCrossingSec as computeRequiredCrossingSec } from '../core/crossingTime.js'

const ALL_CHECK_KEYS = [
  'inputValid',
  'targetBound',
  'targetMatch',
  'citsAvailable',
  'citsFresh',
  'visionFresh',
  'sequenceValid',
  'videoAdvancing',
  'dualGreen',
  'visionScoreOk',
  'visionQualityOk',
  'timeSufficient',
  'distinctFramesOk',
  'holdTimeOk',
]

function allFalseChecks() {
  const checks = {}
  for (const key of ALL_CHECK_KEYS) checks[key] = false
  return checks
}

/**
 * 음수 age가 futureClockToleranceMs를 넘지 않고, maxAgeMs 이하이면 신선한 것으로 본다.
 * @param {number} ageMs
 * @param {number} maxAgeMs
 * @param {number} toleranceMs
 * @returns {boolean}
 */
function isFresh(ageMs, maxAgeMs, toleranceMs) {
  if (!Number.isFinite(ageMs)) return false
  if (ageMs < -toleranceMs) return false
  return ageMs <= maxAgeMs
}

/**
 * @param {object} input
 * @param {object} input.target
 * @param {object} input.cits
 * @param {object} input.vision
 * @param {object} input.user
 * @param {object} input.crosswalk
 * @param {object} input.clock
 * @param {object} input.config
 * @param {object|null|undefined} input.history - { lastCitsSeq, lastFrameSeq, lastFrameAdvanceMonoMs, lastMediaTimeMs }
 * @returns {{ checks: object, failedChecks: string[], ages: object, effectiveRemainingSec: number, requiredCrossingSec: number }}
 */
export function evaluateChecks(input) {
  const { target, cits, vision, user, crosswalk, clock, config, history } = input ?? {}

  const targetResult = validateTargetContext(target)
  const citsResult = validateCitsObservation(cits)
  const visionResult = validateVisionObservation(vision)
  const clockResult = validateClock(clock)
  const configResult = validateConfig(config)

  const inputValid =
    targetResult.ok && citsResult.ok && visionResult.ok && clockResult.ok && configResult.ok

  const ages = { citsSourceAgeMs: NaN, citsReceiveAgeMs: NaN, visionAgeMs: NaN }

  if (!inputValid) {
    return {
      checks: { ...allFalseChecks(), inputValid: false },
      failedChecks: [REASONS.INVALID_INPUT],
      ages,
      effectiveRemainingSec: -Infinity,
      requiredCrossingSec: Infinity,
    }
  }

  const checks = { ...allFalseChecks(), inputValid: true }
  const failedChecks = []
  const addFailed = (code) => {
    if (!failedChecks.includes(code)) failedChecks.push(code)
  }

  // targetBound: 계약을 통과했다는 것은 target이 완전히 바인딩됐다는 뜻이다.
  checks.targetBound = true

  // ---- targetMatch (§8.1) ----
  const targetMatch =
    cits.intersectionId === target.intersectionId &&
    cits.crosswalkId === target.crosswalkId &&
    cits.movementId === target.movementId &&
    cits.direction === target.direction &&
    vision.roiBindingId === target.roiBindingId
  checks.targetMatch = targetMatch
  if (!targetMatch) addFailed(REASONS.TARGET_MISMATCH)

  // ---- citsAvailable ----
  checks.citsAvailable = cits.available === true
  if (!checks.citsAvailable) addFailed(REASONS.CITS_MISSING)

  // ---- freshness (§8.2) ----
  const citsSourceAgeMs = clock.nowEpochMs - cits.sourceEpochMs
  const citsReceiveAgeMs = clock.nowMonoMs - cits.receivedAtMonoMs
  const visionAgeMs = clock.nowMonoMs - vision.capturedAtMonoMs
  ages.citsSourceAgeMs = citsSourceAgeMs
  ages.citsReceiveAgeMs = citsReceiveAgeMs
  ages.visionAgeMs = visionAgeMs

  const tol = config.futureClockToleranceMs
  const citsSourceFresh = isFresh(citsSourceAgeMs, config.maxCitsSourceAgeMs, tol)
  const citsReceiveFresh = isFresh(citsReceiveAgeMs, config.maxCitsReceiveAgeMs, tol)
  checks.citsFresh = citsSourceFresh && citsReceiveFresh
  if (!checks.citsFresh) addFailed(REASONS.CITS_STALE)

  checks.visionFresh = isFresh(visionAgeMs, config.maxVisionAgeMs, tol)
  if (!checks.visionFresh) addFailed(REASONS.VISION_STALE)

  // ---- sequence/replay/reorder (§8.3) ----
  const h = history ?? {}
  const citsSeqOk = !(Number.isFinite(h.lastCitsSeq) && cits.seq < h.lastCitsSeq)
  const frameSeqOk = !(Number.isFinite(h.lastFrameSeq) && vision.frameSeq < h.lastFrameSeq)
  checks.sequenceValid = citsSeqOk && frameSeqOk
  if (!checks.sequenceValid) addFailed(REASONS.REPLAY_OR_REORDER)

  // ---- freeze (§8.3) ----
  if (Number.isFinite(h.lastFrameAdvanceMonoMs)) {
    const sinceAdvanceMs = clock.nowMonoMs - h.lastFrameAdvanceMonoMs
    checks.videoAdvancing = sinceAdvanceMs <= config.freezeTimeoutMs
  } else {
    checks.videoAdvancing = true
  }
  if (!checks.videoAdvancing) addFailed(REASONS.VIDEO_FROZEN)

  // ---- 신호/비전 품질 (§8.4) ----
  checks.visionScoreOk = vision.score >= config.minVisionScore
  checks.visionQualityOk = vision.quality >= config.minVisionQuality
  if (!checks.visionScoreOk || !checks.visionQualityOk) addFailed(REASONS.VISION_UNCERTAIN)

  const citsGreen = checks.citsAvailable && cits.color === 'green'
  const citsRed = checks.citsAvailable && cits.color === 'red'
  const visionGreen = vision.color === 'green'

  checks.dualGreen = citsGreen && visionGreen && checks.visionScoreOk && checks.visionQualityOk

  if (checks.citsAvailable && (citsRed || cits.color === 'unknown')) {
    addFailed(REASONS.RED_SIGNAL)
  } else if (citsGreen && vision.color === 'red') {
    addFailed(REASONS.SOURCE_MISMATCH)
  } else if (citsGreen && vision.color === 'unknown') {
    addFailed(REASONS.VISION_UNCERTAIN)
  }

  // ---- 시간 충분성 (§8.5) ----
  const reqSec = computeRequiredCrossingSec({
    lengthM: crosswalk?.lengthM,
    walkingSpeedMps: user?.walkingSpeedMps,
    marginSec: crosswalk?.marginSec,
  })

  const remainingSecValid = Number.isFinite(cits.remainingSec)
  const budgetValid = Number.isFinite(config.latencyBudgetMs)
  const sourceAgeValidForTime = Number.isFinite(citsSourceAgeMs)

  let effectiveRemainingSec
  if (remainingSecValid && budgetValid && sourceAgeValidForTime) {
    effectiveRemainingSec =
      cits.remainingSec - citsSourceAgeMs / 1000 - config.latencyBudgetMs / 1000
  } else {
    effectiveRemainingSec = -Infinity
  }

  const timeSufficient =
    Number.isFinite(effectiveRemainingSec) &&
    Number.isFinite(reqSec) &&
    Number.isFinite(config.confirmHoldMs) &&
    effectiveRemainingSec >= reqSec + config.confirmHoldMs / 1000

  checks.timeSufficient = timeSufficient
  if (!timeSufficient) addFailed(REASONS.TIME_SHORT)

  return {
    checks,
    failedChecks,
    ages,
    effectiveRemainingSec,
    requiredCrossingSec: reqSec,
  }
}
