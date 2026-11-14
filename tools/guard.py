#!/usr/bin/env python3
"""guard: the ONE input guard between Marko and every automation on this Mac (v27, 14.11.2026).

Marko, 14.11.2026: "this guard should be available for any action happening by Claude or any of my star apps so when
it's running, I'm not writing in the other parts of my computer when I don't want to write. When you finish, I want to
have it back. Same prompt where I was. And even if I touch something during the block, you should catch it and write
it down when the block is lifted."

The guard itself is Macro Recorder (Mantra)'s input lock, 127.0.0.1:8829 (MANTRA_MACRO app/Lock.swift + Guard.swift):
while held, his physical keys and clicks are swallowed (bar at the bottom: CLAUDE · time · what · TAKE OVER), his keys
are kept; when it lifts his app, window, text field and caret come back and his keys are replayed there, in order;
clicks are written down (~/.mantra_macro/guard_log.jsonl, `guard last`). One holder at a time: others wait their turn.

    guard run [--what "<what>"] [--seconds N] [--no-restore] -- <command> [args]   hold it for one command
    guard begin "<what>" [--seconds N] [--no-restore]    hold it across several commands (same Claude session = same owner)
    guard end [--linger MS]                              give it back (MS: keep it a moment for a next step, default 0)
    guard status | last | log [N] | wait-idle [S]        read only
Before taking it, the guard waits until Marko has not touched keyboard or mouse for 1.5 s (at most 6 s, then it takes it
anyway: his keys are buffered). TAKE OVER (or Escape held 1 s) aborts `guard run`'s command at once (exit 130).
Env: GUARD_OWNER (who holds it; default the Claude Code process above), GUARD=0 runs the command unguarded.

Python:  sys.path.insert(0, os.path.expanduser('~/Developer/MANTRA_MACRO/tools')); import guard
         with guard.held("WhatsApp draft"):  ...      # raises guard.Overridden / KeyboardInterrupt on TAKE OVER
"""
import json, os, signal, subprocess, sys, threading, time, urllib.request

URL = os.environ.get('GUARD_URL', 'http://127.0.0.1:8829')
IDLE_S = float(os.environ.get('GUARD_IDLE', '1.5'))
IDLE_MAX_S = float(os.environ.get('GUARD_IDLE_MAX', '6'))
QUEUE_MAX_S = float(os.environ.get('GUARD_QUEUE_MAX', '180'))


class Overridden(Exception):
    """Marko pressed TAKE OVER: stop touching the Mac."""


class Unavailable(Exception):
    """Macro Recorder is not running / has no Accessibility: NOTHING is guarded."""


def _call(method, path, body=None, timeout=3):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(URL + path, data=data, method=method, headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read() or b'{}')


def status():
    try:
        return _call('GET', '/status')
    except Exception as e:
        return {'lock': 'unreachable', 'error': str(e)}


def _ancestor():
    """(owner, pid) of the long-lived process that holds the guard: the Claude Code process above us, else our parent."""
    pid = os.getpid()
    seen = 0
    while pid > 1 and seen < 12:
        seen += 1
        try:
            out = subprocess.run(['ps', '-o', 'ppid=,comm=', '-p', str(pid)], capture_output=True, text=True, timeout=2).stdout.strip()
        except Exception:
            break
        if not out:
            break
        ppid, comm = out.split(None, 1)
        name = os.path.basename(comm)
        if pid != os.getpid() and name in ('claude', 'node') and 'claude' in comm:
            return f'claude-{pid}', pid
        pid = int(ppid)
    return f'pid-{os.getppid()}', os.getppid()


def owner():
    o = os.environ.get('GUARD_OWNER')
    if o:
        return o, int(os.environ.get('GUARD_PID', '0') or 0)
    return _ancestor()


def idle_seconds():
    try:
        out = subprocess.run(['ioreg', '-c', 'IOHIDSystem'], capture_output=True, text=True, timeout=2).stdout
        for line in out.splitlines():
            if 'HIDIdleTime' in line:
                return int(line.rsplit('=', 1)[1].strip()) / 1e9
    except Exception:
        pass
    return 99.0


def wait_idle(need=IDLE_S, most=IDLE_MAX_S):
    """Real input must not start while he is typing: wait until he has been still `need` s, at most `most` s."""
    end = time.time() + most
    while True:
        i = idle_seconds()
        if i >= need:
            return i
        if time.time() >= end:
            return i
        time.sleep(max(0.1, min(0.4, need - i)))


def begin(what, seconds=120, restore=True, own=None, quiet=False):
    """Take the guard (waits for his idle moment and for any other holder). Returns the server's answer."""
    o, pid = own or owner()
    st = status()
    if st.get('lock') == 'unreachable':
        raise Unavailable('Macro Recorder (Mantra) is not running on 127.0.0.1:8829: nothing is guarded')
    if not (st.get('lock') == 'on' and st.get('owner') == o):
        wait_idle()
    end = time.time() + QUEUE_MAX_S
    said = False
    while True:
        r = _call('POST', '/lock', {'text': what, 'seconds': int(seconds), 'owner': o, 'pid': pid, 'restore': bool(restore)})
        if r.get('ok'):
            return r
        if r.get('overridden'):
            raise Overridden(r.get('error'))      # the Mac is his until he gives it back: never wait him out
        if not r.get('busy') and not r.get('overridden'):
            raise Unavailable(r.get('error') or json.dumps(r))
        if not said and not quiet:
            print('guard: waiting, ' + (r.get('error') or 'busy'), file=sys.stderr)
            said = True
        if time.time() > end:
            raise Unavailable('guard: still busy after %d s: %s' % (QUEUE_MAX_S, r.get('error')))
        time.sleep(0.3)
        if not (status().get('lock') == 'on' and status().get('owner') == o):
            wait_idle(IDLE_S, 2)


def end(linger_ms=0, own=None):
    o, _ = own or owner()
    try:
        return _call('POST', '/unlock', {'owner': o, 'linger_ms': int(linger_ms)})
    except Exception as e:
        return {'ok': False, 'error': str(e)}


def last():
    try:
        return _call('GET', '/last')
    except Exception as e:
        return {'ok': False, 'error': str(e)}


class _Watch(threading.Thread):
    """Polls the lock; when Marko takes over (or the lock is gone), calls on_override once."""

    def __init__(self, o, on_override):
        super().__init__(daemon=True)
        self.o, self.on_override, self.stop = o, on_override, threading.Event()
        self.fired = False

    def run(self):
        while not self.stop.wait(0.25):
            st = status()
            if st.get('lock') == 'overridden' or (st.get('lock') == 'off' and not st.get('giving_back')) or \
                    (st.get('lock') == 'on' and st.get('owner') not in (self.o, None, '')):
                # overridden = TAKE OVER; off = the watchdog lifted it (time up): stop rather than run on unguarded
                self.fired = True
                self.on_override(st)
                return


class held:
    """with guard.held("what"): ... — TAKE OVER raises KeyboardInterrupt in the main thread (or calls on_override)."""

    def __init__(self, what, seconds=120, restore=True, linger_ms=0, on_override=None):
        self.what, self.seconds, self.restore, self.linger = what, seconds, restore, linger_ms
        self.on_override = on_override
        self.own = None
        self.watch = None
        self.skip = os.environ.get('GUARD') == '0'

    def __enter__(self):
        if self.skip:
            return self
        self.own = owner()
        begin(self.what, self.seconds, self.restore, own=self.own)
        cb = self.on_override or (lambda st: os.kill(os.getpid(), signal.SIGINT))
        self.watch = _Watch(self.own[0], cb)
        self.watch.start()
        return self

    @property
    def overridden(self):
        return bool(self.watch and self.watch.fired)

    def __exit__(self, et, ev, tb):
        if self.skip:
            return False
        if self.watch:
            self.watch.stop.set()
        fired = self.overridden
        end(self.linger, own=self.own)
        if fired and et is KeyboardInterrupt:
            raise Overridden('Marko took over (TAKE OVER): the action was stopped')
        return False


def _opt(a, name, default=None, flag=False):
    if name in a:
        i = a.index(name)
        if flag:
            a.pop(i)
            return True
        v = a[i + 1]
        del a[i:i + 2]
        return v
    return False if flag else default


def main(argv):
    a = list(argv)
    if not a or a[0] in ('-h', '--help', 'help'):
        print(__doc__)
        return 0
    cmd = a.pop(0)
    if cmd == 'status':
        print(json.dumps(status(), ensure_ascii=False))
        return 0
    if cmd == 'last':
        print(json.dumps(last(), ensure_ascii=False, indent=1))
        return 0
    if cmd == 'log':
        n = int(a[0]) if a else 10
        p = os.path.expanduser('~/.mantra_macro/guard_log.jsonl')
        lines = open(p).read().splitlines()[-n:] if os.path.exists(p) else []
        for line in lines:
            try:
                j = json.loads(line)
                print(time.strftime('%d.%m %H:%M:%S', time.localtime(j['at'])), '·', j.get('what', ''), '·', j.get('notice', ''))
            except Exception:
                pass
        return 0
    if cmd == 'wait-idle':
        print('idle %.1f s' % wait_idle(float(a[0]) if a else IDLE_S))
        return 0
    if cmd == 'begin':
        secs = int(_opt(a, '--seconds', 120))
        restore = not _opt(a, '--no-restore', flag=True)
        what = ' '.join(a) or 'working'
        if os.environ.get('GUARD') == '0':
            print('guard: skipped (GUARD=0)')
            return 0
        try:
            r = begin(what, secs, restore)
        except (Unavailable, Overridden) as e:
            print('guard: NOT held: %s' % e)
            return 3
        o, pid = owner()
        print('guard: held by %s (pid %s)%s' % (o, pid, ' nested' if r.get('nested') else ''))
        return 0
    if cmd == 'end':
        r = end(int(_opt(a, '--linger', 0)))
        print('guard: ' + ('given back' if r.get('ok') else 'NOT given back: %s' % r.get('error')))
        return 0 if r.get('ok') else 1
    if cmd == 'run':
        secs = int(_opt(a, '--seconds', 120))
        what = _opt(a, '--what', None)
        restore = not _opt(a, '--no-restore', flag=True)
        linger = int(_opt(a, '--linger', 0))
        if a and a[0] == '--':
            a.pop(0)
        if not a:
            print('guard run [--what X] -- <command>', file=sys.stderr)
            return 2
        what = what or ' '.join(os.path.basename(x) if i == 0 else x for i, x in enumerate(a))[:70]
        if os.environ.get('GUARD') == '0':
            return subprocess.call(a)
        o = ('run-%d' % os.getpid(), os.getpid())
        st = status()
        inherited = os.environ.get('GUARD_OWNER')
        if inherited and st.get('lock') == 'on' and st.get('owner') == inherited:
            o = (inherited, int(os.environ.get('GUARD_PID', '0') or 0))      # nested inside a held guard
        try:
            begin(what, secs, restore, own=o)
        except (Unavailable, Overridden) as e:
            print('guard: NOT held, command not run: %s' % e, file=sys.stderr)
            return 3
        env = dict(os.environ, GUARD_OWNER=o[0], GUARD_PID=str(o[1]))
        p = subprocess.Popen(a, env=env, start_new_session=True)
        stopped = []

        def kill(st):
            stopped.append(st)
            try:
                os.killpg(p.pid, signal.SIGINT)
                time.sleep(0.8)
                if p.poll() is None:
                    os.killpg(p.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        w = _Watch(o[0], kill)
        w.start()
        try:
            rc = p.wait()
        except KeyboardInterrupt:
            os.killpg(p.pid, signal.SIGINT)
            rc = p.wait()
        w.stop.set()
        end(linger, own=o)
        if stopped:
            why = 'Marko took over (TAKE OVER)' if stopped[0].get('lock') == 'overridden' else 'the guard was lifted (%s)' % stopped[0].get('lock')
            print('guard: command stopped: ' + why, file=sys.stderr)
            return 130
        return rc
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
