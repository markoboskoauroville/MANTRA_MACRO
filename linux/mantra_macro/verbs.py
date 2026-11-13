"""verbs.py: the inbox verbs of the Mac app that are not script lines, translated to Linux (X11): captures, windows, OCR,
find/click/wait-text, the lock bookkeeping. Same words as `macro` on the Mac (tools/macro): `<verb>: a | b | c`.

Not ported (the VM has no Accessibility API in reach, no second display): ax-read/ax-press/ax-focus-end, capture-page,
recalibrate/view, layouts, triggers, login-dialog. `ax-quit` = close the window by title. See linux/README in TAKEOVER.
Tools: ImageMagick `import`, wmctrl, xdotool, tesseract. Nothing else.
"""
import json
import os
import re
import subprocess
import time

CAPTURES = os.path.expanduser('~/.mantra_macro/captures')
LOCKFILE = os.path.expanduser('~/.mantra_macro/lock.json')


class VerbError(Exception):
    pass


def _env():
    return dict(os.environ, DISPLAY=os.environ.get('DISPLAY', ':1'))


def _run(*cmd, timeout=30):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=_env())
    if r.returncode != 0:
        raise VerbError('%s failed: %s' % (cmd[0], (r.stderr or r.stdout).strip()[:200]))
    return r.stdout


def parts(arg, n):
    p = [x.strip() for x in arg.split('|')]
    return (p + [''] * n)[:n]


def screen_size():
    w, h = _run('xdotool', 'getdisplaygeometry').split()
    return int(w), int(h)


def windows():
    """[{id, x, y, w, h, title}] from wmctrl -lG."""
    out = []
    for ln in _run('wmctrl', '-lG').splitlines():
        p = ln.split(None, 7)
        if len(p) >= 8:
            out.append({'id': p[0], 'x': int(p[2]), 'y': int(p[3]), 'w': int(p[4]), 'h': int(p[5]), 'title': p[7]})
    return out


def find_window(title):
    t = title.lower()
    c = [w for w in windows() if t in w['title'].lower()]
    if not c:
        raise VerbError('no window "%s"' % title)
    return max(c, key=lambda w: w['w'] * w['h'])


def _out(file):
    if file:
        return os.path.expanduser(file)
    os.makedirs(CAPTURES, exist_ok=True)
    return os.path.join(CAPTURES, time.strftime('%Y%m%d_%H%M%S') + '.png')


# ------------------------------------------------------------------------------------------------ captures
def capture_screen(arg):
    _display, file = parts(arg, 2)          # one screen on the VM: the display part is accepted and ignored
    f = _out(file)
    _run('import', '-silent', '-window', 'root', f)
    return f


def capture_rect(arg):
    rect, file = parts(arg, 2)
    x, y, w, h = [int(v) for v in rect.split(',')]
    f = _out(file)
    _run('import', '-silent', '-window', 'root', '-crop', '%dx%d+%d+%d' % (w, h, x, y), '+repage', f)
    return f


def capture_window(arg):
    title, file = parts(arg, 2)
    w = find_window(title)
    f = _out(file)
    _run('import', '-silent', '-window', w['id'], f)
    return f


# ------------------------------------------------------------------------------------------------ windows
def snap_rect(action, sw, sh):
    """The rectangle Rectangle's action gives on one screen of sw x sh (x, y, w, h)."""
    a = action.lower()
    t3, t2 = sw // 3, sw // 2
    table = {
        'left-half': (0, 0, t2, sh), 'right-half': (sw - t2, 0, t2, sh),
        'top-half': (0, 0, sw, sh // 2), 'bottom-half': (0, sh - sh // 2, sw, sh // 2),
        'maximize': (0, 0, sw, sh), 'almost-maximize': (int(sw * .05), int(sh * .05), int(sw * .9), int(sh * .9)),
        'center': (sw // 4, sh // 4, sw // 2, sh // 2),
        'first-third': (0, 0, t3, sh), 'center-third': (t3, 0, t3, sh), 'last-third': (sw - t3, 0, t3, sh),
        'first-two-thirds': (0, 0, 2 * t3, sh), 'last-two-thirds': (sw - 2 * t3, 0, 2 * t3, sh),
        'top-left': (0, 0, t2, sh // 2), 'top-right': (sw - t2, 0, t2, sh // 2),
        'bottom-left': (0, sh - sh // 2, t2, sh // 2), 'bottom-right': (sw - t2, sh - sh // 2, t2, sh // 2),
    }
    if a in ('next-display', 'previous-display'):
        raise VerbError('this machine has one display')
    if a not in table:
        raise VerbError('unknown snap action "%s"' % action)
    return table[a]


def _geom(w, x, y, ww, hh):
    _run('wmctrl', '-i', '-r', w['id'], '-b', 'remove,maximized_vert,maximized_horz,fullscreen')
    _run('wmctrl', '-i', '-r', w['id'], '-e', '0,%d,%d,%d,%d' % (x, y, ww, hh))


def win_list(_arg):
    return '\n'.join('%s | %d,%d,%d,%d' % (w['title'], w['x'], w['y'], w['w'], w['h']) for w in windows())


def win_move(arg):
    x, y, ww, hh, title = parts(arg, 5)
    w = find_window(title)
    v = lambda s, cur: int(s) if s != '' else cur  # noqa: E731
    _geom(w, v(x, w['x']), v(y, w['y']), v(ww, w['w']), v(hh, w['h']))
    return 'moved'


def win_snap(arg):
    title, action, _display = parts(arg, 3)
    w = find_window(title)
    sw, sh = screen_size()
    _geom(w, *snap_rect(action, sw, sh))
    return 'snapped'


def win_simple(verb, arg):
    w = find_window(arg.strip())
    if verb == 'win-minimize':
        _run('xdotool', 'windowminimize', str(int(w['id'], 16)))
    elif verb == 'win-maximize':
        _run('wmctrl', '-i', '-r', w['id'], '-b', 'add,maximized_vert,maximized_horz')
    elif verb == 'win-restore':
        _run('wmctrl', '-i', '-r', w['id'], '-b', 'remove,maximized_vert,maximized_horz,hidden')
        _run('wmctrl', '-i', '-a', w['id'])
    elif verb == 'win-top':
        _run('wmctrl', '-i', '-a', w['id'])
    elif verb == 'win-bottom':
        _run('xdotool', 'windowlower', str(int(w['id'], 16)))
    elif verb == 'ax-quit':
        _run('wmctrl', '-i', '-c', w['id'])
    return 'ok'


# ------------------------------------------------------------------------------------------------ OCR
def parse_tsv(tsv, ox=0, oy=0):
    """tesseract tsv -> [{text, x, y}] lines (middle of the line box, screen coordinates), words joined by blocks/lines."""
    lines = {}
    for ln in tsv.splitlines()[1:]:
        c = ln.split('\t')
        if len(c) < 12 or not c[11].strip() or float(c[10]) < 0:
            continue
        key = (c[2], c[3], c[4])
        l, t, w, h = int(c[6]), int(c[7]), int(c[8]), int(c[9])
        d = lines.setdefault(key, {'words': [], 'x0': l, 'y0': t, 'x1': l + w, 'y1': t + h})
        d['words'].append(c[11].strip())
        d['x0'], d['y0'] = min(d['x0'], l), min(d['y0'], t)
        d['x1'], d['y1'] = max(d['x1'], l + w), max(d['y1'], t + h)
    return [{'text': ' '.join(d['words']), 'x': ox + (d['x0'] + d['x1']) // 2, 'y': oy + (d['y0'] + d['y1']) // 2}
            for d in lines.values()]


def _area_file(area):
    """capture the area ('screen', 'window:<t>', 'rect:x,y,w,h' or 'x,y,w,h'), return (file, ox, oy)."""
    area = (area or 'screen').strip()
    os.makedirs(CAPTURES, exist_ok=True)
    f = os.path.join(CAPTURES, 'ocr_%d.png' % os.getpid())
    if area.startswith('window:'):
        w = find_window(area[7:])
        _run('import', '-silent', '-window', w['id'], f)
        return f, w['x'], w['y']
    if area.startswith('rect:'):
        area = area[5:]
    if re.match(r'^\d+,\d+,\d+,\d+$', area):
        x, y, w, h = [int(v) for v in area.split(',')]
        _run('import', '-silent', '-window', 'root', '-crop', '%dx%d+%d+%d' % (w, h, x, y), '+repage', f)
        return f, x, y
    _run('import', '-silent', '-window', 'root', f)
    return f, 0, 0


def ocr_lines(area):
    f, ox, oy = _area_file(area)
    try:
        return parse_tsv(_run('tesseract', f, 'stdout', '--psm', '11', 'tsv', timeout=60), ox, oy)
    finally:
        try:
            os.remove(f)
        except OSError:
            pass


def ocr(arg):
    area, fmt = parts(arg, 2)
    ls = ocr_lines(area)
    if fmt == 'json':
        return json.dumps(ls)
    return '\n'.join(l['text'] for l in ls)


def _match(ls, text):
    t = text.lower()
    return [l for l in ls if t in l['text'].lower()]


def find_text(arg):
    text, area = parts(arg, 2)
    m = _match(ocr_lines(area), text)
    if not m:
        raise VerbError('"%s" not found' % text)
    return '%d,%d' % (m[0]['x'], m[0]['y'])


def click_text(arg):
    xy = find_text(arg)
    x, y = xy.split(',')
    _run('xdotool', 'mousemove', x, y, 'click', '1')
    return 'clicked at ' + xy


def wait_text(arg):
    text, secs, area = parts(arg, 3)
    end = time.time() + float(secs or 10)
    while time.time() < end:
        m = _match(ocr_lines(area), text)
        if m:
            return '%d,%d' % (m[0]['x'], m[0]['y'])
        time.sleep(0.5)
    raise VerbError('"%s" did not appear in %s s' % (text, secs or 10))


# ------------------------------------------------------------------------------------------------ the lock
# Bookkeeping only: the Mac app swallows Marko's mouse and keys (event tap); X11 has no safe equivalent that does not also
# swallow Claude's own xdotool events, and nobody sits at the VM's screen in the middle of a run. State is kept and reported.
def lock(arg):
    secs, text = parts(arg, 2)
    json.dump({'text': text, 'seconds': secs, 'since': time.time()}, open(LOCKFILE, 'w'))
    return 'locked (bookkeeping only on Linux)'


def unlock(_arg):
    try:
        os.remove(LOCKFILE)
    except OSError:
        pass
    return 'unlocked'


def lock_status(_arg):
    return 'locked' if os.path.exists(LOCKFILE) else 'unlocked'


HANDLERS = {
    'capture-screen': capture_screen, 'capture-rect': capture_rect, 'capture-window': capture_window,
    'win-list': win_list, 'win-move': win_move, 'win-snap': win_snap,
    'ocr': ocr, 'find-text': find_text, 'click-text': click_text, 'wait-text': wait_text,
    'lock': lock, 'unlock': unlock, 'lock-status': lock_status, 'request': lambda a: 'requested (no lock on Linux): ' + a,
}
for _v in ('win-minimize', 'win-maximize', 'win-restore', 'win-top', 'win-bottom', 'ax-quit'):
    HANDLERS[_v] = (lambda a, v=_v: win_simple(v, a))


def is_verb(head):
    m = re.match(r'^([a-z][a-z-]*):', head.strip())
    return bool(m and m.group(1) in HANDLERS)


def dispatch(head):
    """head = the inbox text. Returns (handled, result dict) ; handled False when it is not a verb."""
    m = re.match(r'^([a-z][a-z-]*):\s?(.*)$', head.strip(), re.S)
    if not m or m.group(1) not in HANDLERS:
        return False, None
    try:
        return True, {'ok': True, 'message': HANDLERS[m.group(1)](m.group(2)), 'line': 0}
    except VerbError as e:
        return True, {'ok': False, 'message': str(e), 'line': 0}
    except Exception as e:  # noqa: BLE001
        return True, {'ok': False, 'message': '%s: %s' % (type(e).__name__, e), 'line': 0}
