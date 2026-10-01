import { describe, it, expect } from 'vitest'
import { RTA_CONFIG_V1 } from '../../src/safety/config.js'
import { REASONS } from '../../src/safety/reasonCodes.js'
import { MESSAGES, confirmedMessage } from '../../src/safety/reasonCodes.js'
import { createRuntimeShield } from '../../src/safety/runtimeShield.js'

// ---- tick input generator -------------------------------------------------
// Mirrors how S5 traces will drive the shield: monotonic time advances by
// TICK_MS per tick, cits seq / vision frameSeq advance by 1 per tick, and all
// freshness windows stay comfortably inside config thresholds so a run of
// "good" ticks sustains hard-check-pass indefinitely unless a field is
// overridden.
const TICK_MS = 100
const BASE_EPOCH = 1784780000000
const BASE_MONO = 1_000_000 // arbitrary large monotonic origin

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
 * can be overridden via `overrides` (deep-shallow: target/cits/vision/clock
 * objects are individually override-able and merged over the generated
 * defaults).
 */
function makeTick(i, overrides = {}) {
  const nowMonoMs = BASE_MONO + i * TICK_MS
  const nowEpochMs = BASE_EPOCH + i * TICK_MS

  const target = makeTargetContext(overrides.target)

  const cits = {
    available: true,
    color: 'green',
    remainingSec: 35, // comfortably long — effectiveRemainingSec stays >> required+hold
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
// effectiveRemainingSec at tick i ~ 35 - 0.2 - 0.5 = 34.3 (well above threshold)

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

/** Runs `n` good ticks (indices start..start+n-1) against shield, returns last output. */
function runGoodTicks(shield, start, n) {
  let out
  for (let i = start; i < start + n; i++) {
    out = shield.update(makeTick(i))
  }
  return out
}

describe('createRuntimeShield — factory shape', () => {
  it('returns update/getState/reset functions', () => {
    const shield = createRuntimeShield()
    expect(typeof shield.update).toBe('function')
    expect(typeof shield.getState).toBe('function')
    expect(typeof shield.reset).toBe('function')
  })

  it('initial state is WAIT before any update', () => {
    const shield = createRuntimeShield()
    expect(shield.getState()).toBe('WAIT')
  })
})

describe('createRuntimeShield — K/hold combinations (원본 §19.3)', () => {
  it('K-1개 distinct green frame에서는 SIGNAL_CONFIRMED 금지 (여전히 VERIFYING)', () => {
    const shield = createRuntimeShield()
    // minDistinctGreenFrames = 5 → run 4 distinct-frame good ticks
    const out = runGoodTicks(shield, 0, RTA_CONFIG_V1.minDistinctGreenFrames - 1)
    expect(out.decision).toBe('VERIFYING')
    expect(out.state).toBe('CONFIRMING')
    expect(out.reason).toBe('CONFIRMING')
    expect(out.confirmation.distinctGreenFrames).toBe(RTA_CONFIG_V1.minDistinctGreenFrames - 1)
  })

  it('K개 충족해도 hold 미달이면 SIGNAL_CONFIRMED 금지', () => {
    const shield = createRuntimeShield()
    // Exactly K distinct frames but ticks are only TICK_MS apart each,
    // so confirmHoldMs (1500ms) has NOT elapsed since the first counted frame.
    const out = runGoodTicks(shield, 0, RTA_CONFIG_V1.minDistinctGreenFrames)
    expect(out.confirmation.distinctGreenFrames).toBe(RTA_CONFIG_V1.minDistinctGreenFrames)
    // K=5 ticks at 100ms apart → elapsed since first counted frame = 4*100 = 400ms < 1500ms
    expect(out.decision).toBe('VERIFYING')
    expect(out.state).toBe('CONFIRMING')
  })

  it('hold를 충족해도 서로 다른 frame 수(K)가 부족하면 SIGNAL_CONFIRMED 금지', () => {
    const shield = createRuntimeShield()
    // Use tick spacing that stays under freezeTimeoutMs (750ms) per step but
    // accumulates past confirmHoldMs (1500ms) before K (5) distinct frames
    // are reached: 4 ticks * 700ms step -> elapsed since first counted frame
    // = 3*700 = 2100ms >= 1500ms, while distinct frames = 4 < K(5).
    let out
    for (let i = 0; i < 4; i++) {
      const nowMonoMs = BASE_MONO + i * 700
      const nowEpochMs = BASE_EPOCH + i * 700
      out = shield.update(
        makeTick(i, {
          clock: { nowMonoMs, nowEpochMs },
          cits: { sourceEpochMs: nowEpochMs - 200, receivedAtMonoMs: nowMonoMs - 100 },
          vision: { capturedAtMonoMs: nowMonoMs - 50 },
        })
      )
    }
    expect(out.confirmation.distinctGreenFrames).toBe(4)
    expect(out.decision).toBe('VERIFYING')
    expect(RTA_CONFIG_V1.minDistinctGreenFrames).toBe(5)
  })

  it('K와 hold를 동시에 충족하면 SIGNAL_CONFIRMED로 확정된다', () => {
    const shield = createRuntimeShield()
    // Space ticks far enough apart (400ms) that by the Kth distinct frame,
    // hold (1500ms) has also elapsed: (K-1)*400 = 4*400 = 1600ms >= 1500ms
    let out
    for (let i = 0; i < RTA_CONFIG_V1.minDistinctGreenFrames; i++) {
      const nowMonoMs = BASE_MONO + i * 400
      const nowEpochMs = BASE_EPOCH + i * 400
      out = shield.update(
        makeTick(i, {
          clock: { nowMonoMs, nowEpochMs },
          cits: { sourceEpochMs: nowEpochMs - 200, receivedAtMonoMs: nowMonoMs - 100 },
          vision: { capturedAtMonoMs: nowMonoMs - 50 },
        })
      )
    }
    expect(out.decision).toBe('SIGNAL_CONFIRMED')
    expect(out.state).toBe('SIGNAL_CONFIRMED')
    expect(out.reason).toBe('SAFEGRAPH_CONFIRMED')
    expect(out.confirmation.distinctGreenFrames).toBeGreaterThanOrEqual(
      RTA_CONFIG_V1.minDistinctGreenFrames
    )
  })
})

describe('createRuntimeShield — 같은 frameSeq 반복으로 K를 채울 수 없음 (P6)', () => {
  it('frameSeq 고정 반복 tick으로는 영원히 VERIFYING (freeze 걸리기 전 범위 내에서 확인)', () => {
    const shield = createRuntimeShield()
    // Repeat the SAME frameSeq every tick. Space ticks close enough that
    // freezeTimeoutMs (750ms) never trips, so we isolate the "same frame
    // can't count twice" rule from the freeze rule.
    let out
    const fixedFrameSeq = 500
    for (let i = 0; i < 10; i++) {
      const nowMonoMs = BASE_MONO + i * 100 // well within freezeTimeoutMs=750
      const nowEpochMs = BASE_EPOCH + i * 100
      out = shield.update(
        makeTick(i, {
          clock: { nowMonoMs, nowEpochMs },
          cits: { sourceEpochMs: nowEpochMs - 200, receivedAtMonoMs: nowMonoMs - 100 },
          vision: { capturedAtMonoMs: nowMonoMs - 50, frameSeq: fixedFrameSeq },
        })
      )
    }
    expect(out.confirmation.distinctGreenFrames).toBe(1)
    expect(out.decision).toBe('VERIFYING')
    expect(out.state).toBe('CONFIRMING')
  })
})

describe('createRuntimeShield — target/sourceMode 변경 시 누적 초기화', () => {
  it('target 변경 → 누적 초기화 + 그 update는 proceed-like 아님', () => {
    const shield = createRuntimeShield()
    runGoodTicks(shield, 0, 3) // partial progress: 3 distinct frames
    // Rebind target context to a different crosswalk WITHOUT the sensor feeds
    // following (cits/vision still report the old crosswalkId/roiBindingId) —
    // this both changes the target key AND makes targetMatch fail this tick,
    // which must reset accumulation to zero in the same update.
    const out = shield.update(
      makeTick(3, {
        target: { crosswalkId: 'other-crosswalk', roiBindingId: 'other-roi' },
        vision: { roiBindingId: 'roi-ped-north-01' }, // stays on the OLD roi binding
      })
    )
    expect(out.decision).not.toBe('SIGNAL_CONFIRMED')
    expect(out.reason).toBe(REASONS.TARGET_MISMATCH)
    expect(out.confirmation.distinctGreenFrames).toBe(0)
    expect(out.confirmation.confirmingSinceMonoMs).toBeNull()
  })

  it('target 변경(센서가 즉시 따라오는 경우) → 그래도 누적은 0부터 다시 시작한다', () => {
    const shield = createRuntimeShield()
    runGoodTicks(shield, 0, 3) // partial progress: 3 distinct frames
    // Target AND its bound sensors change together (rebinding completed) —
    // targetMatch stays true, but the target key changed, so accumulation
    // must still reset; this tick counts as frame 1 of the new target.
    const out = shield.update(makeTick(3, { target: { crosswalkId: 'other-crosswalk' } }))
    expect(out.decision).not.toBe('SIGNAL_CONFIRMED')
    expect(out.confirmation.distinctGreenFrames).toBe(1)
  })

  it('target 변경 후 새 target으로 처음부터 다시 K+hold 채우면 확정된다', () => {
    const shield = createRuntimeShield()
    runGoodTicks(shield, 0, 3)
    const newTarget = { crosswalkId: 'other-crosswalk' }
    // vision/cits still bound to old roi/intersection unless matched — must also
    // update the corresponding cits/vision ids so targetMatch stays true.
    let out
    for (let i = 0; i < RTA_CONFIG_V1.minDistinctGreenFrames; i++) {
      const idx = 100 + i
      const nowMonoMs = BASE_MONO + idx * 400
      const nowEpochMs = BASE_EPOCH + idx * 400
      out = shield.update(
        makeTick(idx, {
          target: newTarget,
          cits: {
            crosswalkId: 'other-crosswalk',
            sourceEpochMs: nowEpochMs - 200,
            receivedAtMonoMs: nowMonoMs - 100,
          },
          vision: { capturedAtMonoMs: nowMonoMs - 50 },
          clock: { nowMonoMs, nowEpochMs },
        })
      )
    }
    expect(out.decision).toBe('SIGNAL_CONFIRMED')
  })

  it('sourceMode 변경(cits) → 누적 초기화', () => {
    const shield = createRuntimeShield()
    runGoodTicks(shield, 0, 3)
    const out = shield.update(makeTick(3, { cits: { sourceMode: 'LIVE', sourceEpochMs: BASE_EPOCH + 3 * TICK_MS - 200 } }))
    expect(out.confirmation.distinctGreenFrames).toBeLessThanOrEqual(1)
    expect(out.decision).not.toBe('SIGNAL_CONFIRMED')
  })

  it('sourceMode 변경(vision) → 누적 초기화', () => {
    const shield = createRuntimeShield()
    runGoodTicks(shield, 0, 3)
    const out = shield.update(makeTick(3, { vision: { sourceMode: 'CAMERA' } }))
    expect(out.confirmation.distinctGreenFrames).toBeLessThanOrEqual(1)
    expect(out.decision).not.toBe('SIGNAL_CONFIRMED')
  })
})

describe('createRuntimeShield — SIGNAL_CONFIRMED에서 same-update 즉시 WAIT 강등', () => {
  function confirmShield() {
    const shield = createRuntimeShield()
    let out
    for (let i = 0; i < RTA_CONFIG_V1.minDistinctGreenFrames; i++) {
      const nowMonoMs = BASE_MONO + i * 400
      const nowEpochMs = BASE_EPOCH + i * 400
      out = shield.update(
        makeTick(i, {
          clock: { nowMonoMs, nowEpochMs },
          cits: { sourceEpochMs: nowEpochMs - 200, receivedAtMonoMs: nowMonoMs - 100 },
          vision: { capturedAtMonoMs: nowMonoMs - 50 },
        })
      )
    }
    expect(out.decision).toBe('SIGNAL_CONFIRMED')
    return { shield, lastIndex: RTA_CONFIG_V1.minDistinctGreenFrames - 1, lastMono: BASE_MONO + (RTA_CONFIG_V1.minDistinctGreenFrames - 1) * 400 }
  }

  it('red 1회 입력 → 같은 update에서 WAIT', () => {
    const { shield, lastIndex, lastMono } = confirmShield()
    const nextMono = lastMono + 400
    const nextEpoch = BASE_EPOCH + nextMono - BASE_MONO
    const out = shield.update(
      makeTick(lastIndex + 1, {
        clock: { nowMonoMs: nextMono, nowEpochMs: nextEpoch },
        cits: { color: 'red', sourceEpochMs: nextEpoch - 200, receivedAtMonoMs: nextMono - 100 },
        vision: { capturedAtMonoMs: nextMono - 50 },
      })
    )
    expect(out.decision).toBe('WAIT')
    expect(out.state).toBe('WAIT')
    expect(out.reason).toBe(REASONS.RED_SIGNAL)
  })

  it('stale 전환 → 즉시 WAIT', () => {
    const { shield, lastIndex, lastMono } = confirmShield()
    const nextMono = lastMono + 400
    const nextEpoch = BASE_EPOCH + nextMono - BASE_MONO
    const out = shield.update(
      makeTick(lastIndex + 1, {
        clock: { nowMonoMs: nextMono, nowEpochMs: nextEpoch },
        // cits sourceEpochMs far in the past -> stale
        cits: { sourceEpochMs: nextEpoch - 5000, receivedAtMonoMs: nextMono - 100 },
        vision: { capturedAtMonoMs: nextMono - 50 },
      })
    )
    expect(out.decision).toBe('WAIT')
    expect(out.state).toBe('WAIT')
    expect(out.reason).toBe(REASONS.CITS_STALE)
  })

  it('time-short 전환 → 즉시 WAIT', () => {
    const { shield, lastIndex, lastMono } = confirmShield()
    const nextMono = lastMono + 400
    const nextEpoch = BASE_EPOCH + nextMono - BASE_MONO
    const out = shield.update(
      makeTick(lastIndex + 1, {
        clock: { nowMonoMs: nextMono, nowEpochMs: nextEpoch },
        cits: {
          remainingSec: 5, // far below required+hold (~20.17s)
          sourceEpochMs: nextEpoch - 200,
          receivedAtMonoMs: nextMono - 100,
        },
        vision: { capturedAtMonoMs: nextMono - 50 },
      })
    )
    expect(out.decision).toBe('WAIT')
    expect(out.state).toBe('WAIT')
    expect(out.reason).toBe(REASONS.TIME_SHORT)
  })

  it('target 변경 → 즉시 WAIT', () => {
    const { shield, lastIndex, lastMono } = confirmShield()
    const nextMono = lastMono + 400
    const nextEpoch = BASE_EPOCH + nextMono - BASE_MONO
    const out = shield.update(
      makeTick(lastIndex + 1, {
        clock: { nowMonoMs: nextMono, nowEpochMs: nextEpoch },
        // Target context rebinds to a different crosswalk, but the cits/vision
        // feeds have not caught up yet (still report the OLD crosswalkId/roi) —
        // targetMatch fails this same tick.
        target: { crosswalkId: 'changed-crosswalk', roiBindingId: 'changed-roi' },
        cits: { sourceEpochMs: nextEpoch - 200, receivedAtMonoMs: nextMono - 100 },
        vision: { capturedAtMonoMs: nextMono - 50, roiBindingId: 'roi-ped-north-01' },
      })
    )
    expect(out.decision).toBe('WAIT')
    expect(out.state).toBe('WAIT')
    // target mismatch (cits/vision still point at old target) is the failure mode here
    expect(out.reason).toBe(REASONS.TARGET_MISMATCH)
  })
})

describe('createRuntimeShield — WAIT 이후 재green은 처음부터 시작', () => {
  it('WAIT로 강등된 후 다시 green이 연속되면 K/hold를 처음부터 채운다', () => {
    const shield = createRuntimeShield()
    // Get partial progress (3 frames), then force RED (WAIT + reset).
    runGoodTicks(shield, 0, 3)
    const redOut = shield.update(makeTick(3, { cits: { color: 'red' } }))
    expect(redOut.decision).toBe('WAIT')
    expect(redOut.confirmation.distinctGreenFrames).toBe(0)

    // Now resume green from scratch — must take a full K frames + hold again.
    let out
    for (let i = 0; i < RTA_CONFIG_V1.minDistinctGreenFrames; i++) {
      const idx = 10 + i
      const nowMonoMs = BASE_MONO + idx * 400
      const nowEpochMs = BASE_EPOCH + idx * 400
      out = shield.update(
        makeTick(idx, {
          clock: { nowMonoMs, nowEpochMs },
          cits: { sourceEpochMs: nowEpochMs - 200, receivedAtMonoMs: nowMonoMs - 100 },
          vision: { capturedAtMonoMs: nowMonoMs - 50 },
        })
      )
      if (i < RTA_CONFIG_V1.minDistinctGreenFrames - 1) {
        expect(out.decision).not.toBe('SIGNAL_CONFIRMED')
      }
    }
    expect(out.decision).toBe('SIGNAL_CONFIRMED')
  })
})

describe('createRuntimeShield — 입력 계약 실패 / 내부 예외', () => {
  it('update() 인자 없음 → WAIT + INVALID_INPUT', () => {
    const shield = createRuntimeShield()
    const out = shield.update()
    expect(out.decision).toBe('WAIT')
    expect(out.state).toBe('WAIT')
    expect(out.reason).toBe(REASONS.INVALID_INPUT)
    expect(out.message).toBe(MESSAGES.WAIT)
  })

  it('update(null) → WAIT + INVALID_INPUT', () => {
    const shield = createRuntimeShield()
    const out = shield.update(null)
    expect(out.decision).toBe('WAIT')
    expect(out.reason).toBe(REASONS.INVALID_INPUT)
  })

  it('필드 결측(target 없음) → WAIT + INVALID_INPUT', () => {
    const shield = createRuntimeShield()
    const input = makeTick(0)
    delete input.target
    const out = shield.update(input)
    expect(out.decision).toBe('WAIT')
    expect(out.reason).toBe(REASONS.INVALID_INPUT)
  })

  it('내부 예외 강제(잘못된 config 주입) → WAIT + INTERNAL_ERROR', () => {
    // A config whose numeric fields are non-numbers will make arithmetic
    // inside evaluateChecks/shield produce NaN paths or, if a consumer
    // trusts config shape without validation, throw. We force a genuine
    // exception by injecting a config that is not an object at all (throws
    // on property access patterns internal to validateConfig / evaluateChecks
    // is avoided by contracts — so instead we inject a config whose access
    // pattern breaks strict internal assumptions: a Proxy that throws).
    const throwingConfig = new Proxy(RTA_CONFIG_V1, {
      get() {
        throw new Error('forced internal exception')
      },
    })
    const shield = createRuntimeShield({ config: throwingConfig })
    const out = shield.update(makeTick(0))
    expect(out.decision).toBe('WAIT')
    expect(out.state).toBe('WAIT')
    expect(out.reason).toBe(REASONS.INTERNAL_ERROR)
    expect(out.message).toBe(MESSAGES.WAIT)
  })
})

describe('createRuntimeShield — cits unavailable + vision 완벽 → INFORMATION_ONLY (P3)', () => {
  it('cits.available=false, vision green/score/quality/fresh 전부 통과 → INFORMATION_ONLY, SIGNAL_CONFIRMED 아님', () => {
    const shield = createRuntimeShield()
    let out
    for (let i = 0; i < 20; i++) {
      out = shield.update(makeTick(i, { cits: { available: false } }))
    }
    expect(out.decision).toBe('INFORMATION_ONLY')
    expect(out.reason).toBe(REASONS.VISION_ONLY_INFORMATION)
    expect(out.message).toBe(MESSAGES.INFORMATION_ONLY)
    expect(out.decision).not.toBe('SIGNAL_CONFIRMED')
  })

  it('cits unavailable 상태가 지속돼도 confirmation 누적이 발생하지 않는다 (CONFIRMING 진입 불가)', () => {
    const shield = createRuntimeShield()
    let out
    for (let i = 0; i < 10; i++) {
      out = shield.update(makeTick(i, { cits: { available: false } }))
    }
    expect(out.confirmation.distinctGreenFrames).toBe(0)
    expect(out.state).not.toBe('CONFIRMING')
    expect(out.state).not.toBe('SIGNAL_CONFIRMED')
  })

  it('cits unavailable + vision score 미달 → INFORMATION_ONLY 아니라 WAIT', () => {
    const shield = createRuntimeShield()
    const out = shield.update(
      makeTick(0, { cits: { available: false }, vision: { score: 0.1 } })
    )
    expect(out.decision).toBe('WAIT')
    expect(out.decision).not.toBe('INFORMATION_ONLY')
  })

  it('cits unavailable + vision red → INFORMATION_ONLY 아니라 WAIT', () => {
    const shield = createRuntimeShield()
    const out = shield.update(
      makeTick(0, { cits: { available: false }, vision: { color: 'red' } })
    )
    expect(out.decision).toBe('WAIT')
    expect(out.decision).not.toBe('INFORMATION_ONLY')
  })
})

describe('createRuntimeShield — 출력 계약 완전성', () => {
  it('checks 14키·ages·confirmation·configVersion·failedChecks가 항상 존재한다 (WAIT 상태)', () => {
    const shield = createRuntimeShield()
    const out = shield.update(makeTick(0, { cits: { color: 'red' } }))
    expect(Object.keys(out.checks).sort()).toEqual([...ALL_CHECK_KEYS].sort())
    expect(out.ages).toEqual(
      expect.objectContaining({
        citsSourceAgeMs: expect.any(Number),
        citsReceiveAgeMs: expect.any(Number),
        visionAgeMs: expect.any(Number),
      })
    )
    expect(out.confirmation).toEqual(
      expect.objectContaining({
        distinctGreenFrames: expect.any(Number),
        confirmingSinceMonoMs: null,
      })
    )
    expect(out.configVersion).toBe(RTA_CONFIG_V1.configVersion)
    expect(Array.isArray(out.failedChecks)).toBe(true)
    expect(typeof out.effectiveRemainingSec).toBe('number')
    expect(typeof out.requiredCrossingSec).toBe('number')
  })

  it('출력 계약이 CONFIRMING 상태에서도 완전하다', () => {
    const shield = createRuntimeShield()
    const out = runGoodTicks(shield, 0, 2)
    expect(Object.keys(out.checks).sort()).toEqual([...ALL_CHECK_KEYS].sort())
    expect(out.checks.distinctFramesOk).toBe(false) // K not yet met
    expect(out.confirmation.confirmingSinceMonoMs).not.toBeNull()
  })

  it('SIGNAL_CONFIRMED 상태에서 checks.distinctFramesOk/holdTimeOk가 true로 병합된다', () => {
    const shield = createRuntimeShield()
    let out
    for (let i = 0; i < RTA_CONFIG_V1.minDistinctGreenFrames; i++) {
      const nowMonoMs = BASE_MONO + i * 400
      const nowEpochMs = BASE_EPOCH + i * 400
      out = shield.update(
        makeTick(i, {
          clock: { nowMonoMs, nowEpochMs },
          cits: { sourceEpochMs: nowEpochMs - 200, receivedAtMonoMs: nowMonoMs - 100 },
          vision: { capturedAtMonoMs: nowMonoMs - 50 },
        })
      )
    }
    expect(out.checks.distinctFramesOk).toBe(true)
    expect(out.checks.holdTimeOk).toBe(true)
    expect(out.message).toBe(confirmedMessage(Math.floor(out.effectiveRemainingSec)))
  })

  it('WAIT 상태 message는 MESSAGES.WAIT byte-exact다', () => {
    const shield = createRuntimeShield()
    const out = shield.update(makeTick(0, { cits: { color: 'red' } }))
    expect(out.message).toBe(MESSAGES.WAIT)
  })

  it('VERIFYING 상태 message는 MESSAGES.VERIFYING byte-exact다', () => {
    const shield = createRuntimeShield()
    const out = runGoodTicks(shield, 0, 1)
    expect(out.decision).toBe('VERIFYING')
    expect(out.message).toBe(MESSAGES.VERIFYING)
  })
})

describe('createRuntimeShield — reset()', () => {
  it('reset() 후 상태가 초기 WAIT로 되돌아가고 누적이 0이 된다', () => {
    const shield = createRuntimeShield()
    runGoodTicks(shield, 0, 3)
    shield.reset()
    expect(shield.getState()).toBe('WAIT')
    const out = shield.update(makeTick(100))
    // Fresh accumulation: exactly 1 distinct frame counted on this first tick.
    expect(out.confirmation.distinctGreenFrames).toBe(1)
  })
})

describe('createRuntimeShield — getState() reflects last decision state', () => {
  it('WAIT → CONFIRMING → SIGNAL_CONFIRMED 상태 전이를 getState()로 관찰할 수 있다', () => {
    const shield = createRuntimeShield()
    expect(shield.getState()).toBe('WAIT')
    runGoodTicks(shield, 0, 1)
    expect(shield.getState()).toBe('CONFIRMING')
    let out
    for (let i = 1; i < RTA_CONFIG_V1.minDistinctGreenFrames; i++) {
      const nowMonoMs = BASE_MONO + i * 400
      const nowEpochMs = BASE_EPOCH + i * 400
      out = shield.update(
        makeTick(i, {
          clock: { nowMonoMs, nowEpochMs },
          cits: { sourceEpochMs: nowEpochMs - 200, receivedAtMonoMs: nowMonoMs - 100 },
          vision: { capturedAtMonoMs: nowMonoMs - 50 },
        })
      )
    }
    expect(shield.getState()).toBe('SIGNAL_CONFIRMED')
  })
})
