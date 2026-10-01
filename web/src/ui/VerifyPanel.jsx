const DOT = { green: '🟢', red: '🔴', unknown: '⚪' }

export default function VerifyPanel({ cits, vision, tier, needSec }) {
  return (
    <section className="verify-panel" aria-label="검증 현황">
      <h2>이중 검증 현황 <span className={`tier-badge tier-${tier}`}>Tier {tier}</span></h2>
      <div className="verify-row">
        <span className="src-name">C-ITS 신호</span>
        {cits?.available ? (
          <span>{DOT[cits.color]} {cits.color === 'green' ? '초록' : cits.color === 'red' ? '빨강' : '불명'} · 잔여 {Math.round(cits.remainingSec)}초</span>
        ) : (
          <span className="src-down">⛔ 수신 불가 (Tier 2 강등)</span>
        )}
        {cits?.mock && <span className="mock-badge">모의 신호 주입 중</span>}
      </div>
      <div className="verify-row">
        <span className="src-name">비전 AI</span>
        <span>{DOT[vision?.color ?? 'unknown']} {vision?.color === 'green' ? '초록' : vision?.color === 'red' ? '빨강' : '불명'} · conf {(vision?.confidence ?? 0).toFixed(2)}</span>
      </div>
      <div className="verify-row">
        <span className="src-name">필요 횡단시간</span>
        <span>{needSec === Infinity ? '—' : `${needSec.toFixed(1)}초`} (10m ÷ 0.6m/s + 여유 2초)</span>
      </div>
    </section>
  )
}
