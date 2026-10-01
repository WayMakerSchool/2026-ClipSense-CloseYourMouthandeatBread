function defaultSpeak(message) {
  if (typeof speechSynthesis === 'undefined') return
  speechSynthesis.cancel() // 이전 안내 즉시 중단 — 최신 판정이 항상 우선
  const u = new SpeechSynthesisUtterance(message)
  u.lang = 'ko-KR'
  u.rate = 1.05
  speechSynthesis.speak(u)
}

/** 같은 안내의 기관총 반복을 막는 발화 관리자. 메시지가 바뀌면 즉시 발화. */
export function createAnnouncer({ speak = defaultSpeak, cooldownMs = 4000 } = {}) {
  let lastMessage = null
  let lastAt = -Infinity
  return {
    announce(message, nowMs) {
      if (!message) return false
      if (message === lastMessage && nowMs - lastAt < cooldownMs) return false
      lastMessage = message
      lastAt = nowMs
      speak(message)
      return true
    },
  }
}
