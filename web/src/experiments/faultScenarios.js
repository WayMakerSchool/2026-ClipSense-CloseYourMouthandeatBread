/**
 * Deterministic fault-injection scenario traces (원본설계서 §12, 스펙 §2.7).
 *
 * 11 scenarios, each a fixed 100-tick (TICK_MS=100 → DURATION_MS=10000)
 * trace replayed identically by BOTH the experiment runner and the UI's
 * fault-injector buttons — single source of truth (스펙 §2.7).
 *
 * riskClass (spec §2.7):
 *   SAFE:     NORMAL_GREEN
 *   PHYSICAL (UAER denominator):  SINGLE_FALSE_GREEN, TIME_SHORT,
 *             TRUE_GREEN_TO_RED, PERSISTENT_COMMON_CAUSE
 *   CONTRACT (CVER denominator):  WRONG_TARGET_GREEN, STALE_CITS_GREEN,
 *             REORDERED_PACKET, FROZEN_GREEN_VIDEO, CAMERA_OCCLUDED,
 *             TARGET_SWITCH_MID_CONFIRM
 *
 * groundTruth is fixed by this module (not derived by an evaluation
 * algorithm — 원본 §12: "ground truth는 시나리오 정의에 고정").
 *
 * Documented deterministic fault onsets (all times in ms from trace start,
 * tick index = ms / TICK_MS):
 *   - STALE_CITS_GREEN:          cits feed freezes at t=2000ms (tick 20).
 *                                 groundTruth.unsafe flips true once
 *                                 (nowEpochMs - sourceEpochMs) exceeds
 *                                 RTA_CONFIG_V1.maxCitsSourceAgeMs (2000ms).
 *   - REORDERED_PACKET:          from t=2000ms (tick 20) onward, an injected
 *                                 seq that is STRICTLY LOWER than the
 *                                 previous tick's seq every single tick of
 *                                 the fault window (not a constant replay —
 *                                 a constant value only fails sequenceValid
 *                                 once, since history.lastCitsSeq latches
 *                                 onto it and `seq < lastCitsSeq` never
 *                                 re-triggers, letting the shield silently
 *                                 re-confirm inside the unsafe window).
 *                                 unsafe from tick 20 onward.
 *   - FROZEN_GREEN_VIDEO:        vision feed (frameSeq/mediaTimeMs/
 *                                 capturedAtMonoMs) freezes at t=2000ms
 *                                 (tick 20). unsafe once frozen duration
 *                                 exceeds freezeTimeoutMs (750ms).
 *   - TRUE_GREEN_TO_RED:         both cits and vision flip green->red at
 *                                 t=6000ms (tick 60). unsafe only from the
 *                                 flip onward.
 *   - TARGET_SWITCH_MID_CONFIRM: bound target changes to a different
 *                                 crosswalk/movement at t=3000ms (tick 30).
 *                                 unsafe from that tick onward.
 *   - SINGLE_FALSE_GREEN:        cits red for the entire trace; vision red
 *                                 for the entire trace EXCEPT one green tick
 *                                 at t=3000ms (tick 30, score .9). unsafe
 *                                 throughout (actual signal is red).
 *   - CAMERA_OCCLUDED:           vision color 'unknown' + quality 0.2 for
 *                                 the entire trace. unsafe throughout.
 *   - TIME_SHORT:                dual green for the entire trace but
 *                                 cits.remainingSec pinned at 8s (below
 *                                 requiredCrossingSec ~18.67s). unsafe
 *                                 throughout.
 *   - WRONG_TARGET_GREEN:        cits.crosswalkId/movementId AND
 *                                 vision.roiBindingId differ from the bound
 *                                 target for the entire trace (원본 §12:
 *                                 "C-ITS/ROI가 초록"). unsafe throughout.
 *   - PERSISTENT_COMMON_CAUSE:   both sources green, correct target IDs,
 *                                 fresh timestamps for the ENTIRE trace —
 *                                 yet groundTruth.unsafe=true throughout
 *                                 because the actual physical signal is red
 *                                 (residual-risk limit case, 원본 §12: "규칙
 *                                 기반 Shield도 이를 식별하지 못할 수 있다").
 *   - NORMAL_GREEN:               no fault; unsafe=false throughout.
 */

import { RTA_CONFIG_V1 } from '../safety/config.js'

export const TICK_MS = 100
export const DURATION_MS = 10000
export const TICK_COUNT = DURATION_MS / TICK_MS // 100

const BASE_EPOCH = 1784780000000
const BASE_MONO = 1_000_000

// Fault-onset ground-truth transitions reuse the SAME thresholds the runtime
// shield enforces — thresholds live only in src/safety/config.js (global
// constraint #7), never duplicated here as magic numbers.
const CITS_SOURCE_AGE_LIMIT_MS = RTA_CONFIG_V1.maxCitsSourceAgeMs
const FREEZE_TIMEOUT_MS = RTA_CONFIG_V1.freezeTimeoutMs

const STALE_ONSET_TICK = 20 // t=2000ms
const REORDER_ONSET_TICK = 20 // t=2000ms
const FREEZE_ONSET_TICK = 20 // t=2000ms
const TARGET_SWITCH_TICK = 30 // t=3000ms
const SINGLE_FALSE_GREEN_TICK = 30 // t=3000ms
const TRUE_GREEN_TO_RED_TICK = 60 // t=6000ms

function baseTarget() {
  return {
    intersectionId: 'demo-int-001',
    crosswalkId: 'demo-cw-north-01',
    movementId: 'demo-ped-move-01',
    direction: 'NORTHBOUND',
    roiBindingId: 'roi-ped-north-01',
    bindingMethod: 'MANUAL_DEMO',
  }
}

function altTarget() {
  return {
    intersectionId: 'demo-int-001',
    crosswalkId: 'demo-cw-east-02',
    movementId: 'demo-ped-move-02',
    direction: 'EASTBOUND',
    roiBindingId: 'roi-ped-east-02',
    bindingMethod: 'MANUAL_DEMO',
  }
}

/** Normal-baseline cits observation at tick i (원본 §6.2 / 스펙 §2.7 기저값). */
function normalCits(i, target) {
  const nowEpochMs = BASE_EPOCH + i * TICK_MS
  const nowMonoMs = BASE_MONO + i * TICK_MS
  return {
    available: true,
    color: 'green',
    remainingSec: Math.max(0, 35 - i * (TICK_MS / 1000)), // 35s countdown
    intersectionId: target.intersectionId,
    crosswalkId: target.crosswalkId,
    movementId: target.movementId,
    direction: target.direction,
    sourceEpochMs: nowEpochMs - 200,
    receivedAtMonoMs: nowMonoMs - 100,
    seq: 100 + Math.floor(i / 5), // +1 per 500ms (5 ticks @ 100ms)
    sourceMode: 'MOCK',
  }
}

/** Normal-baseline vision observation at tick i (원본 §6.3 / 스펙 §2.7 기저값). */
function normalVision(i, target) {
  const nowMonoMs = BASE_MONO + i * TICK_MS
  return {
    color: 'green',
    score: 0.9,
    quality: 0.8,
    roiBindingId: target.roiBindingId,
    capturedAtMonoMs: nowMonoMs - 50,
    frameSeq: 200 + i, // +1 per tick
    mediaTimeMs: 5000 + i * TICK_MS,
    sourceMode: 'MOCK',
  }
}

function normalGroundTruth() {
  return { unsafe: false, faultActive: false, faultType: null }
}

function faultGroundTruth(faultType) {
  return { unsafe: true, faultActive: true, faultType }
}

/**
 * Builds one tick's full input, starting from the normal baseline and
 * applying scenario-specific field overrides + groundTruth via `mutate`.
 * @param {number} i tick index (0-based)
 * @param {(ctx: object) => void} [mutate] mutates the tick fields in place
 * @returns {object}
 */
function buildTick(i, mutate) {
  const nowEpochMs = BASE_EPOCH + i * TICK_MS
  const nowMonoMs = BASE_MONO + i * TICK_MS
  const target = baseTarget()

  const tick = {
    tickIndex: i,
    clock: { nowEpochMs, nowMonoMs },
    target,
    cits: normalCits(i, target),
    vision: normalVision(i, target),
    user: { walkingSpeedMps: 0.6 },
    crosswalk: { lengthM: 10, marginSec: 2 },
    groundTruth: normalGroundTruth(),
  }

  if (mutate) mutate(tick, i)

  return tick
}

function buildNormalGreen() {
  return Array.from({ length: TICK_COUNT }, (_, i) => buildTick(i))
}

function buildWrongTargetGreen() {
  return Array.from({ length: TICK_COUNT }, (_, i) =>
    buildTick(i, (tick) => {
      // cits/vision both report an adjacent crosswalk's green — the bound
      // target itself stays correct, but BOTH observations are for a
      // DIFFERENT movement (원본 §12: "인접 횡단보도 C-ITS/ROI가 초록").
      tick.cits.crosswalkId = 'demo-cw-east-02'
      tick.cits.movementId = 'demo-ped-move-02'
      tick.cits.direction = 'EASTBOUND'
      tick.vision.roiBindingId = 'roi-ped-east-01'
      tick.groundTruth = faultGroundTruth('WRONG_TARGET_GREEN')
    })
  )
}

function buildStaleCitsGreen() {
  let frozen = null
  return Array.from({ length: TICK_COUNT }, (_, i) =>
    buildTick(i, (tick) => {
      if (i >= STALE_ONSET_TICK) {
        if (!frozen) {
          frozen = {
            sourceEpochMs: tick.cits.sourceEpochMs,
            receivedAtMonoMs: tick.cits.receivedAtMonoMs,
            seq: tick.cits.seq,
          }
        }
        tick.cits.sourceEpochMs = frozen.sourceEpochMs
        tick.cits.receivedAtMonoMs = frozen.receivedAtMonoMs
        tick.cits.seq = frozen.seq
      }
      const ageMs = tick.clock.nowEpochMs - tick.cits.sourceEpochMs
      tick.groundTruth =
        ageMs > CITS_SOURCE_AGE_LIMIT_MS ? faultGroundTruth('STALE_CITS_GREEN') : normalGroundTruth()
    })
  )
}

function buildReorderedPacket() {
  let peakSeq = 0
  return Array.from({ length: TICK_COUNT }, (_, i) =>
    buildTick(i, (tick) => {
      if (i < REORDER_ONSET_TICK) {
        peakSeq = tick.cits.seq
        return
      }
      // Replay a lower seq than what has already been observed AND keep it
      // strictly decreasing tick over tick. A constant repeated seq would
      // only fail sequenceValid on the FIRST injected tick (history.lastCitsSeq
      // then latches onto that same value, so `cits.seq < lastCitsSeq` never
      // re-triggers) — the shield would silently re-accumulate distinct green
      // frames and reach SIGNAL_CONFIRMED again inside the unsafe window
      // (reviewer-caught CVER distortion). Strictly decreasing seq makes
      // REPLAY_OR_REORDER fire on every single tick of the fault window, so
      // hardOk never holds and the shield can never re-confirm.
      tick.cits.seq = Math.max(0, peakSeq - 5 - (i - REORDER_ONSET_TICK))
      tick.groundTruth = faultGroundTruth('REORDERED_PACKET')
    })
  )
}

function buildFrozenGreenVideo() {
  let frozen = null
  return Array.from({ length: TICK_COUNT }, (_, i) =>
    buildTick(i, (tick) => {
      if (i >= FREEZE_ONSET_TICK) {
        if (!frozen) {
          frozen = {
            frameSeq: tick.vision.frameSeq,
            mediaTimeMs: tick.vision.mediaTimeMs,
            capturedAtMonoMs: tick.vision.capturedAtMonoMs,
          }
        }
        tick.vision.frameSeq = frozen.frameSeq
        tick.vision.mediaTimeMs = frozen.mediaTimeMs
        tick.vision.capturedAtMonoMs = frozen.capturedAtMonoMs
      }
      const frozenForMs = i >= FREEZE_ONSET_TICK ? (i - FREEZE_ONSET_TICK) * TICK_MS : 0
      tick.groundTruth =
        frozenForMs > FREEZE_TIMEOUT_MS ? faultGroundTruth('FROZEN_GREEN_VIDEO') : normalGroundTruth()
    })
  )
}

function buildSingleFalseGreen() {
  return Array.from({ length: TICK_COUNT }, (_, i) =>
    buildTick(i, (tick) => {
      tick.cits.color = 'red'
      tick.cits.remainingSec = 0
      if (i === SINGLE_FALSE_GREEN_TICK) {
        tick.vision.color = 'green'
        tick.vision.score = 0.9
      } else {
        tick.vision.color = 'red'
        tick.vision.score = 0.05
      }
      tick.groundTruth = faultGroundTruth('SINGLE_FALSE_GREEN')
    })
  )
}

function buildCameraOccluded() {
  return Array.from({ length: TICK_COUNT }, (_, i) =>
    buildTick(i, (tick) => {
      tick.vision.color = 'unknown'
      tick.vision.quality = 0.2
      tick.vision.score = 0.1
      tick.groundTruth = faultGroundTruth('CAMERA_OCCLUDED')
    })
  )
}

function buildTimeShort() {
  return Array.from({ length: TICK_COUNT }, (_, i) =>
    buildTick(i, (tick) => {
      tick.cits.remainingSec = 8
      tick.groundTruth = faultGroundTruth('TIME_SHORT')
    })
  )
}

function buildTargetSwitchMidConfirm() {
  return Array.from({ length: TICK_COUNT }, (_, i) =>
    buildTick(i, (tick) => {
      if (i >= TARGET_SWITCH_TICK) {
        const newTarget = altTarget()
        tick.target = newTarget
        // Sensors have NOT rebound to the new target yet — they still report
        // the OLD crosswalk/movement/roi, producing a target mismatch.
        tick.groundTruth = faultGroundTruth('TARGET_SWITCH_MID_CONFIRM')
      }
    })
  )
}

function buildTrueGreenToRed() {
  return Array.from({ length: TICK_COUNT }, (_, i) =>
    buildTick(i, (tick) => {
      if (i >= TRUE_GREEN_TO_RED_TICK) {
        tick.cits.color = 'red'
        tick.cits.remainingSec = 0
        tick.vision.color = 'red'
        tick.vision.score = 0.05
        tick.groundTruth = faultGroundTruth('TRUE_GREEN_TO_RED')
      }
    })
  )
}

function buildPersistentCommonCause() {
  return Array.from({ length: TICK_COUNT }, (_, i) =>
    buildTick(i, (tick) => {
      // Both sources agree, target IDs are correct, timestamps stay fresh —
      // indistinguishable from a true green by any contract-level check.
      // The residual risk: the ACTUAL physical signal is red the whole time.
      tick.groundTruth = faultGroundTruth('PERSISTENT_COMMON_CAUSE')
    })
  )
}

const BUILDERS = {
  NORMAL_GREEN: buildNormalGreen,
  WRONG_TARGET_GREEN: buildWrongTargetGreen,
  STALE_CITS_GREEN: buildStaleCitsGreen,
  REORDERED_PACKET: buildReorderedPacket,
  FROZEN_GREEN_VIDEO: buildFrozenGreenVideo,
  SINGLE_FALSE_GREEN: buildSingleFalseGreen,
  CAMERA_OCCLUDED: buildCameraOccluded,
  TIME_SHORT: buildTimeShort,
  TARGET_SWITCH_MID_CONFIRM: buildTargetSwitchMidConfirm,
  TRUE_GREEN_TO_RED: buildTrueGreenToRed,
  PERSISTENT_COMMON_CAUSE: buildPersistentCommonCause,
}

export const SCENARIOS = Object.freeze({
  NORMAL_GREEN: {
    label: '정상 이중 초록',
    riskClass: 'SAFE',
    description: '동일 target에서 C-ITS와 vision이 fresh dual green을 유지한다. 결함 없음.',
  },
  WRONG_TARGET_GREEN: {
    label: '인접 대상 오신호',
    riskClass: 'CONTRACT',
    description: '인접 횡단보도의 C-ITS 신호가 초록으로 들어와 target과 불일치한다.',
  },
  STALE_CITS_GREEN: {
    label: '오래된 C-ITS 초록',
    riskClass: 'CONTRACT',
    description: 'C-ITS 패킷 갱신이 t=2000ms에 멈춰 신선도 한계를 초과한다.',
  },
  REORDERED_PACKET: {
    label: '재정렬/재전송 패킷',
    riskClass: 'CONTRACT',
    description: 't=2000ms부터 더 작은 seq의 패킷이 반복 주입된다.',
  },
  FROZEN_GREEN_VIDEO: {
    label: '정지된 초록 영상',
    riskClass: 'CONTRACT',
    description: '비전 프레임이 t=2000ms에 멈춰 frameSeq/mediaTimeMs가 더 이상 진행하지 않는다.',
  },
  SINGLE_FALSE_GREEN: {
    label: '단일 프레임 오인식',
    riskClass: 'PHYSICAL',
    description: '실제 signal은 red이며, t=3000ms 한 프레임만 vision이 green으로 오인식한다.',
  },
  CAMERA_OCCLUDED: {
    label: '카메라 가림/저품질',
    riskClass: 'CONTRACT',
    description: '비전이 전체 구간 unknown 색상 및 저품질(quality=0.2)로만 관측된다.',
  },
  TIME_SHORT: {
    label: '시간 부족',
    riskClass: 'PHYSICAL',
    description: '두 소스 모두 green이나 잔여시간(8s)이 필요 횡단시간보다 짧다.',
  },
  TARGET_SWITCH_MID_CONFIRM: {
    label: '확인 중 대상 전환',
    riskClass: 'CONTRACT',
    description: 't=3000ms에 바인딩된 target이 다른 횡단보도로 전환되어 센서가 구 target을 계속 보고한다.',
  },
  TRUE_GREEN_TO_RED: {
    label: '초록에서 빨강 전환',
    riskClass: 'PHYSICAL',
    description: 't=6000ms에 두 소스 모두 green에서 red로 전환된다.',
  },
  PERSISTENT_COMMON_CAUSE: {
    label: '지속적 공통원인 오신호',
    riskClass: 'PHYSICAL',
    description:
      '두 소스가 동일 target·fresh timestamp로 전체 구간 동일한 거짓 초록을 보고하는 잔존 위험 한계 시험.',
  },
})

export const SCENARIO_IDS = Object.freeze(Object.keys(SCENARIOS))

/**
 * @param {string} scenarioId one of SCENARIO_IDS
 * @returns {{ scenarioId: string, riskClass: string, ticks: object[] }}
 */
export function buildTrace(scenarioId) {
  const builder = BUILDERS[scenarioId]
  if (!builder) {
    throw new Error(`faultScenarios.buildTrace: unknown scenarioId "${scenarioId}"`)
  }
  return {
    scenarioId,
    riskClass: SCENARIOS[scenarioId].riskClass,
    ticks: builder(),
  }
}
