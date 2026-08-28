#!/usr/bin/env python3
"""ila_analyze.py <pvm_ila_capture.csv> [--around N] [--cols regex]
Vivado ILA CSV -> a compact event trace: every sample where any (selected) probe changes value,
printed as sample# / delta / changed columns, plus the trigger sample and a per-column summary of
the final (wedged) state. Column names are the hierarchical probe names from the .ltx."""
import csv, re, sys
path = sys.argv[1]
around = int(sys.argv[sys.argv.index('--around')+1]) if '--around' in sys.argv else 400
colre = re.compile(sys.argv[sys.argv.index('--cols')+1]) if '--cols' in sys.argv else None
rows = list(csv.reader(open(path)))
hdr = rows[0]; data = rows[1:]
# Vivado CSV: Sample in Buffer, Sample in Window, TRIGGER, <probes...>
def short(n):
    n = re.sub(r'\[\d+:\d+\]$', '', n)
    return n.split('/')[-1]
cols = [(i, short(h)) for i, h in enumerate(hdr) if i >= 3 and (colre is None or colre.search(h))]
trig = next((k for k, r in enumerate(data) if r[2] == '1'), None)
print(f"# {len(data)} samples, {len(cols)} columns, trigger at sample {trig}")
lo = max(0, (trig or 0) - around); hi = min(len(data), (trig or 0) + around)
prev = None
for k in range(lo, hi):
    r = data[k]
    cur = {name: r[i] for i, name in cols}
    if prev is None:
        print(f"{k:6d} {'TRIG' if k == trig else '    '} INIT " + ' '.join(f"{n}={v}" for n, v in cur.items()))
    else:
        ch = [f"{n}={cur[n]}" for n in cur if cur[n] != prev[n]]
        if ch or k == trig:
            print(f"{k:6d} {'TRIG' if k == trig else '    '} " + ' '.join(ch))
    prev = cur
last = data[-1]
print("# final state: " + ' '.join(f"{n}={last[i]}" for i, n in cols))
