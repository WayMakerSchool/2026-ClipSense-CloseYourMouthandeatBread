import { describe, it, expect } from 'vitest'
import { RTA_CONFIG_V1 } from '../../src/safety/config.js'
import {
  REASONS,
  REASON_PRIORITY,
  pickPrimaryReason,
  MESSAGES,
  confirmedMessage,
} from '../../src/safety/reasonCodes.js'
import {
  validateTargetContext,
  validateCitsObservation,
  validateVisionObservation,
  validateClock,
  validateConfig,
} from '../../src/safety/contracts.js'

// ---- Valid samples (원본 §6) ----
const validTarget = {
  intersectionId: 'demo-int-001',
  crosswalkId: 'demo-cw-north-01',
  movementId: 'demo-ped-move-01',
  direction: 'NORTHBOUND',
  roiBindingId: 'roi-ped-north-01',
  bindingMethod: 'MANUAL_DEMO',
}

const validCits = {
  available: true,
  color: 'green',
  remainingSec: 30,
  intersectionId: 'demo-int-001',
  crosswalkId: 'demo-cw-north-01',
  movementId: 'demo-ped-move-01',
  direction: 'NORTHBOUND',
  sourceEpochMs: 1784780000000,
  receivedAtMonoMs: 1200,
  seq: 101,
  sourceMode: 'MOCK',
}

const validVision = {
  color: 'green',
  score: 0.87,
  quality: 0.8,
  roiBindingId: 'roi-ped-north-01',
  capturedAtMonoMs: 1180,
  frameSeq: 205,
  mediaTimeMs: 5240,
  sourceMode: 'RECORDED',
}

const validClock = {
  nowEpochMs: 1784780000800,
  nowMonoMs: 2000,
}

describe('RTA_CONFIG_V1 (원본 §7)', () => {
  it('11개 키를 정확한 값으로 갖는다', () => {
    expect(RTA_CONFIG_V1).toEqual({
      configVersion: 'safegraph-rta-demo-v1',
      minVisionScore: 0.75,
      minVisionQuality: 0.50,
      maxCitsSourceAgeMs: 2000,
      maxCitsReceiveAgeMs: 1500,
      maxVisionAgeMs: 500,
      freezeTimeoutMs: 750,
      futureClockToleranceMs: 250,
      minDistinctGreenFrames: 5,
      confirmHoldMs: 1500,
      latencyBudgetMs: 500,
    })
  })
})

describe('REASONS (원본 §10, 17개 코드)', () => {
  it('17개 reason code를 동명 문자열 값으로 갖는다', () => {
    const expected = [
      'INVALID_INPUT',
      'TARGET_UNBOUND',
      'TARGET_MISMATCH',
      'CITS_MISSING',
      'CITS_STALE',
      'VISION_STALE',
      'REPLAY_OR_REORDER',
      'VIDEO_FROZEN',
      'RED_SIGNAL',
      'VISION_UNCERTAIN',
      'SOURCE_MISMATCH',
      'TIME_SHORT',
      'CONFIRMING',
      'SAFEGRAPH_CONFIRMED',
      'VISION_ONLY_INFORMATION',
      'NO_SIGNAL_INFORMATION',
      'INTERNAL_ERROR',
    ]
    expect(Object.keys(REASONS).sort()).toEqual([...expected].sort())
    for (const code of expected) {
      expect(REASONS[code]).toBe(code)
    }
  })
})

describe('pickPrimaryReason (스펙 §2.2 순서)', () => {
  it("['TIME_SHORT','TARGET_MISMATCH'] → TARGET_MISMATCH", () => {
    expect(pickPrimaryReason(['TIME_SHORT', 'TARGET_MISMATCH'])).toBe('TARGET_MISMATCH')
  })

  it("['CITS_STALE','RED_SIGNAL'] → RED_SIGNAL", () => {
    expect(pickPrimaryReason(['CITS_STALE', 'RED_SIGNAL'])).toBe('RED_SIGNAL')
  })

  it('빈 배열 → INVALID_INPUT', () => {
    expect(pickPrimaryReason([])).toBe('INVALID_INPUT')
  })

  it('목록에 없는 코드만 있으면 → INVALID_INPUT (fail-safe)', () => {
    expect(pickPrimaryReason(['NOT_A_REAL_CODE'])).toBe('INVALID_INPUT')
  })

  it('REASON_PRIORITY는 스펙 §2.2 순서를 그대로 따른다', () => {
    expect(REASON_PRIORITY).toEqual([
      'INVALID_INPUT',
      'TARGET_UNBOUND',
      'TARGET_MISMATCH',
      'RED_SIGNAL',
      'CITS_MISSING',
      'CITS_STALE',
      'VISION_STALE',
      'REPLAY_OR_REORDER',
      'VIDEO_FROZEN',
      'VISION_UNCERTAIN',
      'SOURCE_MISMATCH',
      'TIME_SHORT',
      'CONFIRMING',
    ])
  })
})

describe('MESSAGES (원본 §9.4 byte-exact)', () => {
  it('WAIT 문구', () => {
    expect(MESSAGES.WAIT).toBe('현재 횡단 안내를 제공할 수 없습니다. 대기하세요.')
  })

  it('VERIFYING 문구', () => {
    expect(MESSAGES.VERIFYING).toBe('보행신호를 확인하고 있습니다. 대기하세요.')
  })

  it('INFORMATION_ONLY 문구', () => {
    expect(MESSAGES.INFORMATION_ONLY).toBe('신호 정보가 일부만 확인되었습니다. 횡단 판단을 제공하지 않습니다.')
  })

  it('confirmedMessage는 정수 잔여초를 템플릿에 삽입한다', () => {
    expect(confirmedMessage(26)).toBe('보행신호가 확인되었습니다. 잔여시간은 26초입니다. 주변 차량에 주의하세요.')
  })

  it('confirmedMessage는 소수 입력도 정수로 표기한다', () => {
    expect(confirmedMessage(26.1)).toBe('보행신호가 확인되었습니다. 잔여시간은 26초입니다. 주변 차량에 주의하세요.')
  })
})

describe('validateTargetContext', () => {
  it('유효 표본 → ok', () => {
    expect(validateTargetContext(validTarget)).toEqual({ ok: true, errors: [] })
  })

  it.each([
    'intersectionId',
    'crosswalkId',
    'movementId',
    'direction',
    'roiBindingId',
  ])('%s 누락 → 불합격', (field) => {
    const { [field]: _drop, ...rest } = validTarget
    const result = validateTargetContext(rest)
    expect(result.ok).toBe(false)
    expect(result.errors).toContain(field)
  })

  it.each([
    'intersectionId',
    'crosswalkId',
    'movementId',
    'direction',
    'roiBindingId',
  ])('%s 빈 문자열 → 불합격', (field) => {
    const result = validateTargetContext({ ...validTarget, [field]: '' })
    expect(result.ok).toBe(false)
    expect(result.errors).toContain(field)
  })

  it.each([
    'intersectionId',
    'crosswalkId',
    'movementId',
    'direction',
    'roiBindingId',
  ])('%s 공백만 → 불합격', (field) => {
    const result = validateTargetContext({ ...validTarget, [field]: '   ' })
    expect(result.ok).toBe(false)
    expect(result.errors).toContain(field)
  })

  it("bindingMethod가 'MANUAL_DEMO'가 아니면 불합격", () => {
    const result = validateTargetContext({ ...validTarget, bindingMethod: 'AUTO' })
    expect(result.ok).toBe(false)
    expect(result.errors).toContain('bindingMethod')
  })

  it('bindingMethod 누락 → 불합격', () => {
    const { bindingMethod: _drop, ...rest } = validTarget
    const result = validateTargetContext(rest)
    expect(result.ok).toBe(false)
    expect(result.errors).toContain('bindingMethod')
  })

  it('입력이 null/undefined여도 throw하지 않는다', () => {
    expect(() => validateTargetContext(null)).not.toThrow()
    expect(() => validateTargetContext(undefined)).not.toThrow()
    expect(validateTargetContext(null).ok).toBe(false)
  })
})

describe('validateCitsObservation', () => {
  it('유효 표본 → ok', () => {
    expect(validateCitsObservation(validCits)).toEqual({ ok: true, errors: [] })
  })

  it('color enum 위반 → 불합격', () => {
    const result = validateCitsObservation({ ...validCits, color: 'blue' })
    expect(result.ok).toBe(false)
    expect(result.errors).toContain('color')
  })

  it('remainingSec NaN → 불합격', () => {
    const result = validateCitsObservation({ ...validCits, remainingSec: NaN })
    expect(result.ok).toBe(false)
    expect(result.errors).toContain('remainingSec')
  })

  it('remainingSec Infinity → 불합격', () => {
    const result = validateCitsObservation({ ...validCits, remainingSec: Infinity })
    expect(result.ok).toBe(false)
    expect(result.errors).toContain('remainingSec')
  })

  it('remainingSec 음수 → 불합격', () => {
    const result = validateCitsObservation({ ...validCits, remainingSec: -1 })
    expect(result.ok).toBe(false)
    expect(result.errors).toContain('remainingSec')
  })

  it('sourceEpochMs 누락 → 불합격', () => {
    const { sourceEpochMs: _drop, ...rest } = validCits
    const result = validateCitsObservation(rest)
    expect(result.ok).toBe(false)
    expect(result.errors).toContain('sourceEpochMs')
  })

  it('seq 비정수 → 불합격', () => {
    const result = validateCitsObservation({ ...validCits, seq: 1.5 })
    expect(result.ok).toBe(false)
    expect(result.errors).toContain('seq')
  })

  it('sourceMode enum 위반 → 불합격', () => {
    const result = validateCitsObservation({ ...validCits, sourceMode: 'FAKE' })
    expect(result.ok).toBe(false)
    expect(result.errors).toContain('sourceMode')
  })

  it("sourceMode:'LIVE'인데 sourceEpochMs 없음 → 불합격", () => {
    const { sourceEpochMs: _drop, ...rest } = validCits
    const result = validateCitsObservation({ ...rest, sourceMode: 'LIVE' })
    expect(result.ok).toBe(false)
    expect(result.errors).toContain('sourceEpochMs')
  })

  it("sourceMode:'LIVE'이고 sourceEpochMs 있으면 → ok", () => {
    const result = validateCitsObservation({ ...validCits, sourceMode: 'LIVE' })
    expect(result.ok).toBe(true)
  })

  it('입력이 null이어도 throw하지 않는다', () => {
    expect(() => validateCitsObservation(null)).not.toThrow()
    expect(validateCitsObservation(null).ok).toBe(false)
  })
})

describe('validateVisionObservation', () => {
  it('유효 표본 → ok', () => {
    expect(validateVisionObservation(validVision)).toEqual({ ok: true, errors: [] })
  })

  it('score < 0 → 불합격', () => {
    const result = validateVisionObservation({ ...validVision, score: -0.1 })
    expect(result.ok).toBe(false)
    expect(result.errors).toContain('score')
  })

  it('score > 1 → 불합격', () => {
    const result = validateVisionObservation({ ...validVision, score: 1.1 })
    expect(result.ok).toBe(false)
    expect(result.errors).toContain('score')
  })

  it('score NaN → 불합격', () => {
    const result = validateVisionObservation({ ...validVision, score: NaN })
    expect(result.ok).toBe(false)
    expect(result.errors).toContain('score')
  })

  it('quality < 0 → 불합격', () => {
    const result = validateVisionObservation({ ...validVision, quality: -0.1 })
    expect(result.ok).toBe(false)
    expect(result.errors).toContain('quality')
  })

  it('quality > 1 → 불합격', () => {
    const result = validateVisionObservation({ ...validVision, quality: 1.1 })
    expect(result.ok).toBe(false)
    expect(result.errors).toContain('quality')
  })

  it('quality NaN → 불합격', () => {
    const result = validateVisionObservation({ ...validVision, quality: NaN })
    expect(result.ok).toBe(false)
    expect(result.errors).toContain('quality')
  })

  it('frameSeq 누락 → 불합격', () => {
    const { frameSeq: _drop, ...rest } = validVision
    const result = validateVisionObservation(rest)
    expect(result.ok).toBe(false)
    expect(result.errors).toContain('frameSeq')
  })

  it('roiBindingId 빈 문자열 → 불합격', () => {
    const result = validateVisionObservation({ ...validVision, roiBindingId: '' })
    expect(result.ok).toBe(false)
    expect(result.errors).toContain('roiBindingId')
  })

  it('입력이 null이어도 throw하지 않는다', () => {
    expect(() => validateVisionObservation(null)).not.toThrow()
    expect(validateVisionObservation(null).ok).toBe(false)
  })
})

describe('validateClock', () => {
  it('유효 표본 → ok', () => {
    expect(validateClock(validClock)).toEqual({ ok: true, errors: [] })
  })

  it('nowEpochMs가 NaN → 불합격', () => {
    const result = validateClock({ ...validClock, nowEpochMs: NaN })
    expect(result.ok).toBe(false)
    expect(result.errors).toContain('nowEpochMs')
  })

  it('nowMonoMs가 NaN → 불합격', () => {
    const result = validateClock({ ...validClock, nowMonoMs: NaN })
    expect(result.ok).toBe(false)
    expect(result.errors).toContain('nowMonoMs')
  })

  it('둘 다 NaN → 둘 다 불합격', () => {
    const result = validateClock({ nowEpochMs: NaN, nowMonoMs: NaN })
    expect(result.ok).toBe(false)
    expect(result.errors).toContain('nowEpochMs')
    expect(result.errors).toContain('nowMonoMs')
  })

  it('Infinity → 불합격', () => {
    expect(validateClock({ ...validClock, nowEpochMs: Infinity }).ok).toBe(false)
    expect(validateClock({ ...validClock, nowMonoMs: Infinity }).ok).toBe(false)
  })

  it('입력이 null이어도 throw하지 않는다', () => {
    expect(() => validateClock(null)).not.toThrow()
    expect(validateClock(null).ok).toBe(false)
  })
})

describe('validateConfig', () => {
  it('RTA_CONFIG_V1 → ok', () => {
    expect(validateConfig(RTA_CONFIG_V1)).toEqual({ ok: true, errors: [] })
  })

  it.each([
    'minVisionScore',
    'minVisionQuality',
    'maxCitsSourceAgeMs',
    'maxCitsReceiveAgeMs',
    'maxVisionAgeMs',
    'freezeTimeoutMs',
    'futureClockToleranceMs',
    'minDistinctGreenFrames',
    'confirmHoldMs',
    'latencyBudgetMs',
  ])('%s 음수 임계값 → 불합격', (field) => {
    const result = validateConfig({ ...RTA_CONFIG_V1, [field]: -1 })
    expect(result.ok).toBe(false)
    expect(result.errors).toContain(field)
  })

  it('configVersion 누락 → 불합격', () => {
    const { configVersion: _drop, ...rest } = RTA_CONFIG_V1
    const result = validateConfig(rest)
    expect(result.ok).toBe(false)
    expect(result.errors).toContain('configVersion')
  })

  it('입력이 null이어도 throw하지 않는다', () => {
    expect(() => validateConfig(null)).not.toThrow()
    expect(validateConfig(null).ok).toBe(false)
  })
})
