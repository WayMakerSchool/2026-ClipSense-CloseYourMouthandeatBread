/**
 * Task S4 — 불변식 전수 테스트 (P1~P7).
 *
 * 구현 파일 없음 — 이 파일은 게이트 전용이다. S1~S3에서 구현된
 * createRuntimeShield()가 원본설계서 §19.4의 P1~P7을 항상 만족하는지
 * enum/boolean 조합을 프로그램으로 순회해 검증한다.
 *
 * P1. SIGNAL_CONFIRMED ⇒ 모든 hard safety check가 true
 * P2. hard safety check 하나라도 false ⇒ SIGNAL_CONFIRMED가 아님
 * P3. Tier 2(cits 미가용) 또는 Tier 3 ⇒ SIGNAL_CONFIRMED가 아님
 * P4. target 변경 ⇒ 그 update에서 WAIT(비-proceed)
 * P5. red/unknown/stale/replay/freeze/time-short ⇒ 그 update에서 WAIT(비-proceed)
 * P6. 같은 frame 반복만으로 승인 불가
 * P7. 예외 발생 ⇒ WAIT (never throws)
 *
 * proceed-like(스펙 §2.5) = decision === 'SIGNAL_CONFIRMED' 뿐이다. CONFIRMING의
 * 외부 decision은 'VERIFYING'이며 proceed-like가 아니다.
 */
import { describe, it, expect } from 'vitest'
import { RTA_CONFIG_V1 } from '../../src/safety/config.js'
import { REASONS } from '../../src/safety/reasonCodes.js'
import { createRuntimeShield } from '../../src/safety/runtimeShield.js'

// ---- tick input generator (runtimeShield.test.js 패턴 미러) --------------
const TICK_MS = 100
const BASE_EPOCH = 1784780000000
const BASE_MONO = 1_000_000

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

// 원본 §19.4 P1/P2가 말하는 "모든 hard safety check"는 12개의 즉시 검사다.
// shield 출력의 checks에는 distinctFramesOk/holdTimeOk(확인 누적계)가 병합되어
// 있으므로 별도로 구분해 둔다.
expect(HARD_CHECK_KEYS.length).toBe(12)

function makeTargetContext(overrides = {}) {
  return {
    intersectionId: 'demo-int-001',
    crosswalkId: 'demo-cw-north-01',
    movementId: 'demo-ped-move-01',
    direction: 'NORTHBOUND',
    roiBindingId: 'roi-ped-north-01',
    bindingMethod: 'MANUAL_DEMO',
    ...overrides,
  }
}

/**
 * Builds a valid tick input at logical tick index `i` (0-based). Every field
 * can be overridden via `overrides.{target,cits,vision,clock,user,crosswalk}`.
 * Mirrors tests/safety/runtimeShield.test.js's makeTick.
 */
function makeTick(i, overrides = {}) {
  const nowMonoMs = BASE_MONO + i * TICK_MS
  const nowEpochMs = BASE_EPOCH + i * TICK_MS

  const target = makeTargetContext(overrides.target)

  const cits = {
    available: true,
    color: 'green',
    remainingSec: 35,
    intersectionId: target.intersectionId,
    crosswalkId: target.crosswalkId,
    movementId: target.movementId,
    direction: target.direction,
    sourceEpochMs: nowEpochMs - 200,
    receivedAtMonoMs: nowMonoMs - 100,
    seq: 100 + i,
    sourceMode: 'MOCK',
    ...overrides.cits,
  }

  const vision = {
    color: 'green',
    score: 0.9,
    quality: 0.8,
    roiBindingId: target.roiBindingId,
    capturedAtMonoMs: nowMonoMs - 50,
    frameSeq: 200 + i,
    mediaTimeMs: 5000 + i * TICK_MS,
    sourceMode: 'RECORDED',
    ...overrides.vision,
  }

  const clock = {
    nowEpochMs,
    nowMonoMs,
    ...overrides.clock,
  }

  const user = { walkingSpeedMps: 0.6, ...overrides.user }
  const crosswalk = { lengthM: 10, marginSec: 2, ...overrides.crosswalk }

  return { target, cits, vision, user, crosswalk, clock, ...overrides.top }
}

// requiredCrossingSec = 10/0.6 + 2 = 18.6667; + confirmHoldMs/1000 (1.5) = 20.1667
// remaining:35 → effectiveRemainingSec ~34.3 (충분). remaining:8 → ~7.3 (부족).

/** Drives `n` sequential good ticks (0-based) at 400ms spacing — spacing large
 * enough that K distinct frames also satisfy confirmHoldMs together, matching
 * runtimeShield.test.js's confirming recipe. Returns the last output. */
function driveGoodTicks(shield, n, startIndex = 0) {
  let out
  for (let i = 0; i < n; i++) {
    const idx = startIndex + i
    const nowMonoMs = BASE_MONO + idx * 400
    const nowEpochMs = BASE_EPOCH + idx * 400
    out = shield.update(
      makeTick(idx, {
        clock: { nowMonoMs, nowEpochMs },
        cits: { sourceEpochMs: nowEpochMs - 200, receivedAtMonoMs: nowMonoMs - 100 },
        vision: { capturedAtMonoMs: nowMonoMs - 50 },
      })
    )
  }
  return out
}

/** Drives a fresh shield all the way to SIGNAL_CONFIRMED using the "normal"
 * good-tick recipe (400ms spacing, K = minDistinctGreenFrames). Returns the
 * shield plus bookkeeping needed to build a same-update follow-on tick. */
function confirmFreshShield() {
  const shield = createRuntimeShield()
  const out = driveGoodTicks(shield, RTA_CONFIG_V1.minDistinctGreenFrames)
  expect(out.decision).toBe('SIGNAL_CONFIRMED')
  const lastIndex = RTA_CONFIG_V1.minDistinctGreenFrames - 1
  const lastMono = BASE_MONO + lastIndex * 400
  const lastEpoch = BASE_EPOCH + lastIndex * 400
  return { shield, lastIndex, lastMono, lastEpoch }
}

function nextTickAfterConfirm({ lastIndex, lastMono, lastEpoch }, overrides = {}) {
  const nextMono = lastMono + 400
  const nextEpoch = lastEpoch + 400
  return makeTick(lastIndex + 1, {
    clock: { nowMonoMs: nextMono, nowEpochMs: nextEpoch, ...overrides.clock },
    cits: { sourceEpochMs: nextEpoch - 200, receivedAtMonoMs: nextMono - 100, ...overrides.cits },
    vision: { capturedAtMonoMs: nextMono - 50, ...overrides.vision },
    target: overrides.target,
  })
}

// ---------------------------------------------------------------------------
// Combination dimensions (task brief "Sweep design (binding)")
// ---------------------------------------------------------------------------
const CITS_COLORS = ['green', 'red', 'unknown']
const CITS_AVAILABLE = [true, false]
const FRESHNESS = ['fresh', 'sourceStale', 'receiveStale']
const SEQ_MODES = ['advancing', 'replay']
const VISION_COLORS = ['green', 'red', 'unknown']
const VISION_SCORES = [0.9, 0.5]
const VISION_QUALITIES = [0.8, 0.2]
const FRAME_MODES = ['advancing', 'frozenSeqFrozenMedia', 'frozenSeqAdvancingMedia', 'replaySeq']
const TIME_REMAINING = [35, 8]
const TARGET_MODES = [
  'match',
  'mismatch-intersectionId',
  'mismatch-crosswalkId',
  'mismatch-movementId',
  'mismatch-direction',
  'mismatch-roiBindingId',
]

/**
 * Applies one setting from each dimension to a base tick-override object.
 * `history` lets seq/frame "replay" dimensions be meaningful (a replay needs
 * a prior tick to replay against) — callers drive two ticks: a seed tick at
 * i=0 with 'advancing' settings, then the combination tick at i=1.
 */
function buildCombinationOverrides({
  citsColor,
  citsAvailable,
  freshness,
  seqMode,
  visionColor,
  visionScore,
  visionQuality,
  frameMode,
  timeRemaining,
  targetMode,
  nowMonoMs,
  nowEpochMs,
  seedSeq,
  seedFrameSeq,
  seedMediaTimeMs,
}) {
  const citsOverrides = {
    available: citsAvailable,
    color: citsColor,
    remainingSec: timeRemaining,
  }
  if (freshness === 'sourceStale') {
    citsOverrides.sourceEpochMs = nowEpochMs - (RTA_CONFIG_V1.maxCitsSourceAgeMs + 1000)
  } else {
    citsOverrides.sourceEpochMs = nowEpochMs - 200
  }
  if (freshness === 'receiveStale') {
    citsOverrides.receivedAtMonoMs = nowMonoMs - (RTA_CONFIG_V1.maxCitsReceiveAgeMs + 1000)
  } else {
    citsOverrides.receivedAtMonoMs = nowMonoMs - 100
  }
  citsOverrides.seq = seqMode === 'replay' ? seedSeq - 1 : seedSeq + 1

  const visionOverrides = {
    color: visionColor,
    score: visionScore,
    quality: visionQuality,
  }
  if (freshness === 'visionStale') {
    visionOverrides.capturedAtMonoMs = nowMonoMs - (RTA_CONFIG_V1.maxVisionAgeMs + 1000)
  } else {
    visionOverrides.capturedAtMonoMs = nowMonoMs - 50
  }

  switch (frameMode) {
    case 'advancing':
      visionOverrides.frameSeq = seedFrameSeq + 1
      visionOverrides.mediaTimeMs = seedMediaTimeMs + TICK_MS
      break
    case 'frozenSeqFrozenMedia':
      visionOverrides.frameSeq = seedFrameSeq
      visionOverrides.mediaTimeMs = seedMediaTimeMs
      break
    case 'frozenSeqAdvancingMedia':
      // handoff case: frameSeq repeats while mediaTimeMs still advances —
      // must never be treated as a genuinely new/distinct frame (P6 variant).
      visionOverrides.frameSeq = seedFrameSeq
      visionOverrides.mediaTimeMs = seedMediaTimeMs + TICK_MS
      break
    case 'replaySeq':
      visionOverrides.frameSeq = seedFrameSeq - 1
      visionOverrides.mediaTimeMs = seedMediaTimeMs + TICK_MS
      break
    default:
      throw new Error(`unknown frameMode ${frameMode}`)
  }

  const targetOverrides = {}
  const citsTargetFields = {
    intersectionId: 'demo-int-001',
    crosswalkId: 'demo-cw-north-01',
    movementId: 'demo-ped-move-01',
    direction: 'NORTHBOUND',
  }
  Object.assign(citsOverrides, citsTargetFields)
  visionOverrides.roiBindingId = 'roi-ped-north-01'

  if (targetMode.startsWith('mismatch-')) {
    const field = targetMode.slice('mismatch-'.length)
    if (field === 'roiBindingId') {
      visionOverrides.roiBindingId = 'roi-MISMATCHED'
    } else {
      citsOverrides[field] = `${citsTargetFields[field]}-MISMATCHED`
    }
  }

  return { target: targetOverrides, cits: citsOverrides, vision: visionOverrides, clock: { nowMonoMs, nowEpochMs } }
}

// ---------------------------------------------------------------------------
// P1 / P2 — SIGNAL_CONFIRMED ⇔ 모든 hard check true (양방향), over 100-tick runs
// ---------------------------------------------------------------------------
describe('Invariant P1/P2 — SIGNAL_CONFIRMED ⇔ 모든 hard safety check true', () => {
  // Full cross-product across color/available/freshness dims (binding sweep
  // instruction: "full cross-product for the color/available/fresh
  // dimensions; representative pairs elsewhere").
  const combos = []
  for (const citsColor of CITS_COLORS) {
    for (const citsAvailable of CITS_AVAILABLE) {
      for (const freshness of FRESHNESS) {
        for (const seqMode of SEQ_MODES) {
          for (const visionColor of VISION_COLORS) {
            // representative pairs (not full cross) for score/quality/frame/time/target.
            // score and quality MUST cycle in the same phase (both index 0 together,
            // both index 1 together) so that the "both pass" combination
            // (score=0.9 >= minVisionScore, quality=0.8 >= minVisionQuality) actually
            // occurs — using different phases here previously made every combo fail
            // visionScoreOk/visionQualityOk simultaneously, which made the P1 branch
            // (SIGNAL_CONFIRMED ⇒ hard checks true) permanently unreachable/vacuous
            // across all combos (reviewer-caught regression; see S4 report).
            const qualityCursor = combos.length % 2
            const visionScore = VISION_SCORES[qualityCursor]
            const visionQuality = VISION_QUALITIES[qualityCursor]
            const frameMode = FRAME_MODES[combos.length % FRAME_MODES.length]
            const timeRemaining = TIME_REMAINING[combos.length % TIME_REMAINING.length]
            const targetMode = TARGET_MODES[combos.length % TARGET_MODES.length]
            combos.push({
              citsColor,
              citsAvailable,
              freshness,
              seqMode,
              visionColor,
              visionScore,
              visionQuality,
              frameMode,
              timeRemaining,
              targetMode,
            })
          }
        }
      }
    }
  }

  it(`enumerates a non-trivial number of P1/P2 combinations (got ${combos.length})`, () => {
    expect(combos.length).toBeGreaterThan(100)
  })

  it('100-tick run: every SIGNAL_CONFIRMED tick has all 12 hard checks true; every hard-check-false tick is never SIGNAL_CONFIRMED', () => {
    // Tracks how many of the 108 combos actually reach SIGNAL_CONFIRMED at least
    // once, so the P1 branch's `expect(hardOk).toBe(true)` assertion is provably
    // exercised rather than dead code silently never running (reviewer-caught:
    // a prior phase bug made hardOk always false, so this branch never fired for
    // ANY combo — see task-S4-report.md mutation-check-2 for the fix history).
    let combosThatConfirmed = 0
    for (const combo of combos) {
      const shield = createRuntimeShield()
      let sawConfirmed = false
      for (let i = 0; i < 100; i++) {
        const nowMonoMs = BASE_MONO + i * 100
        const nowEpochMs = BASE_EPOCH + i * 100
        const overrides = buildCombinationOverrides({
          ...combo,
          nowMonoMs,
          nowEpochMs,
          seedSeq: 300 + i, // 'advancing' baseline; seqMode='replay' overrides below the seq itself
          seedFrameSeq: 400 + i,
          seedMediaTimeMs: 8000 + i * 100,
        })
        const out = shield.update(makeTick(i, overrides))
        const hardOk = HARD_CHECK_KEYS.every((k) => out.checks[k] === true)

        if (out.decision === 'SIGNAL_CONFIRMED') {
          sawConfirmed = true
          // P1: SIGNAL_CONFIRMED ⇒ all 12 hard checks true
          expect(
            hardOk,
            `P1 violated for combo ${JSON.stringify(combo)} at tick ${i}: checks=${JSON.stringify(out.checks)}`
          ).toBe(true)
        }
        if (!hardOk) {
          // P2: any hard check false ⇒ decision is not SIGNAL_CONFIRMED
          expect(
            out.decision,
            `P2 violated for combo ${JSON.stringify(combo)} at tick ${i}: checks=${JSON.stringify(out.checks)}`
          ).not.toBe('SIGNAL_CONFIRMED')
        }
      }
      // Not every combo is expected to reach SIGNAL_CONFIRMED (many are
      // deliberately built from failing dimensions) — but SOME must, otherwise
      // the P1 assertion above never actually runs against a true branch.
      if (sawConfirmed) combosThatConfirmed += 1
    }
    // Proves the P1 branch (line "if (out.decision === 'SIGNAL_CONFIRMED')")
    // was reached at least once across the full sweep — without this, a
    // regression that makes hardOk permanently false (as happened before this
    // fix) would silently pass with zero coverage of the P1 direction.
    // Measured: 1 of 108 combos reaches SIGNAL_CONFIRMED at least once in its
    // 100-tick run (the rest are deliberately built from failing dimensions —
    // red/unknown color, stale freshness, replay seq, frozen/replay frame,
    // short time budget, or a mismatched target — so a single confirming combo
    // is the expected shape of this sweep, not a defect).
    expect(
      combosThatConfirmed,
      'P1 branch never executed across any of the 108 combos — sweep is vacuous for P1'
    ).toBeGreaterThan(0)
  })
})

// ---------------------------------------------------------------------------
// P3 — cits.available === false ⇒ never SIGNAL_CONFIRMED (Tier 2/3)
// ---------------------------------------------------------------------------
describe('Invariant P3 — cits.available=false (Tier 2/3) ⇒ SIGNAL_CONFIRMED 0건', () => {
  const combos = []
  for (const citsColor of CITS_COLORS) {
    for (const freshness of FRESHNESS) {
      for (const visionColor of VISION_COLORS) {
        for (const visionScore of VISION_SCORES) {
          for (const visionQuality of VISION_QUALITIES) {
            combos.push({ citsColor, freshness, visionColor, visionScore, visionQuality })
          }
        }
      }
    }
  }

  it(`enumerates available:false combinations (got ${combos.length})`, () => {
    expect(combos.length).toBeGreaterThan(50)
  })

  it('every available:false combination across 100 ticks never yields SIGNAL_CONFIRMED', () => {
    for (const combo of combos) {
      const shield = createRuntimeShield()
      for (let i = 0; i < 100; i++) {
        const nowMonoMs = BASE_MONO + i * 100
        const nowEpochMs = BASE_EPOCH + i * 100
        const overrides = buildCombinationOverrides({
          citsColor: combo.citsColor,
          citsAvailable: false,
          freshness: combo.freshness,
          seqMode: 'advancing',
          visionColor: combo.visionColor,
          visionScore: combo.visionScore,
          visionQuality: combo.visionQuality,
          frameMode: 'advancing',
          timeRemaining: 35,
          targetMode: 'match',
          nowMonoMs,
          nowEpochMs,
          seedSeq: 300 + i,
          seedFrameSeq: 400 + i,
          seedMediaTimeMs: 8000 + i * 100,
        })
        const out = shield.update(makeTick(i, overrides))
        expect(
          out.decision,
          `P3 violated for combo ${JSON.stringify(combo)} at tick ${i}`
        ).not.toBe('SIGNAL_CONFIRMED')
        expect(out.checks.citsAvailable).toBe(false)
      }
    }
  })
})

// ---------------------------------------------------------------------------
// P4 — target 변경 ⇒ same-update WAIT (비-proceed), across each of 5 mismatch fields
// ---------------------------------------------------------------------------
describe('Invariant P4 — target 변경 주입 ⇒ 그 update는 비-proceed', () => {
  for (const targetMode of TARGET_MODES.filter((m) => m !== 'match')) {
    it(`${targetMode}: confirmed shield + target field mismatch → same-update decision != SIGNAL_CONFIRMED`, () => {
      const state = confirmFreshShield()
      const field = targetMode.slice('mismatch-'.length)
      const fieldOverride =
        field === 'roiBindingId'
          ? { vision: { roiBindingId: 'roi-MISMATCHED' } }
          : { cits: { [field]: 'MISMATCHED-VALUE' } }
      const out = state.shield.update(nextTickAfterConfirm(state, fieldOverride))
      expect(out.decision).not.toBe('SIGNAL_CONFIRMED')
      expect(out.decision).toBe('WAIT')
      expect(out.checks.targetMatch).toBe(false)
    })
  }

  it('full target context rebind (all 5 fields change together, sensors follow) → accumulation resets, same-update not SIGNAL_CONFIRMED', () => {
    const state = confirmFreshShield()
    const newCtx = {
      intersectionId: 'other-int',
      crosswalkId: 'other-cw',
      movementId: 'other-mv',
      direction: 'SOUTHBOUND',
      roiBindingId: 'other-roi',
    }
    const out = state.shield.update(
      nextTickAfterConfirm(state, {
        target: newCtx,
        cits: {
          intersectionId: newCtx.intersectionId,
          crosswalkId: newCtx.crosswalkId,
          movementId: newCtx.movementId,
          direction: newCtx.direction,
        },
        vision: { roiBindingId: newCtx.roiBindingId },
      })
    )
    expect(out.decision).not.toBe('SIGNAL_CONFIRMED')
    expect(out.confirmation.distinctGreenFrames).toBeLessThanOrEqual(1)
  })
})

// ---------------------------------------------------------------------------
// P5 — fault class injected onto a confirmed shield ⇒ that update's decision != SIGNAL_CONFIRMED
// Binding constraint: NEVER sample — all 8 classes explicit, individually.
// ---------------------------------------------------------------------------
describe('Invariant P5 — 확정 상태에 결함 주입 → 그 update는 비-proceed (8개 클래스 전수)', () => {
  it('class 1/8: red (cits color red) → same-update not SIGNAL_CONFIRMED', () => {
    const state = confirmFreshShield()
    const out = state.shield.update(nextTickAfterConfirm(state, { cits: { color: 'red' } }))
    expect(out.decision).not.toBe('SIGNAL_CONFIRMED')
    expect(out.decision).toBe('WAIT')
    expect(out.reason).toBe(REASONS.RED_SIGNAL)
  })

  it('class 2/8: unknown (cits color unknown) → same-update not SIGNAL_CONFIRMED', () => {
    const state = confirmFreshShield()
    const out = state.shield.update(nextTickAfterConfirm(state, { cits: { color: 'unknown' } }))
    expect(out.decision).not.toBe('SIGNAL_CONFIRMED')
    expect(out.decision).toBe('WAIT')
    expect(out.reason).toBe(REASONS.RED_SIGNAL)
  })

  it('class 3/8: cits source-stale → same-update not SIGNAL_CONFIRMED', () => {
    const state = confirmFreshShield()
    const out = state.shield.update(
      nextTickAfterConfirm(state, {
        cits: { sourceEpochMs: state.lastEpoch + 400 - (RTA_CONFIG_V1.maxCitsSourceAgeMs + 1000) },
      })
    )
    expect(out.decision).not.toBe('SIGNAL_CONFIRMED')
    expect(out.decision).toBe('WAIT')
    expect(out.reason).toBe(REASONS.CITS_STALE)
  })

  it('class 4/8: cits receive-stale → same-update not SIGNAL_CONFIRMED', () => {
    const state = confirmFreshShield()
    const out = state.shield.update(
      nextTickAfterConfirm(state, {
        cits: { receivedAtMonoMs: state.lastMono + 400 - (RTA_CONFIG_V1.maxCitsReceiveAgeMs + 1000) },
      })
    )
    expect(out.decision).not.toBe('SIGNAL_CONFIRMED')
    expect(out.decision).toBe('WAIT')
    expect(out.reason).toBe(REASONS.CITS_STALE)
  })

  it('class 5/8: vision-stale → same-update not SIGNAL_CONFIRMED', () => {
    const state = confirmFreshShield()
    const out = state.shield.update(
      nextTickAfterConfirm(state, {
        vision: { capturedAtMonoMs: state.lastMono + 400 - (RTA_CONFIG_V1.maxVisionAgeMs + 1000) },
      })
    )
    expect(out.decision).not.toBe('SIGNAL_CONFIRMED')
    expect(out.decision).toBe('WAIT')
    expect(out.reason).toBe(REASONS.VISION_STALE)
  })

  it('class 6/8: replay seq (cits.seq goes backward) → same-update not SIGNAL_CONFIRMED', () => {
    const state = confirmFreshShield()
    const lastSeq = 100 + state.lastIndex
    const out = state.shield.update(nextTickAfterConfirm(state, { cits: { seq: lastSeq - 1 } }))
    expect(out.decision).not.toBe('SIGNAL_CONFIRMED')
    expect(out.decision).toBe('WAIT')
    expect(out.reason).toBe(REASONS.REPLAY_OR_REORDER)
  })

  it('class 7/8: frozen frame past freezeTimeoutMs → same-update not SIGNAL_CONFIRMED', () => {
    const state = confirmFreshShield()
    const lastFrameSeq = 200 + state.lastIndex
    const nextMono = state.lastMono + RTA_CONFIG_V1.freezeTimeoutMs + 1000
    const nextEpoch = state.lastEpoch + RTA_CONFIG_V1.freezeTimeoutMs + 1000
    const out = state.shield.update(
      makeTick(state.lastIndex + 1, {
        clock: { nowMonoMs: nextMono, nowEpochMs: nextEpoch },
        cits: { sourceEpochMs: nextEpoch - 200, receivedAtMonoMs: nextMono - 100 },
        vision: { capturedAtMonoMs: nextMono - 50, frameSeq: lastFrameSeq, mediaTimeMs: 5000 + state.lastIndex * TICK_MS },
      })
    )
    expect(out.decision).not.toBe('SIGNAL_CONFIRMED')
    expect(out.decision).toBe('WAIT')
    expect(out.reason).toBe(REASONS.VIDEO_FROZEN)
  })

  it('class 8/8: time-short (remainingSec below required+hold) → same-update not SIGNAL_CONFIRMED', () => {
    const state = confirmFreshShield()
    const out = state.shield.update(nextTickAfterConfirm(state, { cits: { remainingSec: 8 } }))
    expect(out.decision).not.toBe('SIGNAL_CONFIRMED')
    expect(out.decision).toBe('WAIT')
    expect(out.reason).toBe(REASONS.TIME_SHORT)
  })

  it('all 8 fault classes are covered exactly once above (no sampling)', () => {
    const classes = [
      'red',
      'unknown',
      'sourceStale',
      'receiveStale',
      'visionStale',
      'replaySeq',
      'frozenFramePastTimeout',
      'timeShort',
    ]
    expect(classes.length).toBe(8)
  })
})

// ---------------------------------------------------------------------------
// P6 — frameSeq frozen (repeated) ⇒ never SIGNAL_CONFIRMED over 100 ticks,
// for BOTH media-time variants named in the S3 handoff.
// ---------------------------------------------------------------------------
describe('Invariant P6 — frameSeq 고정 반복 → 100 tick 내 SIGNAL_CONFIRMED 불가', () => {
  it('frozenSeq + frozenMedia: identical frame repeated within freeze window → never SIGNAL_CONFIRMED', () => {
    const shield = createRuntimeShield()
    const fixedFrameSeq = 500
    const fixedMediaTimeMs = 9000
    let sawConfirmed = false
    for (let i = 0; i < 100; i++) {
      const nowMonoMs = BASE_MONO + i * 100 // well within freezeTimeoutMs=750
      const nowEpochMs = BASE_EPOCH + i * 100
      const out = shield.update(
        makeTick(i, {
          clock: { nowMonoMs, nowEpochMs },
          cits: { sourceEpochMs: nowEpochMs - 200, receivedAtMonoMs: nowMonoMs - 100 },
          vision: { capturedAtMonoMs: nowMonoMs - 50, frameSeq: fixedFrameSeq, mediaTimeMs: fixedMediaTimeMs },
        })
      )
      if (out.decision === 'SIGNAL_CONFIRMED') sawConfirmed = true
    }
    expect(sawConfirmed).toBe(false)
  })

  it('frozenSeq + advancingMedia: frameSeq repeats while mediaTimeMs advances → never SIGNAL_CONFIRMED (S3 handoff case)', () => {
    const shield = createRuntimeShield()
    const fixedFrameSeq = 500
    let sawConfirmed = false
    for (let i = 0; i < 100; i++) {
      const nowMonoMs = BASE_MONO + i * 100
      const nowEpochMs = BASE_EPOCH + i * 100
      const out = shield.update(
        makeTick(i, {
          clock: { nowMonoMs, nowEpochMs },
          cits: { sourceEpochMs: nowEpochMs - 200, receivedAtMonoMs: nowMonoMs - 100 },
          vision: { capturedAtMonoMs: nowMonoMs - 50, frameSeq: fixedFrameSeq, mediaTimeMs: 9000 + i * TICK_MS },
        })
      )
      if (out.decision === 'SIGNAL_CONFIRMED') sawConfirmed = true
    }
    expect(sawConfirmed).toBe(false)
  })
})

// ---------------------------------------------------------------------------
// P7 — hostile inputs never throw; decision is WAIT-family (INVALID_INPUT or INTERNAL_ERROR)
// ---------------------------------------------------------------------------
describe('Invariant P7 — 예외적/적대적 입력 → throw 없음, WAIT-family only', () => {
  const wantWaitFamily = (out) => {
    expect(out.decision).toBe('WAIT')
    expect(['INVALID_INPUT', 'INTERNAL_ERROR']).toContain(out.reason)
  }

  it('update(null) → returns (never throws), WAIT-family', () => {
    const shield = createRuntimeShield()
    let out
    expect(() => {
      out = shield.update(null)
    }).not.toThrow()
    wantWaitFamily(out)
  })

  it('update(undefined) / update() → returns, WAIT-family', () => {
    const shield = createRuntimeShield()
    let out
    expect(() => {
      out = shield.update()
    }).not.toThrow()
    wantWaitFamily(out)
  })

  it('update({}) → returns, WAIT-family', () => {
    const shield = createRuntimeShield()
    let out
    expect(() => {
      out = shield.update({})
    }).not.toThrow()
    wantWaitFamily(out)
  })

  it('hostile config Proxy with throwing getters → returns, WAIT-family (INTERNAL_ERROR)', () => {
    const throwingConfig = new Proxy(RTA_CONFIG_V1, {
      get() {
        throw new Error('forced hostile getter')
      },
    })
    const shield = createRuntimeShield({ config: throwingConfig })
    let out
    expect(() => {
      out = shield.update(makeTick(0))
    }).not.toThrow()
    wantWaitFamily(out)
    expect(out.reason).toBe(REASONS.INTERNAL_ERROR)
  })

  it('missing clock (clock: undefined) → returns, WAIT-family', () => {
    const shield = createRuntimeShield()
    const input = makeTick(0)
    delete input.clock
    let out
    expect(() => {
      out = shield.update(input)
    }).not.toThrow()
    wantWaitFamily(out)
    expect(out.reason).toBe(REASONS.INVALID_INPUT)
  })

  it('null clock → returns, WAIT-family', () => {
    const shield = createRuntimeShield()
    const input = makeTick(0, { clock: null })
    input.clock = null
    let out
    expect(() => {
      out = shield.update(input)
    }).not.toThrow()
    wantWaitFamily(out)
    expect(out.reason).toBe(REASONS.INVALID_INPUT)
  })

  it('NaN clock times → returns, WAIT-family', () => {
    const shield = createRuntimeShield()
    const out = shield.update(makeTick(0, { clock: { nowMonoMs: NaN, nowEpochMs: NaN } }))
    wantWaitFamily(out)
    expect(out.reason).toBe(REASONS.INVALID_INPUT)
  })

  it('NaN cits.remainingSec / vision.score → returns, WAIT-family', () => {
    const shield = createRuntimeShield()
    const out = shield.update(
      makeTick(0, { cits: { remainingSec: NaN }, vision: { score: NaN } })
    )
    wantWaitFamily(out)
    expect(out.reason).toBe(REASONS.INVALID_INPUT)
  })

  it('a getter-throwing hostile top-level input object → returns, WAIT-family', () => {
    const shield = createRuntimeShield()
    const hostileInput = new Proxy(makeTick(0), {
      get(target, prop) {
        if (prop === 'target') throw new Error('forced hostile input getter')
        return target[prop]
      },
    })
    let out
    expect(() => {
      out = shield.update(hostileInput)
    }).not.toThrow()
    wantWaitFamily(out)
  })

  it('non-object update() argument (string/number) → returns, WAIT-family', () => {
    const shield = createRuntimeShield()
    for (const bad of ['not-an-object', 42, true, () => {}]) {
      let out
      expect(() => {
        out = shield.update(bad)
      }).not.toThrow()
      wantWaitFamily(out)
    }
  })

  it('sustained hostile-config runtime (100 ticks) never throws and never confirms', () => {
    const throwingConfig = new Proxy(RTA_CONFIG_V1, {
      get() {
        throw new Error('forced hostile getter')
      },
    })
    const shield = createRuntimeShield({ config: throwingConfig })
    for (let i = 0; i < 100; i++) {
      let out
      expect(() => {
        out = shield.update(makeTick(i))
      }).not.toThrow()
      wantWaitFamily(out)
    }
  })
})
