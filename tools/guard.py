#!/usr/bin/env python3
"""guard: the ONE input guard between Marko and every automation on this Mac (v27 14.11.2026, LEASE since v34 25.11.2026).

Marko, 14.11.2026: "this guard should be available for any action happening by Claude or any of my star apps so when
it's running, I'm not writing in the other parts of my computer when I don't want to write. When you finish, I want to
have it back." Marko, 25.11.2026: "I see you have finished the task and I still cannot use my computer for a long time.
... you are forgetting to block my inputs while you are working and bringing back when you are not working so we can
share the same computer."

The guard is Macro Recorder (Mantra)'s input lock, 127.0.0.1:8829 (MANTRA_MACRO app/Lock.swift + Guard.swift). While held,
his keys and clicks are swallowed (the bar at the bottom of every screen: CLAUDE · yours in N s · max · what · TAKE OVER),
his keys are kept; when it lifts his app, window, field and caret come back and his keys are replayed there (never ⌘⇥ or
other shortcuts; keys typed after an app switch go to the clipboard); clicks are written down (`guard last`, `guard log`).

HOLD IT PER BURST, NOT WHILE THINKING. The hold is a LEASE: every guarded step renews it; 4 s without one and the Mac is
his again by itself; the next guarded step takes it again (after his 1.5 s still moment, at most 6 s). One lease lasts at
most 60 s, renewed once while busy, never more than 90 s. It also drops at once when the holder's process is gone, on
`guard end`, TAKE OVER, Escape held 1 s, ⌃⌥⌘Esc or `guard release-all`.

    guard run [--what "<what>"] [--seconds N] [--no-restore] -- <command> [args]   one command, held while it runs
    guard begin "<what>" [--seconds N] [--idle S]   a sequence: begin, then each step (macro do, guard run, ...), then end
    guard ping                                      the holder is still working (renews the lease; rarely needed)
    guard end [--linger MS]                         give it back now (MS at most the 4 s idle)
    guard release-all                               FAILSAFE: everything released, even a wedged lock (kills and restarts
                                                    Macro Recorder if it does not answer in 2 s)
    guard status | last | log [N] | wait-idle [S]   read only
Exit codes: 0 held / given back / done; 130 ABORTED (Marko took over: TAKE OVER, Escape, the Mac is his until he gives it
back); 3 no guard (Macro Recorder not running, no Accessibility); 4 still queued behind another holder after 180 s.
Messages on stderr say which: "guard: held", "guard: queued behind X (position N)", "guard: released", "guard: ABORTED".
Env: GUARD_OWNER (who holds it; default the Claude Code process above), GUARD=0 runs the command unguarded.

Python:  sys.path.insert(0, os.path.expanduser('~/Developer/MANTRA_MACRO/tools')); import guard
         with guard.held("WhatsApp draft"):  ...      # renews itself while the block runs; raises guard.Overridden on TAKE OVER
         guard.run(["cliclick", "c:100,200"], "click Save")   # = guard run, returns the exit code (130 = aborted)
Shell wrappers: `guard run -- <cmd>`; tools/guarded <cmd> is the same in one word.
"""
import json, os, signal, subprocess, sys, threading, time, urllib.request

URL = os.environ.get('GUARD_URL', 'http://127.0.0.1:8829')
IDLE_S = float(os.environ.get('GUARD_IDLE', '1.5'))
IDLE_MAX_S = float(os.environ.get('GUARD_IDLE_MAX', '6'))
QUEUE_MAX_S = float(os.environ.get('GUARD_QUEUE_MAX', '180'))
LEASE_IDLE_S = float(os.environ.get('GUARD_LEASE_IDLE', '4'))     # v34: the app drops the lease after this long idle
PING_S = 1.0                                                      # held() / run ping this often while their work runs
APP = 'Macro Recorder (Mantra)'


class Overridden(Exception):
    """Marko pressed TAKE OVER (or held Escape): stop touching the Mac. CLI exit 130."""


class Unavailable(Exception):
    """Macro Recorder is not running / has no Accessibility: NOTHING is guarded."""


def _say(msg, quiet=False):
    if not quiet:
        print('guard: ' + msg, file=sys.stderr, flush=True)


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


def begin(what, seconds=60, restore=True, own=None, quiet=False, idle=None, place=None):
    """Take the guard (waits for his still moment, then for its turn in the queue). Returns the server's answer.
    Raises Overridden (Marko has the Mac), Unavailable (no guard, or still queued after QUEUE_MAX_S: .queued is True)."""
    o, pid = own or owner()
    st = status()
    if st.get('lock') == 'unreachable':
        raise Unavailable('Macro Recorder (Mantra) is not running on 127.0.0.1:8829: nothing is guarded')
    mine = st.get('lock') == 'on' and st.get('owner') == o
    if not mine:
        wait_idle()
    end = time.time() + QUEUE_MAX_S
    said = None
    body = {'text': what, 'seconds': int(seconds), 'owner': o, 'pid': pid, 'restore': bool(restore),
            'idle': float(idle or LEASE_IDLE_S)}
    if place:
        body['place'] = place
    while True:
        r = _call('POST', '/lock', body)
        if r.get('ok'):
            if not r.get('nested'):
                _say('held by %s: %s' % (o, what), quiet)
            if r.get('refront'):
                # its own app comes front again after a pause (Lock.swift refrontHolder): wait until it is there
                t = time.time() + 1.2
                while time.time() < t and status().get('front_now') != r['refront']:
                    time.sleep(0.08)
            return r
        if r.get('overridden'):
            raise Overridden(r.get('error'))      # the Mac is his until he gives it back: never wait him out
        if not r.get('busy'):
            raise Unavailable(r.get('error') or json.dumps(r))
        msg = 'queued behind %s (position %s): %s' % (r.get('held_by', '?'), r.get('queued', '?'), r.get('error', 'busy'))
        if msg != said:
            _say(msg, quiet)
            said = msg
        if r.get('paused') or status().get('paused'):
            end = time.time() + QUEUE_MAX_S       # v29: Macro Recorder is paused: wait for RESUME, however long it takes
        if time.time() > end:
            e = Unavailable('still queued after %d s: %s' % (QUEUE_MAX_S, r.get('error')))
            e.queued = True
            raise e
        time.sleep(0.3)
        if status().get('lock') != 'on':
            wait_idle(IDLE_S, 2)


def ping(own=None):
    o, _ = own or owner()
    try:
        return _call('POST', '/ping', {'owner': o}, timeout=2)
    except Exception as e:
        return {'ok': False, 'error': str(e)}


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


def release_all(why='release-all'):
    """FAILSAFE. Asks the app (answered off its main thread: the tap goes off at once). No answer in 2 s = the app hangs:
    it is killed (its event tap dies with it, his hands are free) and started again."""
    try:
        r = _call('POST', '/release-all', {'why': why}, timeout=2)
        return {'ok': True, 'how': 'released by the app', 'answer': r}
    except Exception as e:
        err = str(e)
    if subprocess.run(['pgrep', '-x', 'MacroRecorder'], capture_output=True).returncode != 0:
        return {'ok': True, 'how': 'Macro Recorder is not running: nothing can hold the keyboard', 'error': err}
    subprocess.run(['pkill', '-9', '-x', 'MacroRecorder'])
    time.sleep(0.8)
    subprocess.run(['open', '-g', '-a', APP, '--args', '--login'])
    return {'ok': True, 'how': 'the app did not answer (%s): killed and started again' % err}


class _Watch(threading.Thread):
    """Renews the lease every PING_S while the work runs; when Marko takes over (or the lock is gone), calls on_override once."""

    def __init__(self, o, on_override, renew=True):
        super().__init__(daemon=True)
        self.o, self.on_override, self.stop = o, on_override, threading.Event()
        self.renew = renew
        self.fired = False

    def run(self):
        n = 0
        while not self.stop.wait(0.25):
            n += 1
            if self.renew and n % int(PING_S / 0.25) == 0:
                ping((self.o, 0))
            st = status()
            if st.get('lock') == 'overridden' or (st.get('lock') == 'off' and not st.get('giving_back')) or \
                    (st.get('lock') == 'on' and st.get('owner') not in (self.o, None, '')):
                # overridden = TAKE OVER; off = the watchdog lifted it (90 s, release-all): stop rather than run on unguarded
                self.fired = True
                self.on_override(st)
                return


class held:
    """with guard.held("what"): ... — renews itself while the block runs (a block of real work, not of thinking);
    TAKE OVER raises KeyboardInterrupt in the main thread (or calls on_override), then Overridden at the end."""

    def __init__(self, what, seconds=60, restore=True, linger_ms=0, on_override=None):
        self.what, self.seconds, self.restore, self.linger = what, seconds, restore, linger_ms
        self.on_override = on_override
        self.own = None
        self.watch = None
        self.skip = os.environ.get('GUARD') == '0'

    def __enter__(self):
        if self.skip:
            return self
        name, _ = owner()
        self.own = (name, os.getpid())            # v34: this process: gone = lifted at once
        begin(self.what, self.seconds, self.restore, own=self.own, quiet=True)
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


def run(cmd, what=None, seconds=60, restore=True, linger_ms=0, quiet=False):
    """`guard run` for Python callers: runs cmd (list) while the guard is held. Returns its exit code; 130 = aborted
    (Marko took over or the guard was lifted), 3 = no guard (the command did NOT run), 4 = still queued."""
    what = what or ' '.join(os.path.basename(x) if i == 0 else x for i, x in enumerate(cmd))[:70]
    if os.environ.get('GUARD') == '0':
        return subprocess.call(cmd)
    name, _ = owner()
    o = (name, os.getpid())
    try:
        begin(what, seconds, restore, own=o, quiet=quiet)
    except Overridden as e:
        _say('ABORTED, command not run: %s' % e, quiet)
        return 130
    except Unavailable as e:
        _say('NOT held, command not run: %s' % e, quiet)
        return 4 if getattr(e, 'queued', False) else 3
    env = dict(os.environ, GUARD_OWNER=o[0], GUARD_PID=str(o[1]))
    p = subprocess.Popen(cmd, env=env, start_new_session=True)
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
    end(linger_ms, own=o)
    if stopped:
        why = 'Marko took over (TAKE OVER)' if stopped[0].get('lock') == 'overridden' else \
            'the guard was lifted (%s)' % (stopped[0].get('ended') or stopped[0].get('lock'))
        _say('ABORTED, command stopped: ' + why, quiet)
        return 130
    _say('released', quiet)
    return rc


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
    if cmd in ('release-all', 'release', 'panic'):
        r = release_all(' '.join(a) or 'release-all')
        print('guard: released everything (%s)' % r['how'])
        return 0
    if cmd == 'ping':
        r = ping()
        print('guard: ' + ('lease renewed' if r.get('ok') else 'not held (%s)' % (r.get('ended') or r.get('error') or r.get('lock'))))
        return 0 if r.get('ok') else 1
    if cmd == 'begin':
        secs = int(_opt(a, '--seconds', 60))
        idle = float(_opt(a, '--idle', LEASE_IDLE_S))
        restore = not _opt(a, '--no-restore', flag=True)
        what = ' '.join(a) or 'working'
        if os.environ.get('GUARD') == '0':
            print('guard: skipped (GUARD=0)')
            return 0
        try:
            r = begin(what, secs, restore, idle=idle, quiet=True)
        except Overridden as e:
            print('guard: ABORTED, NOT held: %s' % e)
            return 130
        except Unavailable as e:
            print('guard: NOT held: %s' % e)
            return 4 if getattr(e, 'queued', False) else 3
        o, pid = owner()
        print('guard: held by %s (pid %s)%s; lease %g s idle, %s s max: hold it per burst, `guard end` when the steps are done'
              % (o, pid, ' nested' if r.get('nested') else '', idle, (r.get('lease') or {}).get('max_left', secs)))
        return 0
    if cmd == 'end':
        r = end(int(_opt(a, '--linger', 0)))
        print('guard: ' + ('released (given back)' if r.get('ok') else 'NOT given back: %s' % r.get('error')))
        return 0 if r.get('ok') else 1
    if cmd == 'run':
        secs = int(_opt(a, '--seconds', 60))
        what = _opt(a, '--what', None)
        restore = not _opt(a, '--no-restore', flag=True)
        linger = int(_opt(a, '--linger', 0))
        if a and a[0] == '--':
            a.pop(0)
        if not a:
            print('guard run [--what X] -- <command>', file=sys.stderr)
            return 2
        return run(a, what, secs, restore, linger)
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
