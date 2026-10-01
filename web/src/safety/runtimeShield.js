/**
 * 비대칭 Runtime Assurance 상태기계 (원본설계서 §9, 스펙 §2.5).
 *
 * WAIT → CONFIRMING → SIGNAL_CONFIRMED
 *
 * 진행 방향(WAIT → CONFIRMING → SIGNAL_CONFIRMED)은 서로 다른 K개의 green
 * 프레임과 hold 시간을 동시에 요구하며 느리게 승인한다. 차단 방향(모든 상태
 * → WAIT)은 재확인 없이 같은 update에서 즉시 반영한다 — 이것이 "비대칭"이다.
 *
 * 브라우저 API·Date.now()/performance.now() 직접 호출 금지 — clock은 input 인자.
 */
import { RTA_CONFIG_V1 } from './config.js'
import { REASONS, MESSAGES, confirmedMessage, pickPrimaryReason } from './reasonCodes.js'
import { evaluateChecks } from './safeGraphChecks.js'

// 즉시(hard) 검사 12종 — distinctFramesOk/holdTimeOk는 shield가 확인 누적으로부터 병합한다.
const HARD_CHECK_KEYS = [
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
]

/**
 * target context를 5필드 join으로 직렬화한다. 필드 중 하나라도 없으면
 * (계약 위반 입력) 구분 가능한 플레이스홀더를 넣어 undefined 필드끼리
 * 우연히 동일한 키로 합쳐지는 것을 방지한다.
 * @param {object|null|undefined} target
 * @returns {string}
 */
function serializeTarget(target) {
  const t = target ?? {}
  const fields = ['intersectionId', 'crosswalkId', 'movementId', 'direction', 'roiBindingId']
  return fields.map((f) => (t[f] === undefined || t[f] === null ? `<missing:${f}>` : String(t[f]))).join('|')
}

function serializeModeKey(cits, vision) {
  return `${cits?.sourceMode ?? '<none>'}|${vision?.sourceMode ?? '<none>'}`
}

/**
 * 입력 계약 불합격/내부 예외 시 사용하는 fail-safe WAIT 출력.
 * @param {string} reason
 * @param {string} configVersion
 * @returns {object}
 */
function fallbackWaitOutput(reason, configVersion) {
  const checks = {}
  for (const key of HARD_CHECK_KEYS) checks[key] = false
  checks.distinctFramesOk = false
  checks.holdTimeOk = false
  return {
    decision: 'WAIT',
    state: 'WAIT',
    reason,
    message: MESSAGES.WAIT,
    checks,
    failedChecks: [reason],
    ages: { citsSourceAgeMs: NaN, citsReceiveAgeMs: NaN, visionAgeMs: NaN },
    effectiveRemainingSec: -Infinity,
    requiredCrossingSec: Infinity,
    confirmation: { distinctGreenFrames: 0, confirmingSinceMonoMs: null },
    configVersion,
  }
}

/**
 * @param {object} params
 * @param {object} [params.config]
 * @returns {{ update(input: object): object, getState(): string, reset(): void }}
 */
export function createRuntimeShield({ config = RTA_CONFIG_V1 } = {}) {
  let state = 'WAIT'
  let history = null // { lastCitsSeq, lastFrameSeq, lastFrameAdvanceMonoMs, lastMediaTimeMs }
  let lastCountedFrameSeq = null
  let distinctGreenFrames = 0
  let confirmingSinceMonoMs = null
  let lastTargetKey = null
  let lastModeKey = null

  function resetAccumulation() {
    history = null
    lastCountedFrameSeq = null
    distinctGreenFrames = 0
    confirmingSinceMonoMs = null
  }

  function resetAll() {
    resetAccumulation()
    state = 'WAIT'
    lastTargetKey = null
    lastModeKey = null
  }

  function advanceHistory(input, hardOk) {
    const cits = input.cits
    const vision = input.vision
    const prev = history

    const frameAdvanced =
      !prev ||
      !Number.isFinite(prev.lastFrameSeq) ||
      vision.frameSeq > prev.lastFrameSeq ||
      !Number.isFinite(prev.lastMediaTimeMs) ||
      vision.mediaTimeMs > prev.lastMediaTimeMs

    const lastFrameAdvanceMonoMs = frameAdvanced
      ? input.clock.nowMonoMs
      : prev
        ? prev.lastFrameAdvanceMonoMs
        : input.clock.nowMonoMs

    history = {
      lastCitsSeq: cits.seq,
      lastFrameSeq: vision.frameSeq,
      lastFrameAdvanceMonoMs,
      lastMediaTimeMs: vision.mediaTimeMs,
    }
  }

  function countDistinctFrameIfNew(frameSeq, nowMonoMs) {
    if (lastCountedFrameSeq !== null && frameSeq <= lastCountedFrameSeq) return
    lastCountedFrameSeq = frameSeq
    distinctGreenFrames += 1
    if (confirmingSinceMonoMs === null) confirmingSinceMonoMs = nowMonoMs
  }

  function buildOutput({ evald, decision, outState, reason, message, distinctFramesOk, holdTimeOk }) {
    const checks = { ...evald.checks, distinctFramesOk, holdTimeOk }
    return {
      decision,
      state: outState,
      reason,
      message,
      checks,
      failedChecks: evald.failedChecks,
      ages: evald.ages,
      effectiveRemainingSec: evald.effectiveRemainingSec,
      requiredCrossingSec: evald.requiredCrossingSec,
      confirmation: {
        distinctGreenFrames,
        confirmingSinceMonoMs,
      },
      configVersion: config.configVersion,
    }
  }

  function isInformationOnlyEligible(evald, input) {
    const failedSet = new Set(evald.failedChecks)
    // Only failure present must be CITS_MISSING, and citsAvailable specifically false.
    if (!failedSet.has(REASONS.CITS_MISSING)) return false
    if (failedSet.size !== 1) return false
    const c = evald.checks
    return (
      c.inputValid &&
      c.targetBound &&
      c.targetMatch &&
      c.visionFresh &&
      c.sequenceValid &&
      c.videoAdvancing &&
      c.visionScoreOk &&
      c.visionQualityOk &&
      c.timeSufficient &&
      input?.vision?.color === 'green'
    )
  }

  function update(input) {
    try {
      if (input === null || input === undefined || typeof input !== 'object') {
        resetAll()
        return fallbackWaitOutput(REASONS.INVALID_INPUT, config.configVersion)
      }

      const targetKey = serializeTarget(input.target)
      const modeKey = serializeModeKey(input.cits, input.vision)
      if (lastTargetKey !== null && (targetKey !== lastTargetKey || modeKey !== lastModeKey)) {
        resetAccumulation()
      }
      lastTargetKey = targetKey
      lastModeKey = modeKey

      const evald = evaluateChecks({ ...input, config, history })

      // inputValid false → INVALID_INPUT WAIT, no history mutation from malformed data.
      if (!evald.checks.inputValid) {
        resetAccumulation()
        state = 'WAIT'
        return buildOutput({
          evald,
          decision: 'WAIT',
          outState: 'WAIT',
          reason: REASONS.INVALID_INPUT,
          message: MESSAGES.WAIT,
          distinctFramesOk: false,
          holdTimeOk: false,
        })
      }

      const hardOk = HARD_CHECK_KEYS.every((k) => evald.checks[k])

      advanceHistory(input, hardOk)

      if (!hardOk) {
        resetAccumulation()
        if (isInformationOnlyEligible(evald, input)) {
          state = 'WAIT'
          return buildOutput({
            evald,
            decision: 'INFORMATION_ONLY',
            outState: 'WAIT',
            reason: REASONS.VISION_ONLY_INFORMATION,
            message: MESSAGES.INFORMATION_ONLY,
            distinctFramesOk: false,
            holdTimeOk: false,
          })
        }
        state = 'WAIT'
        const reason = pickPrimaryReason(evald.failedChecks)
        return buildOutput({
          evald,
          decision: 'WAIT',
          outState: 'WAIT',
          reason,
          message: MESSAGES.WAIT,
          distinctFramesOk: false,
          holdTimeOk: false,
        })
      }

      // All 12 hard checks pass this tick — count distinct frame progress.
      countDistinctFrameIfNew(input.vision.frameSeq, input.clock.nowMonoMs)

      const distinctFramesOk = distinctGreenFrames >= config.minDistinctGreenFrames
      const holdTimeOk =
        confirmingSinceMonoMs !== null &&
        input.clock.nowMonoMs - confirmingSinceMonoMs >= config.confirmHoldMs

      if (distinctFramesOk && holdTimeOk) {
        state = 'SIGNAL_CONFIRMED'
        return buildOutput({
          evald,
          decision: 'SIGNAL_CONFIRMED',
          outState: 'SIGNAL_CONFIRMED',
          reason: REASONS.SAFEGRAPH_CONFIRMED,
          message: confirmedMessage(Math.floor(evald.effectiveRemainingSec)),
          distinctFramesOk: true,
          holdTimeOk: true,
        })
      }

      state = 'CONFIRMING'
      return buildOutput({
        evald,
        decision: 'VERIFYING',
        outState: 'CONFIRMING',
        reason: REASONS.CONFIRMING,
        message: MESSAGES.VERIFYING,
        distinctFramesOk,
        holdTimeOk,
      })
    } catch {
      // config itself may be the thing throwing (e.g. a malformed/hostile
      // config object) — never trust it again once an exception has been
      // observed. Fall back to the known-safe default's version string.
      try {
        resetAll()
      } catch {
        // resetAll() only touches closure state, but stay defensive: a
        // partially-corrupted closure must still not escape as an exception.
      }
      return fallbackWaitOutput(REASONS.INTERNAL_ERROR, RTA_CONFIG_V1.configVersion)
    }
  }

  function getState() {
    return state
  }

  function reset() {
    resetAll()
  }

  return { update, getState, reset }
}
