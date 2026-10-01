/**
 * SafeGraph-RTA 버전이 있는 실험 설정 (원본설계서 §7).
 * 안전 인증 기준이 아니라 예선 기술 검증용 실험 설정이다.
 * 임계값은 이 파일에만 존재한다 — 다른 파일에 중복 하드코딩하지 않는다.
 */
export const RTA_CONFIG_V1 = {
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
}
