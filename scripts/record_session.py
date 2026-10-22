"""실제 클립 사진 + 웹 판독 + 작은 교차로 정답을 한 줄씩 기록한다 (증거·학습 데이터 수집).

clip_web.py(/api/frame)와 mini_intersection.py(/state)가 떠 있는 상태에서 실행한다.
새 프레임(부팅ID:프레임번호)마다 JPEG 한 장과 frames.jsonl 한 줄을 저장한다.
정답 phase는 휴대폰 화면이 실제로 그 색을 띄우고 있었다는 뜻이지, 도로 신호가 아니다.

  .venv/bin/python scripts/record_session.py --out output/session_YYYYmmdd_HHMM --seconds 600
"""
from __future__ import annotations

import argparse
import base64
import json
import time
import urllib.request
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path


def get_json(opener, url):
    with opener.open(url, timeout=1.0) as resp:
        return json.load(resp)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--web', default='http://127.0.0.1:5173')
    ap.add_argument('--mini', default='http://127.0.0.1:8765', help='작은 교차로. 없으면 정답 없이 기록')
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--seconds', type=float, default=600)
    args = ap.parse_args()
    (args.out / 'frames').mkdir(parents=True, exist_ok=True)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    log = (args.out / 'frames.jsonl').open('a', encoding='utf-8')
    seen, stats = set(), Counter()
    end = time.monotonic() + args.seconds
    print(f'기록 중 → {args.out} (Ctrl+C로 종료)', flush=True)
    try:
        while time.monotonic() < end:
            time.sleep(0.1)
            try:
                snap = get_json(opener, args.web + '/api/frame')
            except Exception:
                stats['web_error'] += 1
                continue
            truth = None
            try:
                truth = get_json(opener, args.mini + '/state')
            except Exception:
                pass
            frame = snap.get('frame')
            key = f"{frame['bootId']}:{frame['seq']}" if frame else None
            row = {'at': datetime.now(timezone.utc).isoformat(), 'connection': snap['connection'],
                   'decision': snap['decision'], 'reason': snap['decisionReason'],
                   'guidance': snap['guidance'], 'visionState': snap.get('visionState'),
                   'truth': truth and {k: truth.get(k) for k in ('phase', 'remainMs', 'lampOn', 'apiMode')}}
            if frame is None:
                # 사진이 없는 상태(끊김·만료)도 상태가 바뀔 때만 남긴다.
                state = ('none', snap['connection'], snap['guidance'])
                if state not in seen:
                    seen.add(state)
                    log.write(json.dumps({**row, 'frame': None}, ensure_ascii=False) + '\n')
                continue
            if key in seen:
                continue
            seen.add(key)
            name = f"{frame['bootId']}_{frame['seq']:06d}.jpg"
            (args.out / 'frames' / name).write_bytes(base64.b64decode(frame['jpeg']))
            meta = {k: frame.get(k) for k in ('seq', 'bootId', 'jpegSha256', 'raw', 'stable',
                                               'detectorReason', 'digits', 'digitsFrame', 'boxes', 'rotated')}
            meta['sensor'] = frame['source'].get('sensor')
            log.write(json.dumps({**row, 'file': name, 'frame': meta}, ensure_ascii=False) + '\n')
            log.flush()
            stats['frames'] += 1
            label = truth['phase'] if truth else '-'
            stats[f"{label}->{frame['raw']}"] += 1
            if stats['frames'] % 20 == 0:
                print(f"{stats['frames']}장 · 정답→판독 {dict((k, v) for k, v in stats.items() if '->' in k)}", flush=True)
    except KeyboardInterrupt:
        pass
    finally:
        log.close()
        (args.out / 'summary.json').write_text(json.dumps(dict(stats), ensure_ascii=False, indent=1))
        print('끝:', dict(stats), flush=True)


if __name__ == '__main__':
    main()
