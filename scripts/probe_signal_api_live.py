"""서울 T-Data 실서버 1회 진단 호출. 자동 테스트가 아니라 실동작 대조용이다.

실행:
    python scripts/probe_signal_api_live.py [itstId] [방위]      # 기본 1537 ne
키: 환경변수 TDATA_KEY, 없으면 ~/.clipsense/tdata_key. 키는 출력하지 않는다.

출력: HTTP 상태, 호출 제한(429) 정보, 데이터 생성 후 경과 시간, 방위별 보행신호,
그리고 앱 판정 계층(parse_reading)이 이 응답을 어떻게 읽는지.

주의(2026-10-01 실측): 기존 엔드포인트는 키당 5분에 1회만 허용하고(초과 시 429
V2X_REPEAT_CALL_LIMIT), 응답 데이터도 약 30분 전 등록분이다. 서버는 실시간 용도로
v2xSignalPhaseTimingFusionCurrentInfo API를 안내한다(별도 활용신청 필요로 보임).
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from signal_api import DEFAULT_BASE_URL, parse_reading  # noqa: E402

DIRECTIONS = ["nt", "et", "st", "wt", "ne", "se", "sw", "nw"]


def load_key() -> str:
    key = os.environ.get("TDATA_KEY", "").strip()
    path = Path.home() / ".clipsense" / "tdata_key"
    if not key and path.exists():
        key = path.read_text().strip()
    return key


def main() -> int:
    key = load_key()
    if not key:
        print("키가 없습니다: TDATA_KEY 환경변수 또는 ~/.clipsense/tdata_key")
        return 1
    itst = sys.argv[1] if len(sys.argv) > 1 else "1537"
    direction = sys.argv[2] if len(sys.argv) > 2 else "ne"
    base = os.environ.get("TDATA_BASE_URL", DEFAULT_BASE_URL)
    query = urllib.parse.urlencode(
        {"apiKey": key, "type": "json", "itstId": itst, "numOfRows": "10"})
    req = urllib.request.Request(f"{base}?{query}", headers={"User-Agent": "clipsense/1.0"})

    sent_ms = int(time.time() * 1000)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            status, body = resp.status, resp.read()
    except urllib.error.HTTPError as e:
        status, body = e.code, e.read()
    except Exception as e:  # 네트워크 오류
        print(f"네트워크 오류: {type(e).__name__}")
        return 1
    rtt_ms = int(time.time() * 1000) - sent_ms
    print(f"엔드포인트 {base.rsplit('/', 2)[-2]} · 교차로 {itst} · HTTP {status} · 왕복 {rtt_ms}ms")

    try:
        data = json.loads(body)
    except ValueError:
        print("JSON 아님:", body[:200].decode("utf-8", "replace").replace(key, "<KEY>"))
        return 1

    if status == 429 and isinstance(data, dict):
        print(f"호출 제한: {data.get('code')} · 다음 호출 가능 {data.get('nextCallAvailableAt')}")
        print("서버 안내:", str(data.get("message", "")).replace(key, "<KEY>"))
        return 2
    if status != 200 or not isinstance(data, list):
        print("오류 응답:", json.dumps(data, ensure_ascii=False)[:300].replace(key, "<KEY>"))
        return 1

    records = [r for r in data if str(r.get("itstId")) == str(itst)] or data
    if not records:
        print("레코드 없음")
        return 1
    r = records[0]
    now_ms = int(time.time() * 1000)
    trsm = r.get("trsmUtcTime")
    age = (now_ms - float(trsm)) / 1000 if trsm else None
    print(f"레코드 {len(data)}개 · 전송시각 기준 데이터 나이 "
          f"{'알 수 없음' if age is None else f'{age:.1f}초'} · 등록 {r.get('regDt')}")
    for d in DIRECTIONS:
        st, rm = r.get(f"{d}PdsgStatNm"), r.get(f"{d}PdsgRmdrCs")
        if st or rm is not None:
            remain = "-" if rm is None else f"{float(rm) / 10:.1f}초"
            print(f"  보행 {d}: {st} · 잔여 {remain}")

    reading = parse_reading(data, direction, now_ms=now_ms, itst_id=itst)
    print(f"앱 판정 계층 해석({direction}): color={reading.color} "
          f"remain={reading.remain_sec} fresh_ms={reading.fresh_ms}"
          + ("  ← 2초보다 오래되어 UNKNOWN" if age and age > 2 else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
