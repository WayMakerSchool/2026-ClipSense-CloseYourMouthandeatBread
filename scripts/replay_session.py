"""기록한 실사진 세션을 현재 웹 판단 과정(ClipFeed)에 순서대로 다시 넣어 안내를 재계산한다.

record_session.py가 저장한 frames.jsonl + frames/*.jpg(이미 회전된 화면용 사진)를 쓴다.
라이브 당시 안내와 재계산 안내를, 그 순간 휴대폰 화면 정답(작은 교차로 phase)과 함께 비교한다.

  .venv/bin/python scripts/replay_session.py output/session_20261022_1532 --out replay.csv
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from collections import Counter
from datetime import datetime
from email.message import Message
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from clip_web import ClipFeed  # noqa: E402


def headers(seq, boot, uptime_us):
    out = Message()
    for k, v in {'Content-Type': 'image/jpeg', 'X-Frame-Seq': str(seq),
                 'X-Capture-Uptime-Us': str(uptime_us), 'X-Response-Uptime-Us': str(uptime_us + 1000),
                 'X-Boot-Id': boot, 'X-Camera-Sensor': 'OV3660'}.items():
        out[k] = v
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('session', type=Path)
    ap.add_argument('--out', type=Path)
    args = ap.parse_args()
    rows = [json.loads(line) for line in open(args.session / 'frames.jsonl') if '"file"' in line]
    t0 = datetime.fromisoformat(rows[0]['at']).timestamp()
    now = {'t': 0.0}
    feed = ClipFeed('http://replay.invalid', 'replay', clock=lambda: now['t'], vision='head')
    stats, out = Counter(), []
    for r in rows:
        now['t'] = datetime.fromisoformat(r['at']).timestamp() - t0 + 1000
        f = r['frame']
        jpeg = (args.session / 'frames' / r['file']).read_bytes()
        feed.accept(jpeg, headers(f['seq'], f['bootId'], int(now['t'] * 1e6)), 10, now['t'])
        snap = feed.snapshot()
        phase = r['truth']['phase'] if r['truth'] else None
        live_green = '초록' in r['guidance']
        new_green = '초록' in snap['guidance']
        raw_now = (snap['frame'] or {}).get('raw')
        bad_live = live_green and (f['raw'] == 'RED' or f['detectorReason'] == 'no_signal_head')
        bad_new = new_green and (raw_now == 'RED' or (snap['frame'] or {}).get('detectorReason') == 'no_signal_head')
        stats['frames'] += 1
        stats['live_green_on_red_or_nohead'] += bad_live
        stats['new_green_on_red_or_nohead'] += bad_new
        stats[f'live:{r["guidance"][:6]}'] += 1
        stats[f'new:{snap["guidance"][:6]}'] += 1
        out.append({'at': r['at'], 'seq': f['seq'], 'truth_phase': phase, 'live_raw': f['raw'],
                    'live_guidance': r['guidance'], 'replay_raw': raw_now,
                    'replay_state': snap.get('visionState'), 'replay_digits': (snap['frame'] or {}).get('digits'),
                    'replay_guidance': snap['guidance'], 'file': r['file']})
    if args.out:
        with open(args.out, 'w', newline='', encoding='utf-8') as fp:
            w = csv.DictWriter(fp, fieldnames=list(out[0]))
            w.writeheader()
            w.writerows(out)
    print(json.dumps(dict(stats), ensure_ascii=False, indent=1))


if __name__ == '__main__':
    main()
