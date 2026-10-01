// 14개 check 키 (즉시 검사 12종 + shield가 확인 누적으로부터 병합하는 2종).
// 순서는 원본설계서 §8/§15.3, 스펙 §2.4/§2.5의 정의 순서를 따른다.
const CHECK_LABELS = [
  ['inputValid', '입력 유효성 (Input Valid)'],
  ['targetBound', 'Target Binding'],
  ['targetMatch', 'Target Match'],
  ['citsAvailable', 'C-ITS Available'],
  ['citsFresh', 'C-ITS Freshness'],
  ['visionFresh', 'Vision Freshness'],
  ['sequenceValid', 'Sequence / Replay'],
  ['videoAdvancing', 'Video Advancing'],
  ['dualGreen', 'Dual Green'],
  ['visionScoreOk', 'Vision Score'],
  ['visionQualityOk', 'Vision Quality'],
  ['timeSufficient', 'Time Budget'],
  ['distinctFramesOk', 'Distinct Frames'],
  ['holdTimeOk', 'Confirmation Hold'],
]

/**
 * 안전 게이트 패널 (스펙 §2.10): 14개 check를 아이콘+텍스트로 PASS/BLOCK
 * 표시한다 (색상 단독으로 의미를 전달하지 않는다). failedChecks에 포함된
 * reason code에 대응하는 check는 별도로 하이라이트한다.
 */
export default function SafetyGatePanel({ checks, failedChecks }) {
  const failedSet = new Set(Array.isArray(failedChecks) ? failedChecks : [])
  // failedChecks는 reason code 목록이라 check 키와 이름이 다를 수 있으므로,
  // 실패한 check는 checks[key] === false로 직접 판정한다. failedSet은
  // "이 tick에서 어떤 reason이 실제로 원인이 되었는지"를 보조 표시하는 데만 쓴다.

  return (
    <section className="gate-panel" aria-label="14개 안전 게이트">
      <h2>안전 게이트 (14 checks)</h2>
      <ul className="gate-list">
        {CHECK_LABELS.map(([key, label]) => {
          const value = checks?.[key]
          const pass = value === true
          return (
            <li key={key} className={`gate-item ${pass ? 'gate-pass' : 'gate-block'}`}>
              <span className="gate-icon" aria-hidden="true">{pass ? '✅' : '⛔'}</span>
              <span className="gate-label">{label}</span>
              <span className="gate-status">{pass ? 'PASS' : 'BLOCK'}</span>
            </li>
          )
        })}
      </ul>
      <div className="gate-failed">
        <span className="gate-failed-label">failedChecks (reason codes)</span>
        {failedSet.size === 0 ? (
          <span className="gate-failed-empty">없음</span>
        ) : (
          <ul className="gate-failed-list">
            {[...failedSet].map((code) => (
              <li key={code}>{code}</li>
            ))}
          </ul>
        )}
      </div>
    </section>
  )
}
