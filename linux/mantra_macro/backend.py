"""backend.py: what a script does to the screen on Linux (X11), through xdotool and wmctrl.

`Backend` is the real one. `FakeBackend` records the calls, for the tests (no screen needed).
"""
import os
import re
import shlex
import shutil
import subprocess
import threading

# AutoHotkey key names -> X keysyms
KEYS = {
    'enter': 'Return', 'return': 'Return', 'tab': 'Tab', 'esc': 'Escape', 'escape': 'Escape', 'space': 'space',
    'bs': 'BackSpace', 'backspace': 'BackSpace', 'del': 'Delete', 'delete': 'Delete', 'ins': 'Insert',
    'insert': 'Insert', 'up': 'Up', 'down': 'Down', 'left': 'Left', 'right': 'Right', 'home': 'Home', 'end': 'End',
    'pgup': 'Prior', 'pgdn': 'Next', 'appskey': 'Menu', 'printscreen': 'Print', 'capslock': 'Caps_Lock',
    'ctrl': 'ctrl', 'control': 'ctrl', 'lctrl': 'ctrl', 'rctrl': 'ctrl', 'alt': 'alt', 'lalt': 'alt', 'ralt': 'alt',
    'shift': 'shift', 'lshift': 'shift', 'rshift': 'shift', 'win': 'super', 'lwin': 'super', 'rwin': 'super',
    'cmd': 'super', 'lcmd': 'super', 'rcmd': 'super',
    '!': 'exclam', '^': 'asciicircum', '+': 'plus', '#': 'numbersign', '{': 'braceleft', '}': 'braceright',
    'volume_up': 'XF86AudioRaiseVolume', 'volume_down': 'XF86AudioLowerVolume', 'volume_mute': 'XF86AudioMute',
    'media_play_pause': 'XF86AudioPlay',
}
for i in range(1, 25):
    KEYS['f%d' % i] = 'F%d' % i
MODS = {'^': 'ctrl', '!': 'alt', '+': 'shift', '#': 'super'}
WHEEL = {'wheelup': 4, 'wheeldown': 5, 'wheelleft': 6, 'wheelright': 7}


def keysym(name):
    k = KEYS.get(name.lower())
    if k:
        return k
    if len(name) == 1:
        return name
    return name  # a keysym written directly, e.g. {KP_Enter}


def send_plan(text):
    """Turn a Send string into steps: ('type', text) | ('key', 'ctrl+c') | ('down'/'up', key) | ('wheel', button, n)."""
    steps, mods, buf = [], [], []

    def flush():
        if buf:
            steps.append(('type', ''.join(buf)))
            buf.clear()

    i = 0
    while i < len(text):
        ch = text[i]
        if ch in MODS:
            flush()
            mods.append(MODS[ch])
            i += 1
            continue
        if ch == '{':
            j = text.find('}', i + 2) if text[i + 1:i + 2] == '}' else text.find('}', i + 1)
            if j < 0:
                buf.append(ch)
                i += 1
                continue
            inner = text[i + 1:j]
            i = j + 1
            parts = inner.split(' ')
            name = parts[0] if inner not in ('}', ' ') else inner
            arg = parts[1].lower() if len(parts) > 1 else None
            if name.lower() in WHEEL:
                flush()
                steps.append(('wheel', WHEEL[name.lower()], int(arg or 1)))
                mods = []
                continue
            k = keysym(name)
            flush()
            if arg in ('down', 'up'):
                steps.append((arg, k))
            else:
                n = int(arg) if arg and arg.isdigit() else 1
                for _ in range(n):
                    steps.append(('key', '+'.join(mods + [k])))
            mods = []
            continue
        if mods:
            flush()
            k = keysym(ch) if not ch.isalpha() else ch.lower()
            if ch.isalpha() and ch.isupper():
                mods = mods + ['shift']
            steps.append(('key', '+'.join(mods + [k])))
            mods = []
        elif ch == '\n':
            flush()
            steps.append(('key', 'Return'))
        else:
            buf.append(ch)
        i += 1
    flush()
    return steps


class Stopped(Exception):
    pass


class Backend:
    def __init__(self):
        self.stop_event = threading.Event()
        self.env = dict(os.environ, DISPLAY=os.environ.get('DISPLAY', ':1'))

    def check_stop(self):
        if self.stop_event.is_set():
            raise Stopped()

    def _x(self, *args, capture=False):
        r = subprocess.run(['xdotool', *map(str, args)], env=self.env, capture_output=True, text=True)
        return r.stdout.strip() if capture else r.returncode == 0

    # mouse
    def click(self, x, y, button='Left', count=1):
        b = {'Left': 1, 'Middle': 2, 'Right': 3}.get(button, 1)
        if x is not None:
            self._x('mousemove', '--sync', x, y)
        self._x('click', '--repeat', count, '--delay', 80, b)

    def move(self, x, y):
        self._x('mousemove', '--sync', x, y)

    def drag(self, button, x1, y1, x2, y2):
        b = {'Left': 1, 'Middle': 2, 'Right': 3}.get(button, 1)
        self._x('mousemove', '--sync', x1, y1, 'mousedown', b, 'sleep', 0.1, 'mousemove', '--sync', x2, y2,
                'sleep', 0.1, 'mouseup', b)

    def mouse_pos(self):
        out = self._x('getmouselocation', '--shell', capture=True)
        d = dict(l.split('=') for l in out.splitlines() if '=' in l)
        return int(d.get('X', 0)), int(d.get('Y', 0))

    def screen_size(self):
        out = self._x('getdisplaygeometry', capture=True).split()
        return (int(out[0]), int(out[1])) if len(out) == 2 else (0, 0)

    def pixel(self, x, y):
        r = subprocess.run(['import', '-window', 'root', '-crop', '1x1+%d+%d' % (x, y), 'txt:-'],
                           env=self.env, capture_output=True, text=True)
        m = re.search(r'#([0-9A-Fa-f]{6})', r.stdout)
        return '0x' + m.group(1).upper() if m else '0x000000'

    # keyboard
    def send(self, text):
        for step in send_plan(text):
            self.check_stop()
            if step[0] == 'type':
                self._x('type', '--delay', 8, '--', step[1])
            elif step[0] == 'key':
                self._x('key', '--clearmodifiers', step[1])
            elif step[0] == 'down':
                self._x('keydown', step[1])
            elif step[0] == 'up':
                self._x('keyup', step[1])
            elif step[0] == 'wheel':
                self._x('click', '--repeat', step[2], '--delay', 30, step[1])

    def type_text(self, text):
        self._x('type', '--delay', 8, '--', text)

    # windows: titles match by part (AutoHotkey's mode 2), or "ahk_class X"
    def _find(self, title):
        if title.lower().startswith('ahk_class '):
            out = self._x('search', '--onlyvisible', '--class', re.escape(title[10:].strip()), capture=True)
        else:
            out = self._x('search', '--onlyvisible', '--name', re.escape(title), capture=True)
        ids = [i for i in out.split() if i.isdigit()]
        return ids[0] if ids else None

    def win_active(self, title=''):
        name = self._x('getactivewindow', 'getwindowname', capture=True)
        return title.lower() in name.lower() if title else bool(name)

    def win_exist(self, title=''):
        return self._find(title) is not None

    def win_activate(self, title):
        wid = self._find(title)
        if not wid:
            return False
        return self._x('windowactivate', '--sync', wid)

    def win_close(self, title):
        wid = self._find(title)
        if wid:
            self._x('windowclose', wid)

    def win_geometry(self, title):
        wid = self._find(title) if title else self._x('getactivewindow', capture=True)
        if not wid:
            return None
        out = self._x('getwindowgeometry', '--shell', wid, capture=True)
        d = dict(l.split('=') for l in out.splitlines() if '=' in l)
        return int(d['X']), int(d['Y']), int(d['WIDTH']), int(d['HEIGHT'])

    def run(self, target):
        target = target.strip()
        if re.match(r'^[a-z]+://', target):
            subprocess.Popen(['xdg-open', target], env=self.env, start_new_session=True)
            return
        parts = [os.path.expanduser(p) for p in shlex.split(target)]
        if parts and (shutil.which(parts[0]) or os.access(parts[0], os.X_OK) and os.path.isfile(parts[0])):
            subprocess.Popen(parts, env=self.env, start_new_session=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            subprocess.Popen(['xdg-open', os.path.expanduser(target)], env=self.env, start_new_session=True)

    def notify(self, msg):
        if shutil.which('notify-send'):
            subprocess.Popen(['notify-send', 'Macro Recorder', msg], env=self.env)


class FakeBackend(Backend):
    def __init__(self, windows=('Google Chrome',), active='Google Chrome'):
        self.stop_event = threading.Event()
        self.calls = []
        self.windows = list(windows)
        self.active = active
        self.pos = (0, 0)

    def click(self, x, y, button='Left', count=1):
        self.calls.append(('click', x, y, button, count))

    def move(self, x, y):
        self.pos = (x, y)
        self.calls.append(('move', x, y))

    def drag(self, *a):
        self.calls.append(('drag',) + a)

    def mouse_pos(self):
        return self.pos

    def screen_size(self):
        return (1920, 1080)

    def pixel(self, x, y):
        return '0x000000'

    def send(self, text):
        self.calls.append(('send', text))

    def type_text(self, text):
        self.calls.append(('type', text))

    def win_active(self, title=''):
        return title.lower() in self.active.lower()

    def win_exist(self, title=''):
        return any(title.lower() in w.lower() for w in self.windows)

    def win_activate(self, title):
        self.calls.append(('activate', title))
        if self.win_exist(title):
            self.active = next(w for w in self.windows if title.lower() in w.lower())
            return True
        return False

    def win_close(self, title):
        self.calls.append(('close', title))

    def win_geometry(self, title):
        return (10, 20, 800, 600) if self.win_exist(title) else None

    def run(self, target):
        self.calls.append(('run', target))

    def notify(self, msg):
        self.calls.append(('notify', msg))
