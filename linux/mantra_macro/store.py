"""store.py: ~/.mantra_macro, the same folder and settings.json as the Mac app (app/Store.swift)."""
import json
import os
import re
import time

DIR = os.path.expanduser('~/.mantra_macro')
MACROS = os.path.join(DIR, 'macros')
INBOX = os.path.join(DIR, 'inbox')
TRASH = os.path.join(DIR, 'trash')
SETTINGS = os.path.join(DIR, 'settings.json')

for d in (DIR, MACROS, INBOX, TRASH):
    os.makedirs(d, exist_ok=True)


def safe_name(name):
    name = re.sub(r'[/\\\x00]', '-', name).strip()
    return name or time.strftime('macro %Y-%m-%d %H.%M.%S')


def path(name):
    return os.path.join(MACROS, safe_name(name) + '.ahk')


def names():
    out = [f[:-4] for f in os.listdir(MACROS) if f.endswith('.ahk')]
    return sorted(out, key=lambda n: -os.path.getmtime(path(n)))


def read(name):
    with open(path(name)) as f:
        return f.read()


def write(name, text):
    p = path(name)
    if os.path.exists(p):
        os.replace(p, os.path.join(TRASH, '%s %s.ahk' % (safe_name(name), time.strftime('%Y-%m-%d %H.%M.%S'))))
    with open(p, 'w') as f:
        f.write(text)
    return p


def delete(name):
    p = path(name)
    if os.path.exists(p):
        os.replace(p, os.path.join(TRASH, '%s %s.ahk' % (safe_name(name), time.strftime('%Y-%m-%d %H.%M.%S'))))


def settings():
    try:
        with open(SETTINGS) as f:
            return json.load(f)
    except Exception:
        return {}


def save_settings(j):
    tmp = SETTINGS + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(j, f, indent=1)
    os.replace(tmp, SETTINGS)


def slots():
    """'1'..'0' -> macro name; only names that exist, no name twice (the first slot keeps it)."""
    raw = settings().get('slots') or {}
    out, seen = {}, set()
    for k in '1234567890':
        n = raw.get(k)
        if isinstance(n, str) and n and n not in seen and os.path.exists(path(n)):
            out[k] = n
            seen.add(n)
    return out


def set_slot(key, name):
    j = settings()
    s = j.get('slots') or {}
    for k in list(s):
        if s[k] == name:
            del s[k]
    if name:
        s[key] = name
    else:
        s.pop(key, None)
    j['slots'] = s
    save_settings(j)
