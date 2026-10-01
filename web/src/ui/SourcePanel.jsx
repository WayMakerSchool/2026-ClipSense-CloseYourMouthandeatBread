const COLOR_DOT = { green: '🟢', red: '🔴', unknown: '⚪' }
const COLOR_LABEL = { green: '초록', red: '빨강', unknown: '불명' }

function fmtMs(ms) {
  if (!Number.isFinite(ms)) return '—'
  return `${Math.round(ms)}ms`
}

function fmtSec(sec) {
  if (!Number.isFinite(sec)) return '—'
  return `${sec.toFixed(1)}초`
}

/**
 * 입력 소스 패널 (스펙 §2.10):
 * - 영상 배지 CAMERA|MOCK, C-ITS 배지 MOCK (LIVE 미연결 상태를 정직하게 표기)
 * - 카메라 모드에서는 C-ITS가 네트워크(/cits-mock)로 서빙됨을 명시하고
 *   poll 연결 상태(연결됨/끊김)를 함께 표기한다 (스펙 §W1.4).
 * - videoSourceLabel이 주어지면(카메라 모드) "내장 카메라"/"ESP32 스트림"을
 *   영상 배지에 덧붙인다 — vision.sourceMode 계약값(CAMERA)은 그대로 두고
 *   표시 텍스트만 구분한다 (스펙 §W3: "배지 텍스트는 enum과 달라도 됨").
 * - target 4필드 + roiBinding
 * - C-ITS 색/잔여/source age/receive age/seq
 * - Vision 색/score/quality/frame age/frameSeq
 */
export default function SourcePanel({ target, cits, vision, ages, citsNetworkState, videoSourceLabel }) {
  const visionSourceMode = vision?.sourceMode ?? 'MOCK'
  const citsSourceMode = cits?.sourceMode ?? 'MOCK'
  const citsBadgeLabel = citsNetworkState ? `C-ITS: MOCK(네트워크) · ${citsNetworkState}` : `C-ITS: ${citsSourceMode}`
  const visionBadgeLabel = videoSourceLabel ? `영상: ${visionSourceMode} (${videoSourceLabel})` : `영상: ${visionSourceMode}`

  return (
    <section className="source-panel" aria-label="입력 소스 현황">
      <h2>입력 소스</h2>

      <div className="source-badges">
        <span className={`badge badge-source badge-${visionSourceMode.toLowerCase()}`}>
          {visionBadgeLabel}
        </span>
        <span className={`badge badge-source badge-${citsSourceMode.toLowerCase()}`}>
          {citsBadgeLabel}
        </span>
      </div>

      <div className="source-block">
        <h3>Target (MANUAL BINDING)</h3>
        <div className="kv-grid">
          <span className="kv-key">교차로</span>
          <span className="kv-val">{target?.intersectionId ?? '—'}</span>
          <span className="kv-key">횡단보도</span>
          <span className="kv-val">{target?.crosswalkId ?? '—'}</span>
          <span className="kv-key">이동류</span>
          <span className="kv-val">{target?.movementId ?? '—'}</span>
          <span className="kv-key">방향</span>
          <span className="kv-val">{target?.direction ?? '—'}</span>
          <span className="kv-key">ROI 바인딩</span>
          <span className="kv-val">{target?.roiBindingId ?? '—'}</span>
        </div>
      </div>

      <div className="source-block">
        <h3>C-ITS</h3>
        <div className="kv-grid">
          <span className="kv-key">색상</span>
          <span className="kv-val">
            {COLOR_DOT[cits?.color ?? 'unknown']} {COLOR_LABEL[cits?.color ?? 'unknown']}
            {cits?.available === false && ' (수신 불가)'}
          </span>
          <span className="kv-key">잔여시간</span>
          <span className="kv-val">{fmtSec(cits?.remainingSec)}</span>
          <span className="kv-key">source age</span>
          <span className="kv-val">{fmtMs(ages?.citsSourceAgeMs)}</span>
          <span className="kv-key">receive age</span>
          <span className="kv-val">{fmtMs(ages?.citsReceiveAgeMs)}</span>
          <span className="kv-key">seq</span>
          <span className="kv-val">{cits?.seq ?? '—'}</span>
        </div>
      </div>

      <div className="source-block">
        <h3>Vision</h3>
        <div className="kv-grid">
          <span className="kv-key">색상</span>
          <span className="kv-val">
            {COLOR_DOT[vision?.color ?? 'unknown']} {COLOR_LABEL[vision?.color ?? 'unknown']}
          </span>
          <span className="kv-key">score</span>
          <span className="kv-val">{Number.isFinite(vision?.score) ? vision.score.toFixed(2) : '—'}</span>
          <span className="kv-key">quality</span>
          <span className="kv-val">{Number.isFinite(vision?.quality) ? vision.quality.toFixed(2) : '—'}</span>
          <span className="kv-key">frame age</span>
          <span className="kv-val">{fmtMs(ages?.visionAgeMs)}</span>
          <span className="kv-key">frameSeq</span>
          <span className="kv-val">{vision?.frameSeq ?? '—'}</span>
        </div>
      </div>
    </section>
  )
}
