#!/usr/bin/env python3
"""test_lease.py: the v34 input guard on the installed app, with simulated holders (25.11.2026).

Every hold here is a few seconds long, shows the bar, and the failsafes (watchdog, Escape, ⌃⌥⌘Esc, release-all) are in the
build under test. No synthetic clicks: TAKE OVER and GIVE THE MAC BACK are pressed through Accessibility (the app's own
hook). Synthetic KEYS (as his hands would type) are posted only into a new TextEdit document, and only while the lock is on.

  python3 tests/test_lease.py [bar|holder|idle|ping|queue|takeover|replay|release|all]

bar       the bar is on screen on every display while held (CGWindowList, screenshots in the scratch folder)
holder    a fake holder killed with kill -9: the lock lifts within a second (ended holder-gone)
idle      a holder that does nothing: the lock lifts after the lease's idle time (ended idle)
ping      a holder that pings keeps it; when it stops, it lifts
queue     two more holders queue first come first served behind the first
takeover  `guard run -- sleep 20` aborted with exit 130 by TAKE OVER (AX press); GIVE THE MAC BACK frees it
replay    keys typed during the lock go back into his app (TextEdit); ⌘⇥ is not replayed; keys after it go to the clipboard
release   `guard release-all` frees a held lock at once
"""
import json, os, subprocess, sys, tempfile, time, urllib.request

URL = 'http://127.0.0.1:8829'
OUT = os.environ.get('LEASE_OUT') or tempfile.mkdtemp(prefix='leasetest-')
os.makedirs(OUT, exist_ok=True)
GUARD = os.path.expanduser('~/Developer/MANTRA_MACRO/tools/guard.py')
results = []


def call(method, path, body=None, timeout=4):
    req = urllib.request.Request(URL + path, data=json.dumps(body).encode() if body is not None else None, method=method,
                                 headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read() or b'{}')


def st():
    return call('GET', '/status')


def check(ok, name, detail=''):
    results.append((bool(ok), name, detail))
    print(('PASS ' if ok else 'FAIL ') + name + (('  [' + detail + ']') if detail else ''), flush=True)


def holder(seconds=30):
    return subprocess.Popen(['sleep', str(seconds)])


def lock(owner, pid, what, idle=1.5, seconds=20, place=None):
    b = {'text': 'TEST (Claude, a few seconds): ' + what, 'owner': owner, 'pid': pid, 'seconds': seconds, 'idle': idle}
    if place:
        b['place'] = place
    return call('POST', '/lock', b)


def wait_off(limit):
    t0 = time.time()
    while time.time() - t0 < limit:
        s = st()
        if s.get('lock') != 'on' and not s.get('giving_back'):
            return time.time() - t0, s
        time.sleep(0.05)
    return None, st()


def safe():
    """Never leave a lock behind."""
    try:
        s = st()
        if s.get('lock') in ('on', 'overridden', 'requested'):
            call('POST', '/release-all', {'why': 'test cleanup'})
            time.sleep(0.5)
    except Exception:
        pass


def onscreen_bars():
    import Quartz
    out = []
    for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID):
        if w.get('kCGWindowName') == 'Macro Recorder input lock bar':
            out.append((bool(w.get('kCGWindowIsOnscreen')), dict(w['kCGWindowBounds']), w.get('kCGWindowLayer')))
    return out


def ax_press(ident):
    """Press the bar's TAKE OVER (ident takeover) or the blob (giveback) through Accessibility."""
    from ApplicationServices import (AXUIElementCreateApplication, AXUIElementCopyAttributeValue, AXUIElementPerformAction)
    pid = int(subprocess.run(['pgrep', '-x', 'MacroRecorder'], capture_output=True, text=True).stdout.split()[0])
    app = AXUIElementCreateApplication(pid)

    def walk(e, depth=0):
        if depth > 6:
            return None
        err, i = AXUIElementCopyAttributeValue(e, 'AXIdentifier', None)
        if i == ident:
            return e
        err, kids = AXUIElementCopyAttributeValue(e, 'AXChildren', None)
        for k in kids or []:
            f = walk(k, depth + 1)
            if f is not None:
                return f
        return None
    err, wins = AXUIElementCopyAttributeValue(app, 'AXWindows', None)
    for w in wins or []:
        f = walk(w)
        if f is not None:
            return AXUIElementPerformAction(f, 'AXPress') == 0
    return False


def t_bar():
    h = holder()
    r = lock('lease-bar', h.pid, 'bar check', idle=3)
    check(r.get('ok'), 'bar: lock taken', json.dumps(r)[:120])
    time.sleep(0.7)
    s = st()
    bars = onscreen_bars()
    screens = s.get('bar', {}).get('screens')
    f = [os.path.join(OUT, 'bar_d%d.png' % i) for i in range(1, (screens or 1) + 1)]
    subprocess.run(['screencapture', '-x'] + f)
    check(len(bars) == screens and all(b[0] for b in bars), 'bar: on screen on every display',
          'screens %s, bars %s, status %s' % (screens, bars, s.get('bar')))
    check(all(b[2] >= 1000 for b in bars), 'bar: above everything (screen-saver level)', str([b[2] for b in bars]))
    lease = s.get('lease') or {}
    check(lease.get('idle_s') == 3 and lease.get('max_left', 0) > 0, 'bar: lease in status', json.dumps(lease))
    h.kill()
    wait_off(3)
    print('     screenshots: ' + ' '.join(f))


def t_holder():
    h = holder()
    r = lock('lease-holder', h.pid, 'holder killed', idle=10)
    check(r.get('ok'), 'holder: lock taken')
    time.sleep(0.5)
    t0 = time.time()
    os.kill(h.pid, 9)
    h.wait()
    dt, s = wait_off(3)
    check(dt is not None and dt < 1.0 and s.get('ended') == 'holder-gone', 'holder: kill -9 lifts it within 1 s',
          'after %.2f s, ended %s' % (time.time() - t0, s.get('ended')))


def t_idle():
    h = holder()
    r = lock('lease-idle', h.pid, 'idle drop', idle=1.5)
    check(r.get('ok'), 'idle: lock taken')
    dt, s = wait_off(4)
    check(dt is not None and 1.4 <= dt <= 2.2 and s.get('ended') == 'idle', 'idle: lifts by itself after 1.5 s idle',
          'after %s s, ended %s' % (dt and round(dt, 2), s.get('ended')))
    h.kill()


def t_ping():
    h = holder()
    r = lock('lease-ping', h.pid, 'ping keeps it', idle=1.5)
    check(r.get('ok'), 'ping: lock taken')
    held = True
    for _ in range(6):
        time.sleep(0.5)
        call('POST', '/ping', {'owner': 'lease-ping'})
        held = held and st().get('lock') == 'on'
    check(held, 'ping: still held after 3 s of pings (idle 1.5 s)')
    dt, s = wait_off(4)
    check(dt is not None and dt <= 2.2 and s.get('ended') == 'idle', 'ping: lifts 1.5 s after the last ping',
          'after %s s, ended %s' % (dt and round(dt, 2), s.get('ended')))
    h.kill()


def t_queue():
    ha, hb, hc = holder(), holder(), holder()
    a = lock('lease-qA', ha.pid, 'queue A', idle=3)
    b = lock('lease-qB', hb.pid, 'queue B', idle=3)
    c = lock('lease-qC', hc.pid, 'queue C', idle=3)
    check(a.get('ok') and b.get('busy') and b.get('queued') == 1 and c.get('queued') == 2, 'queue: B first, C second',
          'B %s, C %s' % (b.get('queued'), c.get('queued')))
    c2 = lock('lease-qC', hc.pid, 'queue C', idle=3)
    check(not c2.get('ok') and c2.get('queued') == 2, 'queue: C cannot jump B')
    call('POST', '/unlock', {'owner': 'lease-qA'})
    got = None
    t0 = time.time()
    while time.time() - t0 < 4 and not got:
        rc = lock('lease-qC', hc.pid, 'queue C', idle=3)       # C asks first ...
        rb = lock('lease-qB', hb.pid, 'queue B', idle=3)       # ... but B is first in the queue
        if rc.get('ok'):
            got = 'C'
        elif rb.get('ok'):
            got = 'B'
        time.sleep(0.2)
    check(got == 'B', 'queue: after A, B gets it (first come first served)', 'got %s' % got)
    call('POST', '/unlock', {'owner': 'lease-qB'})
    got = None
    t0 = time.time()
    while time.time() - t0 < 4 and not got:
        if lock('lease-qC', hc.pid, 'queue C', idle=3).get('ok'):
            got = 'C'
        time.sleep(0.2)
    check(got == 'C', 'queue: then C')
    call('POST', '/unlock', {'owner': 'lease-qC'})
    for h in (ha, hb, hc):
        h.kill()
    wait_off(3)


def t_takeover():
    p = subprocess.Popen([sys.executable, GUARD, 'run', '--what', 'TEST: TAKE OVER aborts this sleep', '--', 'sleep', '20'],
                         stderr=subprocess.PIPE, text=True, env=dict(os.environ, GUARD_OWNER='lease-takeover', GUARD_IDLE_MAX='2'))
    t0 = time.time()
    while time.time() - t0 < 8 and st().get('owner') != 'lease-takeover':
        time.sleep(0.1)
    time.sleep(0.5)
    pressed = ax_press('takeover')
    check(pressed, 'takeover: TAKE OVER pressed through Accessibility')
    try:
        rc = p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        p.kill(); rc = None
    err = p.stderr.read()
    check(rc == 130 and 'ABORTED' in err, 'takeover: guard run exits 130 (ABORTED)', 'rc %s, %s' % (rc, err.strip()[-120:]))
    s = st()
    check(s.get('lock') == 'overridden', 'takeover: the Mac is his (overridden)', s.get('lock'))
    r = call('POST', '/lock', {'text': 'x', 'owner': 'lease-after', 'pid': os.getpid(), 'idle': 1})
    check(r.get('overridden'), 'takeover: a new holder is refused while he has it')
    gb = ax_press('giveback')
    time.sleep(0.4)
    check(gb and st().get('lock') == 'off', 'takeover: GIVE THE MAC BACK frees it', st().get('lock'))


def osa(s):
    try:
        return subprocess.run(['osascript', '-e', s], capture_output=True, text=True, timeout=5).stdout.strip()
    except subprocess.TimeoutExpired:
        return '(osascript timed out)'


def t_replay():
    import Quartz
    saved = subprocess.run(['pbpaste'], capture_output=True).stdout
    osa('tell application "TextEdit" to make new document')
    osa('tell application "TextEdit" to activate')
    time.sleep(1.0)
    front = osa('tell application "System Events" to get name of first process whose frontmost is true')
    check(front == 'TextEdit', 'replay: his app (a new TextEdit document) in front', front)
    h = holder()
    r = lock('lease-replay', h.pid, 'keys typed now go back to TextEdit', idle=4, place='front')
    check(r.get('ok') and r.get('his_app') == 'TextEdit', 'replay: lock taken, his app TextEdit', json.dumps(r)[:140])
    osa('tell application "Finder" to activate')     # the automation brings another app front
    time.sleep(0.4)

    def key(code, ch='', flags=0):
        if st().get('lock') != 'on':
            return False                              # never type when the lock is not on
        for down in (True, False):
            e = Quartz.CGEventCreateKeyboardEvent(None, code, down)
            if ch:
                Quartz.CGEventKeyboardSetUnicodeString(e, len(ch), ch)
            if flags:
                Quartz.CGEventSetFlags(e, flags)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, e)
            time.sleep(0.02)
        return True
    ok = all(key(c, ch) for c, ch in ((0, 'a'), (11, 'b'), (8, 'c')))
    ok = ok and key(48, '', Quartz.kCGEventFlagMaskCommand)      # ⌘⇥ (swallowed: the lock is on)
    ok = ok and all(key(c, ch) for c, ch in ((7, 'x'), (16, 'y'), (6, 'z')))
    check(ok, 'replay: 7 keys posted while the lock was on')
    call('POST', '/ping', {'owner': 'lease-replay'})
    call('POST', '/unlock', {'owner': 'lease-replay'})
    wait_off(4)
    time.sleep(1.2)
    last = call('GET', '/last')
    text = osa('tell application "TextEdit" to get text of front document')
    clip = subprocess.run(['pbpaste'], capture_output=True, text=True).stdout
    check(text.lower() == 'abc', 'replay: TextEdit got exactly "abc" (TextEdit capitalises the first letter)', repr(text))
    check(last.get('front_app') == 'TextEdit' and last.get('replayed') == 3, 'replay: log says 3 keys into TextEdit', last.get('notice', ''))
    check(any('⌘⇥' in x for x in last.get('not_replayed', [])) and 'x' not in text, 'replay: ⌘⇥ not replayed',
          str(last.get('not_replayed')))
    check(clip == 'xyz', 'replay: the keys after ⌘⇥ are on the clipboard', repr(clip))
    check(last.get('his_app_back') is True, 'replay: his app verified in front after the give-back')
    osa('tell application "TextEdit" to close front document saving no')
    subprocess.run(['pbcopy'], input=saved)
    h.kill()


def t_chord():
    import Quartz
    h = holder()
    lock('lease-chord', h.pid, 'Ctrl-Opt-Cmd-Esc releases everything', idle=10)
    time.sleep(0.3)
    if st().get('lock') == 'on':                      # only while held: then the tap swallows it
        for down in (True, False):
            e = Quartz.CGEventCreateKeyboardEvent(None, 53, down)
            Quartz.CGEventSetFlags(e, Quartz.kCGEventFlagMaskControl | Quartz.kCGEventFlagMaskAlternate | Quartz.kCGEventFlagMaskCommand)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, e)
    dt, s = wait_off(2)
    check(dt is not None and dt < 1 and s.get('ended') == 'chord', 'chord: ⌃⌥⌘Esc frees it at once', 'ended %s' % s.get('ended'))
    h.kill()


def t_release():
    h = holder()
    lock('lease-release', h.pid, 'release-all', idle=10)
    t0 = time.time()
    out = subprocess.run([sys.executable, GUARD, 'release-all', 'test'], capture_output=True, text=True).stdout.strip()
    dt, s = wait_off(2)
    check(dt is not None and time.time() - t0 < 1.5, 'release: release-all frees it at once', '%s; ended %s' % (out, s.get('ended')))
    h.kill()


TESTS = {'chord': t_chord, 'bar': t_bar, 'holder': t_holder, 'idle': t_idle, 'ping': t_ping, 'queue': t_queue, 'release': t_release,
         'takeover': t_takeover, 'replay': t_replay}

if __name__ == '__main__':
    which = sys.argv[1:] or ['all']
    if which == ['all']:
        which = list(TESTS)
    s0 = st()
    if s0.get('version', 0) < 34:
        print('the installed Macro Recorder is v%s: these tests need v34' % s0.get('version'))
        sys.exit(2)
    for n in which:
        print('--', n, flush=True)
        try:
            TESTS[n]()
        except Exception as e:
            check(False, n + ': exception', repr(e))
        finally:
            safe()
        time.sleep(0.8)
    bad = [r for r in results if not r[0]]
    print('%d passed, %d failed; files in %s' % (len(results) - len(bad), len(bad), OUT))
    sys.exit(1 if bad else 0)
