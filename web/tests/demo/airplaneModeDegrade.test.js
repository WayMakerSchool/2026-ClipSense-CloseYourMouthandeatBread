import { describe, it, expect } from 'vitest'
import { RTA_CONFIG_V1 } from '../../src/safety/config.js'
import { REASONS } from '../../src/safety/reasonCodes.js'
import { createRuntimeShield } from '../../src/safety/runtimeShield.js'

/**
 * 헤드리스 재현: 카메라 모드에서 /cits-mock 폴이 실패/중단(비행기 모드)될 때
 * safety tick이 "마지막으로 성공한 cits observation"을 계속 재사용하며
 * clock만 흘러가는 상황을 그대로 흉내낸다 (App.jsx의 citsRef 패턴과 동일 —
 * poll 실패 시 citsRef.current는 makeUnavailableCits로 교체되지만, 이
 * 테스트는 "poll이 아예 멈춰서(예: setInterval 자체가 안 돌 정도로 극단적
 * 네트워크 단절) 마지막 성공 응답이 그대로 남아있는" 한 단계 더 가혹한
 * 경로 — 즉 CITS_STALE 경로 — 를 검증한다. 실제 App에서는 poll 실패마다
 * makeUnavailableCits로 교체되어 CITS_MISSING이 즉시 뜨므로 이 시나리오는
 * "그보다 느리게 감지되더라도 결국 안전측으로 수렴한다"는 하한 보장이다).
 *
 * 스펙 §W1.3: "poll이 실패/중단되어도 safety tick은 계속 평가하고, 마지막
 * 성공 관측치의 age가 자라 CITS_STALE → WAIT으로 수렴한다"를 clock을 실제
 * ms 단위로 계속 전진시키며 증명한다.
 */

const TICK_MS = 100
const BASE_EPOCH = 1_800_000_000_000
const BASE_MONO = 5_000_000

const TARGET = Object.freeze({
  intersectionId: 'demo-int-001',
  crosswalkId: 'demo-cw-north-01',
  movementId: 'demo-ped-move-01',
  direction: 'NORTHBOUND',
  roiBindingId: 'roi-ped-north-01',
  bindingMethod: 'MANUAL_DEMO',
})

function freshCits(nowEpochMs, nowMonoMs, seq) {
  return {
    available: true,
    color: 'green',
    remainingSec: 35,
    intersectionId: TARGET.intersectionId,
    crosswalkId: TARGET.crosswalkId,
    movementId: TARGET.movementId,
    direction: TARGET.direction,
    sourceEpochMs: nowEpochMs,
    receivedAtMonoMs: nowMonoMs,
    seq,
    sourceMode: 'MOCK',
  }
}

function freshVision(nowMonoMs, frameSeq) {
  return {
    color: 'green',
    score: 0.9,
    quality: 0.8,
    roiBindingId: TARGET.roiBindingId,
    capturedAtMonoMs: nowMonoMs,
    frameSeq,
    mediaTimeMs: nowMonoMs,
    sourceMode: 'CAMERA',
  }
}

describe('카메라 모드 비행기 모드 열화 경로 (headless)', () => {
  it('CITS poll이 멈춘 뒤 clock만 전진하면 CITS_STALE → WAIT으로 수렴한다', () => {
    const shield = createRuntimeShield()

    // 1) 정상 구간: dual green을 유지해 SIGNAL_CONFIRMED까지 끌어올린다.
    //    (minDistinctGreenFrames=5, confirmHoldMs=1500ms → 100ms tick으로 20틱이면 충분)
    let lastOut
    let citsSeq = 500
    let frameSeq = 900
    let lastGoodCits = freshCits(BASE_EPOCH, BASE_MONO, citsSeq)

    for (let i = 0; i < 20; i++) {
      const nowEpochMs = BASE_EPOCH + i * TICK_MS
      const nowMonoMs = BASE_MONO + i * TICK_MS
      frameSeq += 1
      citsSeq += 1
      // poll이 살아있는 동안은 매 CITS_TICK_MS마다 새로 도착하는 관측치를
      // 흉내낸다 — sourceEpochMs가 clock을 계속 따라간다(진짜 live poll처럼).
      lastGoodCits = freshCits(nowEpochMs, nowMonoMs, citsSeq)
      lastOut = shield.update({
        target: TARGET,
        cits: lastGoodCits,
        vision: freshVision(nowMonoMs, frameSeq),
        user: { walkingSpeedMps: 0.6 },
        crosswalk: { lengthM: 10, marginSec: 2 },
        clock: { nowEpochMs, nowMonoMs },
      })
    }

    expect(lastOut.decision).toBe('SIGNAL_CONFIRMED')

    // 2) "비행기 모드": poll이 완전히 멈췄다고 가정하고 citsRef는 더 이상
    //    갱신되지 않는다(lastGoodCits 그대로) — 오직 clock만 실제 ms만큼 전진한다.
    //    citsSourceAgeMs = nowEpochMs - cits.sourceEpochMs가 maxCitsSourceAgeMs(2000ms)를
    //    넘어서는 순간부터 citsFresh 체크가 실패해야 한다.
    const airplaneStartTick = 20
    const ticksUntilStale = Math.ceil(RTA_CONFIG_V1.maxCitsSourceAgeMs / TICK_MS) + 2 // 여유

    let staleDetectedAtMs = null
    for (let i = airplaneStartTick; i < airplaneStartTick + ticksUntilStale; i++) {
      const nowEpochMs = BASE_EPOCH + i * TICK_MS
      const nowMonoMs = BASE_MONO + i * TICK_MS
      frameSeq += 1
      lastOut = shield.update({
        target: TARGET,
        cits: lastGoodCits, // 갱신 없음 — poll이 멈춘 상태를 흉내
        vision: freshVision(nowMonoMs, frameSeq), // vision은 계속 살아있음(카메라는 정상)
        user: { walkingSpeedMps: 0.6 },
        crosswalk: { lengthM: 10, marginSec: 2 },
        clock: { nowEpochMs, nowMonoMs },
      })
      if (staleDetectedAtMs === null && lastOut.decision === 'WAIT') {
        staleDetectedAtMs = nowEpochMs - BASE_EPOCH
      }
    }

    // 3) 최종적으로 WAIT이어야 하고, 원인은 CITS_STALE이어야 한다 (CITS_MISSING이 아님 —
    //    available은 여전히 true인 "오래된" 관측치이기 때문).
    expect(lastOut.decision).toBe('WAIT')
    expect(lastOut.reason).toBe(REASONS.CITS_STALE)
    expect(lastOut.checks.citsAvailable).toBe(true)
    expect(lastOut.checks.citsFresh).toBe(false)

    // 4) age 성장이 몇 초 내(데모 스펙: "몇 초 안에 WAIT으로 열화") 안에 감지됐는지 확인.
    expect(staleDetectedAtMs).not.toBeNull()
    expect(staleDetectedAtMs).toBeLessThan(5000)
    expect(lastOut.ages.citsSourceAgeMs).toBeGreaterThan(RTA_CONFIG_V1.maxCitsSourceAgeMs)
  })

  it('poll 실패 즉시 makeUnavailableCits 모양의 관측치라면 CITS_MISSING → WAIT을 즉시 낸다', () => {
    // App.jsx의 실제 경로: poll이 실패하면 citsRef는 바로 available:false 관측치로
    // 교체된다(freeze가 아니라 즉시 대체). 이 케이스는 그 경로가 CITS_MISSING을
    // 내지 INVALID_INPUT을 내지 않음을 못박아 둔다 (계약 형태를 반드시 유지해야 함).
    const shield = createRuntimeShield()
    const nowEpochMs = BASE_EPOCH
    const nowMonoMs = BASE_MONO

    const unavailableCits = {
      available: false,
      color: 'unknown',
      remainingSec: 0,
      intersectionId: TARGET.intersectionId,
      crosswalkId: TARGET.crosswalkId,
      movementId: TARGET.movementId,
      direction: TARGET.direction,
      sourceEpochMs: nowEpochMs,
      receivedAtMonoMs: nowMonoMs,
      seq: 1,
      sourceMode: 'MOCK',
    }

    const out = shield.update({
      target: TARGET,
      cits: unavailableCits,
      vision: freshVision(nowMonoMs, 1),
      user: { walkingSpeedMps: 0.6 },
      crosswalk: { lengthM: 10, marginSec: 2 },
      clock: { nowEpochMs, nowMonoMs },
    })

    expect(out.decision).toBe('WAIT')
    expect(out.reason).toBe(REASONS.CITS_MISSING)
    expect(out.checks.inputValid).toBe(true) // 계약 자체는 유효 — INVALID_INPUT이 아님
    expect(out.checks.citsAvailable).toBe(false)
  })
})
