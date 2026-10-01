import { describe, it, expect } from 'vitest'
import { RTA_CONFIG_V1 } from '../../src/safety/config.js'
import { REASONS } from '../../src/safety/reasonCodes.js'
import { evaluateChecks } from '../../src/safety/safeGraphChecks.js'

// ---- Valid baseline samples (원본 §6 / §7) ----
const baseTarget = () => ({
  intersectionId: 'demo-int-001',
  crosswalkId: 'demo-cw-north-01',
  movementId: 'demo-ped-move-01',
  direction: 'NORTHBOUND',
  roiBindingId: 'roi-ped-north-01',
  bindingMethod: 'MANUAL_DEMO',
})

const baseCits = () => ({
  available: true,
  color: 'green',
  remainingSec: 35,
  intersectionId: 'demo-int-001',
  crosswalkId: 'demo-cw-north-01',
  movementId: 'demo-ped-move-01',
  direction: 'NORTHBOUND',
  sourceEpochMs: 1784780000000,
  receivedAtMonoMs: 1200,
  seq: 101,
  sourceMode: 'MOCK',
})

const baseVision = () => ({
  color: 'green',
  score: 0.87,
  quality: 0.8,
  roiBindingId: 'roi-ped-north-01',
  capturedAtMonoMs: 1180,
  frameSeq: 205,
  mediaTimeMs: 5240,
  sourceMode: 'RECORDED',
})

const baseClock = () => ({
  nowEpochMs: 1784780000200, // sourceEpochMs + 200ms
  nowMonoMs: 1300, // receivedAtMonoMs + 100ms; capturedAtMonoMs + 120ms
})

const baseUser = () => ({ walkingSpeedMps: 0.6 })
const baseCrosswalk = () => ({ lengthM: 10, marginSec: 2 })

const baseInput = () => ({
  target: baseTarget(),
  cits: baseCits(),
  vision: baseVision(),
  user: baseUser(),
  crosswalk: baseCrosswalk(),
  clock: baseClock(),
  config: RTA_CONFIG_V1,
  history: null,
})

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

describe('evaluateChecks — 출력 계약 (원본 §10)', () => {
  it('checks 객체는 14키를 전부 갖는다', () => {
    const { checks } = evaluateChecks(baseInput())
    expect(Object.keys(checks).sort()).toEqual([...ALL_CHECK_KEYS].sort())
  })

  it('distinctFramesOk / holdTimeOk는 항상 false다 (shield가 병합)', () => {
    const { checks } = evaluateChecks(baseInput())
    expect(checks.distinctFramesOk).toBe(false)
    expect(checks.holdTimeOk).toBe(false)
  })

  it('정상 입력에서는 12개 즉시 검사가 전부 true다', () => {
    const { checks, failedChecks } = evaluateChecks(baseInput())
    expect(checks.inputValid).toBe(true)
    expect(checks.targetBound).toBe(true)
    expect(checks.targetMatch).toBe(true)
    expect(checks.citsAvailable).toBe(true)
    expect(checks.citsFresh).toBe(true)
    expect(checks.visionFresh).toBe(true)
    expect(checks.sequenceValid).toBe(true)
    expect(checks.videoAdvancing).toBe(true)
    expect(checks.dualGreen).toBe(true)
    expect(checks.visionScoreOk).toBe(true)
    expect(checks.visionQualityOk).toBe(true)
    expect(checks.timeSufficient).toBe(true)
    expect(failedChecks).toEqual([])
  })

  it('ages 객체를 반환한다 (citsSourceAgeMs/citsReceiveAgeMs/visionAgeMs)', () => {
    const { ages } = evaluateChecks(baseInput())
    expect(ages).toEqual({
      citsSourceAgeMs: 200,
      citsReceiveAgeMs: 100,
      visionAgeMs: 120,
    })
  })

  it('requiredCrossingSec을 crossingTime.js 공식으로 반환한다', () => {
    const { requiredCrossingSec } = evaluateChecks(baseInput())
    // 10 / 0.6 + 2 = 18.666...
    expect(requiredCrossingSec).toBeCloseTo(18.6667, 3)
  })
})

describe('evaluateChecks — 순수성', () => {
  it('같은 입력을 두 번 호출하면 동일한 출력을 반환한다', () => {
    const input = baseInput()
    const r1 = evaluateChecks(input)
    const r2 = evaluateChecks(input)
    expect(r1).toEqual(r2)
  })

  it('history를 변형하지 않는다', () => {
    const history = { lastCitsSeq: 100, lastFrameSeq: 200, lastFrameAdvanceMonoMs: 1000, lastMediaTimeMs: 5000 }
    const historyCopy = { ...history }
    evaluateChecks({ ...baseInput(), history })
    expect(history).toEqual(historyCopy)
  })

  it('입력 객체를 변형하지 않는다', () => {
    const input = baseInput()
    const snapshot = JSON.parse(JSON.stringify(input))
    evaluateChecks(input)
    expect(input).toEqual(snapshot)
  })
})

describe('evaluateChecks — invalid 입력 (계약 불합격)', () => {
  it('target 계약 불합격 → inputValid false, failedChecks는 INVALID_INPUT만, 나머지 검사 전부 false', () => {
    const input = { ...baseInput(), target: { ...baseTarget(), intersectionId: '' } }
    const { checks, failedChecks } = evaluateChecks(input)
    expect(checks.inputValid).toBe(false)
    expect(failedChecks).toEqual([REASONS.INVALID_INPUT])
    for (const key of ALL_CHECK_KEYS) {
      if (key === 'inputValid') continue
      expect(checks[key]).toBe(false)
    }
  })

  it('cits 계약 불합격(잘못된 color enum) → INVALID_INPUT만', () => {
    const input = { ...baseInput(), cits: { ...baseCits(), color: 'purple' } }
    const { failedChecks } = evaluateChecks(input)
    expect(failedChecks).toEqual([REASONS.INVALID_INPUT])
  })

  it('vision 계약 불합격(score NaN) → INVALID_INPUT만', () => {
    const input = { ...baseInput(), vision: { ...baseVision(), score: NaN } }
    const { failedChecks } = evaluateChecks(input)
    expect(failedChecks).toEqual([REASONS.INVALID_INPUT])
  })

  it('clock 계약 불합격(Infinity) → INVALID_INPUT만', () => {
    const input = { ...baseInput(), clock: { nowEpochMs: Infinity, nowMonoMs: 100 } }
    const { failedChecks } = evaluateChecks(input)
    expect(failedChecks).toEqual([REASONS.INVALID_INPUT])
  })

  it('config 계약 불합격(음수 threshold) → INVALID_INPUT만', () => {
    const input = { ...baseInput(), config: { ...RTA_CONFIG_V1, minVisionScore: -1 } }
    const { failedChecks } = evaluateChecks(input)
    expect(failedChecks).toEqual([REASONS.INVALID_INPUT])
  })

  it('invalid 입력의 ages/effectiveRemainingSec/requiredCrossingSec은 안전 방향(0 또는 Infinity류)이다', () => {
    const input = { ...baseInput(), target: null }
    const { effectiveRemainingSec } = evaluateChecks(input)
    expect(effectiveRemainingSec).toBeLessThanOrEqual(0)
  })
})

describe('evaluateChecks — targetMatch (원본 §8.1, §19.2)', () => {
  it('전 필드 일치 → targetMatch true', () => {
    const { checks } = evaluateChecks(baseInput())
    expect(checks.targetMatch).toBe(true)
  })

  it('intersection만 불일치 → targetMatch false + TARGET_MISMATCH', () => {
    const input = { ...baseInput(), cits: { ...baseCits(), intersectionId: 'other-int' } }
    const { checks, failedChecks } = evaluateChecks(input)
    expect(checks.targetMatch).toBe(false)
    expect(failedChecks).toContain(REASONS.TARGET_MISMATCH)
  })

  it('crosswalk만 불일치 → targetMatch false + TARGET_MISMATCH', () => {
    const input = { ...baseInput(), cits: { ...baseCits(), crosswalkId: 'other-cw' } }
    const { checks, failedChecks } = evaluateChecks(input)
    expect(checks.targetMatch).toBe(false)
    expect(failedChecks).toContain(REASONS.TARGET_MISMATCH)
  })

  it('movement만 불일치 → targetMatch false + TARGET_MISMATCH', () => {
    const input = { ...baseInput(), cits: { ...baseCits(), movementId: 'other-move' } }
    const { checks, failedChecks } = evaluateChecks(input)
    expect(checks.targetMatch).toBe(false)
    expect(failedChecks).toContain(REASONS.TARGET_MISMATCH)
  })

  it('direction만 불일치 → targetMatch false + TARGET_MISMATCH', () => {
    const input = { ...baseInput(), cits: { ...baseCits(), direction: 'SOUTHBOUND' } }
    const { checks, failedChecks } = evaluateChecks(input)
    expect(checks.targetMatch).toBe(false)
    expect(failedChecks).toContain(REASONS.TARGET_MISMATCH)
  })

  it('ROI binding 불일치 → targetMatch false + TARGET_MISMATCH', () => {
    const input = { ...baseInput(), vision: { ...baseVision(), roiBindingId: 'other-roi' } }
    const { checks, failedChecks } = evaluateChecks(input)
    expect(checks.targetMatch).toBe(false)
    expect(failedChecks).toContain(REASONS.TARGET_MISMATCH)
  })
})

describe('evaluateChecks — freshness 경계값 (원본 §8.2, config maxCitsSourceAgeMs=2000/maxVisionAgeMs=500/maxCitsReceiveAgeMs=1500)', () => {
  it('citsSourceAge 1999ms → citsFresh true', () => {
    const clock = { nowEpochMs: baseCits().sourceEpochMs + 1999, nowMonoMs: 1300 }
    const input = { ...baseInput(), clock }
    const { checks, ages } = evaluateChecks(input)
    expect(ages.citsSourceAgeMs).toBe(1999)
    expect(checks.citsFresh).toBe(true)
  })

  it('citsSourceAge 2001ms → citsFresh false + CITS_STALE', () => {
    const clock = { nowEpochMs: baseCits().sourceEpochMs + 2001, nowMonoMs: 1300 }
    const input = { ...baseInput(), clock }
    const { checks, failedChecks, ages } = evaluateChecks(input)
    expect(ages.citsSourceAgeMs).toBe(2001)
    expect(checks.citsFresh).toBe(false)
    expect(failedChecks).toContain(REASONS.CITS_STALE)
  })

  it('visionAge 499ms → visionFresh true', () => {
    const clock = { nowEpochMs: baseClock().nowEpochMs, nowMonoMs: baseVision().capturedAtMonoMs + 499 }
    const input = { ...baseInput(), clock }
    const { checks, ages } = evaluateChecks(input)
    expect(ages.visionAgeMs).toBe(499)
    expect(checks.visionFresh).toBe(true)
  })

  it('visionAge 501ms → visionFresh false + VISION_STALE', () => {
    const clock = { nowEpochMs: baseClock().nowEpochMs, nowMonoMs: baseVision().capturedAtMonoMs + 501 }
    const input = { ...baseInput(), clock }
    const { checks, failedChecks, ages } = evaluateChecks(input)
    expect(ages.visionAgeMs).toBe(501)
    expect(checks.visionFresh).toBe(false)
    expect(failedChecks).toContain(REASONS.VISION_STALE)
  })

  it('receiveAge 1499ms → citsFresh true', () => {
    const clock = { nowEpochMs: baseClock().nowEpochMs, nowMonoMs: baseCits().receivedAtMonoMs + 1499 }
    const input = { ...baseInput(), clock }
    const { checks, ages } = evaluateChecks(input)
    expect(ages.citsReceiveAgeMs).toBe(1499)
    expect(checks.citsFresh).toBe(true)
  })

  it('receiveAge 1501ms → citsFresh false + CITS_STALE', () => {
    const clock = { nowEpochMs: baseClock().nowEpochMs, nowMonoMs: baseCits().receivedAtMonoMs + 1501 }
    const input = { ...baseInput(), clock }
    const { checks, failedChecks, ages } = evaluateChecks(input)
    expect(ages.citsReceiveAgeMs).toBe(1501)
    expect(checks.citsFresh).toBe(false)
    expect(failedChecks).toContain(REASONS.CITS_STALE)
  })
})

describe('evaluateChecks — 미래 timestamp / clock skew (원본 §8.2, futureClockToleranceMs=250)', () => {
  it('citsSourceAge -200ms (tol 250 이내) → citsFresh true', () => {
    const clock = { nowEpochMs: baseCits().sourceEpochMs - 200, nowMonoMs: 1300 }
    const input = { ...baseInput(), clock }
    const { checks, ages } = evaluateChecks(input)
    expect(ages.citsSourceAgeMs).toBe(-200)
    expect(checks.citsFresh).toBe(true)
  })

  it('citsSourceAge -300ms (tol 초과) → citsFresh false + CITS_STALE', () => {
    const clock = { nowEpochMs: baseCits().sourceEpochMs - 300, nowMonoMs: 1300 }
    const input = { ...baseInput(), clock }
    const { checks, failedChecks, ages } = evaluateChecks(input)
    expect(ages.citsSourceAgeMs).toBe(-300)
    expect(checks.citsFresh).toBe(false)
    expect(failedChecks).toContain(REASONS.CITS_STALE)
  })

  it('visionAge -200ms (tol 이내) → visionFresh true', () => {
    const clock = { nowEpochMs: baseClock().nowEpochMs, nowMonoMs: baseVision().capturedAtMonoMs - 200 }
    const input = { ...baseInput(), clock }
    const { checks } = evaluateChecks(input)
    expect(checks.visionFresh).toBe(true)
  })

  it('visionAge -300ms (tol 초과) → visionFresh false + VISION_STALE', () => {
    const clock = { nowEpochMs: baseClock().nowEpochMs, nowMonoMs: baseVision().capturedAtMonoMs - 300 }
    const input = { ...baseInput(), clock }
    const { checks, failedChecks } = evaluateChecks(input)
    expect(checks.visionFresh).toBe(false)
    expect(failedChecks).toContain(REASONS.VISION_STALE)
  })
})

describe('evaluateChecks — sequence/replay/reorder (원본 §8.3)', () => {
  it('cits.seq 역전(101→100, history.lastCitsSeq=101) → sequenceValid false + REPLAY_OR_REORDER', () => {
    const history = { lastCitsSeq: 101, lastFrameSeq: 200, lastFrameAdvanceMonoMs: 1000, lastMediaTimeMs: 5000 }
    const input = { ...baseInput(), cits: { ...baseCits(), seq: 100 }, history }
    const { checks, failedChecks } = evaluateChecks(input)
    expect(checks.sequenceValid).toBe(false)
    expect(failedChecks).toContain(REASONS.REPLAY_OR_REORDER)
  })

  it('vision.frameSeq 역전(205→204, history.lastFrameSeq=205) → sequenceValid false + REPLAY_OR_REORDER', () => {
    const history = { lastCitsSeq: 100, lastFrameSeq: 205, lastFrameAdvanceMonoMs: 1000, lastMediaTimeMs: 5000 }
    const input = { ...baseInput(), vision: { ...baseVision(), frameSeq: 204 }, history }
    const { checks, failedChecks } = evaluateChecks(input)
    expect(checks.sequenceValid).toBe(false)
    expect(failedChecks).toContain(REASONS.REPLAY_OR_REORDER)
  })

  it('동일 seq는 sequenceValid를 실패시키지 않는다 (freshness가 별도로 판정)', () => {
    const history = { lastCitsSeq: 101, lastFrameSeq: 205, lastFrameAdvanceMonoMs: 1200, lastMediaTimeMs: 5240 }
    const input = { ...baseInput(), history }
    const { checks } = evaluateChecks(input)
    expect(checks.sequenceValid).toBe(true)
  })

  it('history가 null이면(첫 tick) sequenceValid는 통과한다', () => {
    const input = { ...baseInput(), history: null }
    const { checks } = evaluateChecks(input)
    expect(checks.sequenceValid).toBe(true)
  })

  it('history가 비어있는 객체({})여도 sequenceValid는 통과한다', () => {
    const input = { ...baseInput(), history: {} }
    const { checks } = evaluateChecks(input)
    expect(checks.sequenceValid).toBe(true)
  })

  it('음수 seq끼리의 역전도 정상적으로 REPLAY_OR_REORDER로 잡힌다', () => {
    const history = { lastCitsSeq: -5, lastFrameSeq: 200, lastFrameAdvanceMonoMs: 1000, lastMediaTimeMs: 5000 }
    const input = { ...baseInput(), cits: { ...baseCits(), seq: -10 }, history }
    const { checks, failedChecks } = evaluateChecks(input)
    expect(checks.sequenceValid).toBe(false)
    expect(failedChecks).toContain(REASONS.REPLAY_OR_REORDER)
  })
})

describe('evaluateChecks — freeze (원본 §8.3, freezeTimeoutMs=750)', () => {
  it('lastFrameAdvanceMonoMs로부터 750ms 경과 → videoAdvancing true (경계 포함)', () => {
    const history = { lastCitsSeq: 100, lastFrameSeq: 200, lastFrameAdvanceMonoMs: 1000, lastMediaTimeMs: 5000 }
    const clock = { nowEpochMs: baseClock().nowEpochMs, nowMonoMs: 1000 + 750 }
    const input = { ...baseInput(), clock, history }
    const { checks } = evaluateChecks(input)
    expect(checks.videoAdvancing).toBe(true)
  })

  it('lastFrameAdvanceMonoMs로부터 751ms 경과 → videoAdvancing false + VIDEO_FROZEN', () => {
    const history = { lastCitsSeq: 100, lastFrameSeq: 200, lastFrameAdvanceMonoMs: 1000, lastMediaTimeMs: 5000 }
    const clock = { nowEpochMs: baseClock().nowEpochMs, nowMonoMs: 1000 + 751 }
    const input = { ...baseInput(), clock, history }
    const { checks, failedChecks } = evaluateChecks(input)
    expect(checks.videoAdvancing).toBe(false)
    expect(failedChecks).toContain(REASONS.VIDEO_FROZEN)
  })

  it('history 없음(첫 tick) → videoAdvancing true', () => {
    const input = { ...baseInput(), history: null }
    const { checks } = evaluateChecks(input)
    expect(checks.videoAdvancing).toBe(true)
  })
})

describe('evaluateChecks — dualGreen / 신호·비전 품질 (원본 §8.4, §19.2)', () => {
  it('cits red → dualGreen false + RED_SIGNAL', () => {
    const input = { ...baseInput(), cits: { ...baseCits(), color: 'red' } }
    const { checks, failedChecks } = evaluateChecks(input)
    expect(checks.dualGreen).toBe(false)
    expect(failedChecks).toContain(REASONS.RED_SIGNAL)
  })

  it('cits unknown → dualGreen false + RED_SIGNAL', () => {
    const input = { ...baseInput(), cits: { ...baseCits(), color: 'unknown' } }
    const { checks, failedChecks } = evaluateChecks(input)
    expect(checks.dualGreen).toBe(false)
    expect(failedChecks).toContain(REASONS.RED_SIGNAL)
  })

  it('cits green × vision red → dualGreen false + SOURCE_MISMATCH (RED_SIGNAL 아님)', () => {
    const input = { ...baseInput(), vision: { ...baseVision(), color: 'red' } }
    const { checks, failedChecks } = evaluateChecks(input)
    expect(checks.dualGreen).toBe(false)
    expect(failedChecks).toContain(REASONS.SOURCE_MISMATCH)
    expect(failedChecks).not.toContain(REASONS.RED_SIGNAL)
  })

  it('cits green × vision unknown → dualGreen false + VISION_UNCERTAIN', () => {
    const input = { ...baseInput(), vision: { ...baseVision(), color: 'unknown' } }
    const { checks, failedChecks } = evaluateChecks(input)
    expect(checks.dualGreen).toBe(false)
    expect(failedChecks).toContain(REASONS.VISION_UNCERTAIN)
  })

  it('vision score 미달(< minVisionScore 0.75) → visionScoreOk false + VISION_UNCERTAIN', () => {
    const input = { ...baseInput(), vision: { ...baseVision(), score: 0.5 } }
    const { checks, failedChecks } = evaluateChecks(input)
    expect(checks.visionScoreOk).toBe(false)
    expect(failedChecks).toContain(REASONS.VISION_UNCERTAIN)
  })

  it('vision quality 미달(< minVisionQuality 0.50) → visionQualityOk false + VISION_UNCERTAIN', () => {
    const input = { ...baseInput(), vision: { ...baseVision(), quality: 0.2 } }
    const { checks, failedChecks } = evaluateChecks(input)
    expect(checks.visionQualityOk).toBe(false)
    expect(failedChecks).toContain(REASONS.VISION_UNCERTAIN)
  })

  it('cits.available === false → citsAvailable false + CITS_MISSING, dualGreen false, RED_SIGNAL 없음', () => {
    const input = { ...baseInput(), cits: { ...baseCits(), available: false } }
    const { checks, failedChecks } = evaluateChecks(input)
    expect(checks.citsAvailable).toBe(false)
    expect(checks.dualGreen).toBe(false)
    expect(failedChecks).toContain(REASONS.CITS_MISSING)
    expect(failedChecks).not.toContain(REASONS.RED_SIGNAL)
  })

  it('cits.available === false + color red → 여전히 CITS_MISSING만, RED_SIGNAL 아님 (연결 끊김을 적색으로 오분류하지 않는다)', () => {
    const input = { ...baseInput(), cits: { ...baseCits(), available: false, color: 'red' } }
    const { checks, failedChecks } = evaluateChecks(input)
    expect(checks.citsAvailable).toBe(false)
    expect(failedChecks).toContain(REASONS.CITS_MISSING)
    expect(failedChecks).not.toContain(REASONS.RED_SIGNAL)
  })

  it('cits.available === false + color unknown → 여전히 CITS_MISSING만, RED_SIGNAL 아님', () => {
    const input = { ...baseInput(), cits: { ...baseCits(), available: false, color: 'unknown' } }
    const { checks, failedChecks } = evaluateChecks(input)
    expect(checks.citsAvailable).toBe(false)
    expect(failedChecks).toContain(REASONS.CITS_MISSING)
    expect(failedChecks).not.toContain(REASONS.RED_SIGNAL)
  })

  it('cits.available === false + color green → 여전히 CITS_MISSING만, RED_SIGNAL 아님', () => {
    const input = { ...baseInput(), cits: { ...baseCits(), available: false, color: 'green' } }
    const { checks, failedChecks } = evaluateChecks(input)
    expect(checks.citsAvailable).toBe(false)
    expect(failedChecks).toContain(REASONS.CITS_MISSING)
    expect(failedChecks).not.toContain(REASONS.RED_SIGNAL)
  })

  it('score 경계: score === minVisionScore(0.75) → visionScoreOk true', () => {
    const input = { ...baseInput(), vision: { ...baseVision(), score: 0.75 } }
    const { checks } = evaluateChecks(input)
    expect(checks.visionScoreOk).toBe(true)
  })

  it('quality 경계: quality === minVisionQuality(0.50) → visionQualityOk true', () => {
    const input = { ...baseInput(), vision: { ...baseVision(), quality: 0.5 } }
    const { checks } = evaluateChecks(input)
    expect(checks.visionQualityOk).toBe(true)
  })
})

describe('evaluateChecks — 시간 충분성 (원본 §8.5, §19.2 정확한 예시)', () => {
  it('remaining 35, sourceAge 200ms, budget 500ms → effective = 34.3 ≥ 18.67+1.5 → timeSufficient true', () => {
    // requiredCrossingSec = 10/0.6 + 2 = 18.6667; + confirmHoldMs/1000 (1.5) = 20.1667
    const clock = { nowEpochMs: baseCits().sourceEpochMs + 200, nowMonoMs: 1300 }
    const input = {
      ...baseInput(),
      cits: { ...baseCits(), remainingSec: 35 },
      clock,
    }
    const { checks, effectiveRemainingSec, requiredCrossingSec } = evaluateChecks(input)
    expect(effectiveRemainingSec).toBeCloseTo(34.3, 5)
    expect(requiredCrossingSec).toBeCloseTo(18.6667, 3)
    expect(checks.timeSufficient).toBe(true)
  })

  it('remaining 20, sourceAge 200ms, budget 500ms → effective = 19.3 < 20.17 → timeSufficient false + TIME_SHORT', () => {
    const clock = { nowEpochMs: baseCits().sourceEpochMs + 200, nowMonoMs: 1300 }
    const input = {
      ...baseInput(),
      cits: { ...baseCits(), remainingSec: 20 },
      clock,
    }
    const { checks, failedChecks, effectiveRemainingSec } = evaluateChecks(input)
    expect(effectiveRemainingSec).toBeCloseTo(19.3, 5)
    expect(checks.timeSufficient).toBe(false)
    expect(failedChecks).toContain(REASONS.TIME_SHORT)
  })

  it('crosswalk 길이가 유효하지 않으면 requiredCrossingSec=Infinity → timeSufficient false + TIME_SHORT', () => {
    const input = { ...baseInput(), crosswalk: { lengthM: -1, marginSec: 2 } }
    const { checks, failedChecks, requiredCrossingSec } = evaluateChecks(input)
    expect(requiredCrossingSec).toBe(Infinity)
    expect(checks.timeSufficient).toBe(false)
    expect(failedChecks).toContain(REASONS.TIME_SHORT)
  })

  it('crosswalk.marginSec을 requiredCrossingSec 계산에 전달한다', () => {
    const input = { ...baseInput(), crosswalk: { lengthM: 10, marginSec: 5 } }
    const { requiredCrossingSec } = evaluateChecks(input)
    expect(requiredCrossingSec).toBeCloseTo(10 / 0.6 + 5, 3)
  })
})

describe('evaluateChecks — failedChecks 종합', () => {
  it('여러 실패가 동시에 발생하면 failedChecks에 모두 보존된다', () => {
    const input = {
      ...baseInput(),
      cits: { ...baseCits(), color: 'red', intersectionId: 'other-int' },
    }
    const { failedChecks } = evaluateChecks(input)
    expect(failedChecks).toContain(REASONS.TARGET_MISMATCH)
    expect(failedChecks).toContain(REASONS.RED_SIGNAL)
  })

  it('failedChecks에 중복 코드가 없다', () => {
    const input = {
      ...baseInput(),
      vision: { ...baseVision(), score: 0.1, quality: 0.1 },
    }
    const { failedChecks } = evaluateChecks(input)
    const seen = new Set(failedChecks)
    expect(seen.size).toBe(failedChecks.length)
  })
})
