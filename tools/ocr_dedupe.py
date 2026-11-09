#!/usr/bin/env python3
"""Duplicates in a list of websites read by OCR (Macro Recorder v19).
  python3 ocr_dedupe.py file.txt [file2.txt ...]    one entry per line (OCR lines are fine: the first URL/domain in a line counts)
Prints each normalised address with the lines it came from; exit 1 when there are duplicates."""
import re, sys, collections

def norm(s):
    s = s.strip().lower()
    m = re.search(r'((?:https?://)?(?:www\.)?[a-z0-9][a-z0-9.-]*\.[a-z]{2,}(?:/[^\s]*)?)', s)
    if not m: return None
    s = re.sub(r'^https?://', '', m.group(1)); s = re.sub(r'^www\.', '', s)
    return s.rstrip('/')

# a line starting "---" begins a new read; the same address seen again within one read counts as a duplicate, across reads
# (the page scrolled and shown twice) it does not. Only lines with a scheme (http) or a .pages.dev name are addresses.
seen = collections.OrderedDict()
for f in sys.argv[1:]:
    rd = 0
    for n, line in enumerate(open(f, encoding='utf-8'), 1):
        if line.startswith('---'): rd += 1; continue
        t = line.split('\t')[-1]
        if not re.search(r'https?://|\.pages\.dev', t, re.I) or 'example.com' in t or 'B00AQL8VU4' in t: continue
        k = norm(t)
        if k: seen.setdefault(k, []).append((rd, f"{f}:{n}: {t.strip()}"))
dups = {k: [x for _, x in v] for k, v in seen.items() if any(sum(1 for r, _ in v if r == q) > 1 for q in {r for r, _ in v})}
print(f"{len(seen)} distinct, {len(dups)} duplicated")
for k, v in dups.items():
    print(k); [print("   ", x) for x in v]
sys.exit(1 if dups else 0)
