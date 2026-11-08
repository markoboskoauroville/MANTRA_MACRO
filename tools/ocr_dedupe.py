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

seen = collections.OrderedDict()
for f in sys.argv[1:]:
    for n, line in enumerate(open(f, encoding='utf-8'), 1):
        k = norm(line.split('\t')[-1])
        if k: seen.setdefault(k, []).append(f"{f}:{n}: {line.strip()}")
dups = {k: v for k, v in seen.items() if len(v) > 1}
print(f"{len(seen)} distinct, {len(dups)} duplicated")
for k, v in dups.items():
    print(k); [print("   ", x) for x in v]
sys.exit(1 if dups else 0)
