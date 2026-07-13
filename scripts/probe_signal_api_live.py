"""서울 T-Data 실서버 1회 수동 확인. 키는 환경변수 TDATA_KEY.
실행: TDATA_KEY=... python scripts/probe_signal_api_live.py [itstId] [방위]
자동 테스트 아님 — 실동작 대조용. 응답의 색·잔여가 실제 신호와 맞는지 눈으로 확인.
"""
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from signal_api import fetch_reading

key = os.environ.get("TDATA_KEY", "").strip()
if not key:
    print("환경변수 TDATA_KEY가 필요합니다.")
    sys.exit(1)

itst = sys.argv[1] if len(sys.argv) > 1 else "1537"
direction = sys.argv[2] if len(sys.argv) > 2 else "ne"
now_ms = int(time.time() * 1000)

r = fetch_reading(itst, direction, key, now_ms=now_ms)
print(f"교차로 {itst} 방위 {direction}: color={r.color} "
      f"remain={r.remain_sec} fresh_ms={r.fresh_ms} raw={r.raw!r}")
