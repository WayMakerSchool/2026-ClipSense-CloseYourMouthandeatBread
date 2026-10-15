import { useEffect, useState } from 'react'
import { normalizeBoardAddress, startBoardPolling } from '../sources/boardCapture.js'
import './BoardPhotoPanel.css'

export default function BoardPhotoPanel() {
  const [address, setAddress] = useState('')
  const [token, setToken] = useState('')
  const [connection, setConnection] = useState(null)
  const [frame, setFrame] = useState(null)
  const [error, setError] = useState('')

  useEffect(() => {
    if (!connection) return undefined
    let imageUrl
    const clearImage = () => {
      if (imageUrl) URL.revokeObjectURL(imageUrl)
      imageUrl = undefined
      setFrame(null)
    }
    const stop = startBoardPolling({
      ...connection,
      onFrame(photo) {
        const nextUrl = URL.createObjectURL(photo.blob)
        if (imageUrl) URL.revokeObjectURL(imageUrl)
        imageUrl = nextUrl
        setFrame({ ...photo, url: imageUrl })
        setError('')
      },
      onError(message) {
        clearImage()
        setError(message)
      },
    })
    return () => {
      stop()
      if (imageUrl) URL.revokeObjectURL(imageUrl)
    }
  }, [connection])

  const disconnect = () => {
    setConnection(null)
    setFrame(null)
    setError('')
  }
  const connect = (event) => {
    event.preventDefault()
    disconnect()
    try {
      setConnection({ address: normalizeBoardAddress(address), token })
    } catch (problem) {
      setError(problem.message)
    }
  }

  return (
    <section className="board-photo-panel" aria-labelledby="board-photo-heading">
      <h2 id="board-photo-heading">클립 보드 사진</h2>
      <p>사진 확인 전용 · 아래 횡단 판정의 카메라 입력에는 사용되지 않습니다.</p>
      <form className="board-photo-form" onSubmit={connect}>
        <label htmlFor="board-address">보드 주소
          <input id="board-address" type="text" inputMode="url" placeholder="http://192.168.0.50 또는 localhost:8080"
            value={address} onChange={(event) => { disconnect(); setAddress(event.target.value) }}
            autoCapitalize="none" autoCorrect="off" spellCheck={false} required />
        </label>
        <label htmlFor="board-token">기기 토큰
          <input id="board-token" type="password" value={token}
            onChange={(event) => { disconnect(); setToken(event.target.value) }} autoComplete="off" />
        </label>
        <button type="submit">연결 / 다시 연결</button>
        <button type="button" onClick={disconnect} disabled={!connection}>수신 중지</button>
      </form>
      <p>토큰은 현재 화면의 메모리에만 보관합니다. 연결하면 1초마다 사진을 요청합니다.</p>
      <p role={error ? 'alert' : 'status'} className={`board-photo-status${error ? ' board-photo-error' : ''}`}>
        {error || (connection ? (frame ? '사진 수신 중 · 1초 간격' : '보드에 연결 중…') : '보드 주소와 기기 토큰을 입력하고 연결해 주세요.')}
      </p>
      {frame ? <>
        <dl className="board-photo-meta">
          <div><dt>사진 번호</dt><dd>{frame.seq}</dd></div>
          <div className={frame.sourceLabel === '노트북 촬영' ? 'board-photo-laptop' : ''}>
            <dt>출처</dt><dd>{frame.sourceLabel}</dd>
          </div>
        </dl>
        <p>카메라 센서: {frame.sensor || '미제공'} · 출처 헤더: {frame.source || '미제공'}</p>
        <img className="board-photo-image" src={frame.url} alt={`${frame.sourceLabel} · 사진 번호 ${frame.seq}`}
          onError={() => { setFrame(null); setError('사진을 표시할 수 없습니다. 보드의 JPEG 응답을 확인해 주세요.') }} />
      </> : <p className="board-photo-empty">표시할 사진이 없습니다.</p>}
    </section>
  )
}
