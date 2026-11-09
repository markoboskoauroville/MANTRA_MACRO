#!/usr/bin/env python3
"""The website list read by partnernet-list (Macro Recorder v19) -> merged list + duplicates.
  python3 ocr_dedupe.py ~/.mantra_macro/partnernet-list.txt
File: "--- read N" starts a read, "--- step" ends one scroll step; lines are OCR lines (the first tab column is ignored).
Per read: the union of the addresses in all steps (a line ending in '-' or '.' joins the next; only whole https://...pages.dev
style lines count, tooltips and half-scrolled rows are dropped by that), normalised (http/https, www, trailing slash, case).
Prints each read's list, whether the reads are IDENTICAL, and CANDIDATE duplicates: an address shown twice in ONE step. A candidate
is only a hint (a hover tooltip repeats a row): confirm by a picture of the box before deleting anything. Exit 1 if candidates."""
import re, sys, collections

def norm(s):
    s = s.strip().lower(); s = re.sub(r'^https?://', '', s); s = re.sub(r'^www\.', '', s); return s.rstrip('/')

def join(lines):
    out, buf = [], ''
    for t in lines:
        t = (buf + t.strip()) if buf else t.strip(); buf = ''
        if t.endswith('-') or t.endswith('.'): buf = t; continue
        out.append(t)
    if buf: out.append(buf)
    return out

reads, steps = [], []
for line in open(sys.argv[1], encoding='utf-8'):
    line = line.rstrip('\n')
    if line.startswith('--- read'): reads.append([]); steps = None; continue
    if line.startswith('--- step'): steps = None; continue
    if not reads: continue
    if steps is None: steps = []; reads[-1].append(steps)
    steps.append(line.split('\t')[-1])
lists, cands = [], collections.Counter()
for r in reads:
    seen = []
    for st in r:
        c = collections.Counter(norm(t) for t in join(st) if re.fullmatch(r'https?://\S+\.[a-z]{2,}/?', t.strip(), re.I) and 'example.com' not in t and 'B00AQL8VU4' not in t)
        for k, n in c.items():
            if k not in seen: seen.append(k)
            if n > 1: cands[k] += 1
    lists.append(seen)
for i, l in enumerate(lists, 1): print(f"read {i}: {len(l)} sites"); [print("  ", x) for x in l]
print("reads IDENTICAL" if all(sorted(l) == sorted(lists[0]) for l in lists) else "reads DIFFER")
if cands: print("candidate duplicates (verify by picture):", dict(cands))
sys.exit(1 if cands else 0)
