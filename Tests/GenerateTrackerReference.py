"""Development-only oracle. Python/Ultralytics are NOT used by the app."""
import json
import os
from pathlib import Path
os.environ['YOLO_AUTOINSTALL'] = 'false'
os.environ['YOLO_CONFIG_DIR'] = '/tmp/benur-tracker-reference'
import numpy as np
from ultralytics.engine.results import Boxes
from ultralytics.trackers.bot_sort import BOTSORT
from ultralytics.utils import YAML, IterableSimpleNamespace
from ultralytics.utils.checks import check_yaml

rng = np.random.default_rng(481)
cases = []

def add(name, frames, fps=30):
    args = YAML.load(check_yaml('botsort.yaml'))
    args.update(gmc_method='none', with_reid=False, track_buffer=fps)
    tracker = BOTSORT(IterableSimpleNamespace(**args))
    detections, expected = [], []
    for frame in frames:
        array = np.asarray(frame, dtype=np.float32).reshape(-1, 6)
        detections.append([dict(bbox=row[:4].tolist(), confidence=float(row[4]), classID=int(row[5])) for row in array])
        tracks = tracker.update(Boxes(array, orig_shape=(720, 1280)))
        expected.append([dict(id=int(t[4]), detectionIndex=int(t[-1]), bbox=t[:4].tolist(), confidence=float(t[5])) for t in tracks])
    cases.append(dict(name=name, fps=fps, frames=detections, expected=expected))

box = lambda x, score=.9: [x, 100, x+40, 140, score, 0]
add('activation-low-score-recovery-occlusion', [[box(100)], [box(102,.2)], [], [box(106)], [box(108)]])
add('tentative-confirmation-and-removal', [[], [box(100)], [], [box(200)], [box(202)], [], [box(206)]])
add('lost-expiration', [[box(100)]] + [[]]*8 + [[box(100)], [box(102)]], fps=3)
add('empty-frames', [[]]*8)
# Crossings, variable confidence, occlusions, decoys and changing box dimensions.
for case in range(12):
    frames=[]
    objects = rng.uniform([50,50,-2,-2,20,20], [900,500,2,2,80,100], size=(8,6))
    for f in range(100):
        frame=[]
        for i,(x,y,vx,vy,w,h) in enumerate(objects):
            if rng.random() < .16 or (i == 0 and 35 < f < 65): continue
            confidence = float(rng.uniform(.11,.24) if rng.random() < .18 else rng.uniform(.4,.99))
            left = x+vx*f+rng.normal(0,.5); top=y+vy*f+rng.normal(0,.5)
            frame.append([left,top,left+w*(1+.01*np.sin(f)),top+h,confidence,0])
        if f%13==0:
            frame.append([1100,10,1120,30,.7,0])
        rng.shuffle(frame)
        frames.append(frame)
    add(f'random-motion-{case}', frames)
output = Path('Tests/tracker-reference.json')
output.write_text(json.dumps(dict(upstream='ultralytics==8.4.177', gmc='none (association parity only)', cases=cases)))
print(f'Wrote {len(cases)} cases / {sum(len(c["frames"]) for c in cases)} frames to {output}')
