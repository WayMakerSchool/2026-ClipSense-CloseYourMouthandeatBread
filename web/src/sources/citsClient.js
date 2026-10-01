/**
 * 경찰청 C-ITS 실시간 보행신호 클라이언트.
 * 모든 실패는 { available: false }로 수렴한다 — throw하지 않는다.
 * 실패가 곧 tierResolver의 Tier 2 자동 강등 신호이기 때문이다.
 */
const STAT_MAP = {
  'protected-Movement-Allowed': 'green',
  'permissive-Movement-Allowed': 'green',
  'stop-And-Remain': 'red',
  'stop-Then-Proceed': 'red',
}

const UNAVAILABLE = { color: 'unknown', remainingSec: 0, available: false }

/** item의 방위별 보행신호 필드를 파싱. dir: nt|et|st|wt (북/동/남/서) */
export function parsePedSignal(item, dir = 'nt') {
  if (!item || typeof item !== 'object') return { ...UNAVAILABLE }
  const stat = item[`${dir}PdsgStatNm`]
  const rmdrCs = item[`${dir}PdsgRmdrCs`]
  const color = STAT_MAP[stat]
  if (!color || !Number.isFinite(Number(rmdrCs))) return { ...UNAVAILABLE }
  return { color, remainingSec: Number(rmdrCs) / 10, available: true }
}

export async function fetchSignal({ itstId, dir = 'nt', timeoutMs = 3000, fetchFn = fetch } = {}) {
  const ctrl = new AbortController()
  const timer = setTimeout(() => ctrl.abort(), timeoutMs)
  try {
    const res = await fetchFn(`/cits?itstId=${encodeURIComponent(itstId ?? '')}&type=json&numOfRows=1`, {
      signal: ctrl.signal,
    })
    if (!res.ok) return { ...UNAVAILABLE }
    const json = await res.json()
    let item = json?.response?.body?.items?.item
    if (Array.isArray(item)) item = item[0]
    return parsePedSignal(item, dir)
  } catch {
    return { ...UNAVAILABLE }
  } finally {
    clearTimeout(timer)
  }
}
