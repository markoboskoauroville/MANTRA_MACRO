"""recorder.py: records the keyboard and mouse on X11 (the RECORD extension) and writes it as MANTRA SCRIPT.

Same output as the Mac recorder: `Click x, y`, `Send "..."` for keys, `Sleep ms` for pauses, a header comment.
`events_to_script` is pure and tested (tests/test_recorder.py).
"""
import threading
import time

PAUSE_MIN_MS = 250      # shorter gaps are not written
PAUSE_MAX_MS = 10000    # a longer gap is written as this
DOUBLE_MS = 400

MOD_KEYSYMS = {
    'Control_L': '^', 'Control_R': '^', 'Alt_L': '!', 'Alt_R': '!', 'Meta_L': '!', 'Meta_R': '!',
    'Shift_L': '+', 'Shift_R': '+', 'Super_L': '#', 'Super_R': '#',
}
NAMED = {
    'Return': '{Enter}', 'KP_Enter': '{Enter}', 'Tab': '{Tab}', 'Escape': '{Esc}', 'BackSpace': '{BS}',
    'Delete': '{Del}', 'Insert': '{Ins}', 'Up': '{Up}', 'Down': '{Down}', 'Left': '{Left}', 'Right': '{Right}',
    'Home': '{Home}', 'End': '{End}', 'Prior': '{PgUp}', 'Next': '{PgDn}', 'space': ' ',
}
SPECIAL_CHARS = {'!': '{!}', '^': '{^}', '+': '{+}', '#': '{#}', '{': '{{}', '}': '{}}'}


def key_text(keysym_name, char, mods):
    """One key press as Send text."""
    prefix = ''.join(sorted(set(mods), key='^!+#'.index))
    if keysym_name in NAMED:
        t = NAMED[keysym_name]
        return prefix + ('{Space}' if t == ' ' and prefix else t)
    if keysym_name.startswith('F') and keysym_name[1:].isdigit():
        return prefix + '{%s}' % keysym_name
    if prefix and prefix != '+':
        base = keysym_name.lower() if len(keysym_name) == 1 else (char or keysym_name).lower()
        return prefix.replace('+', '') + ('+' if '+' in prefix else '') + SPECIAL_CHARS.get(base, base)
    c = char or (keysym_name if len(keysym_name) == 1 else '')
    if not c:
        return prefix + '{%s}' % keysym_name
    return SPECIAL_CHARS.get(c, c)


def _q(s):
    return '"' + s.replace('`', '``').replace('"', '`"') + '"'


def events_to_script(events, name='', started=None):
    """events: dicts {t (s), kind: 'click'|'key'|'wheel', ...} -> script text."""
    lines = ['; %s, recorded %s on Linux' % (name or 'macro', time.strftime('%d.%m.%Y %H:%M', time.localtime(started or time.time())))]
    send_buf = []
    last_t = None

    def flush():
        if send_buf:
            lines.append('Send ' + _q(''.join(send_buf)))
            send_buf.clear()

    i = 0
    while i < len(events):
        e = events[i]
        if last_t is not None:
            gap = int(round((e['t'] - last_t) * 1000))
            if gap >= PAUSE_MIN_MS:
                flush()
                lines.append('Sleep %d' % min(gap, PAUSE_MAX_MS))
        if e['kind'] == 'click':
            flush()
            count = 1
            while (i + 1 < len(events) and events[i + 1]['kind'] == 'click' and events[i + 1]['button'] == e['button']
                   and abs(events[i + 1]['x'] - e['x']) <= 3 and abs(events[i + 1]['y'] - e['y']) <= 3
                   and (events[i + 1]['t'] - events[i]['t']) * 1000 <= DOUBLE_MS):
                count += 1
                i += 1
            extra = ''
            if e['button'] != 'Left':
                extra = ', ' + _q(e['button'])
                if count > 1:
                    extra = ', ' + _q(e['button']) + ', ' + str(count)
            elif count > 1:
                extra = ', ' + str(count)
            lines.append('Click %d, %d%s' % (e['x'], e['y'], extra))
        elif e['kind'] == 'drag':
            flush()
            lines.append('MouseClickDrag "Left", %d, %d, %d, %d' % (e['x'], e['y'], e['x2'], e['y2']))
        elif e['kind'] == 'wheel':
            n = 1
            while i + 1 < len(events) and events[i + 1]['kind'] == 'wheel' and events[i + 1]['dir'] == e['dir']:
                n += 1
                i += 1
            flush()
            lines.append('Send "{Wheel%s %d}"' % (e['dir'], n))
        elif e['kind'] == 'key':
            send_buf.append(e['text'])
        last_t = events[i]['t']
        i += 1
    flush()
    return '\n'.join(lines) + '\n'


class Recorder:
    """Listens to X with RECORD in a thread. `stop()` returns the events."""

    def __init__(self, ignore_chord=None):
        self.events = []
        self.started = None
        self._thread = None
        self._ctx = None
        self._mods = set()
        self._press = None
        self.ignore_chord = ignore_chord  # (set of mod chars, keysym) that toggles recording, not written

    def start(self):
        from Xlib import display, X
        from Xlib.ext import record
        self.events, self.started, self._mods, self._press = [], time.time(), set(), None
        self._d_ctl = display.Display()
        self._d_rec = display.Display()
        self._ctx = self._d_ctl.record_create_context(0, [record.AllClients], [{
            'core_requests': (0, 0), 'core_replies': (0, 0), 'ext_requests': (0, 0, 0, 0),
            'ext_replies': (0, 0, 0, 0), 'delivered_events': (0, 0), 'device_events': (X.KeyPress, X.MotionNotify),
            'errors': (0, 0), 'client_started': False, 'client_died': False}])
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self):
        try:
            self._d_rec.record_enable_context(self._ctx, self._on)
        except Exception:
            pass

    def _on(self, reply):
        from Xlib import X, XK
        from Xlib.ext import record
        from Xlib.protocol import rq
        if reply.category != record.FromServer or reply.client_swapped or not reply.data:
            return
        data = reply.data
        while data:
            ev, data = rq.EventField(None).parse_binary_value(data, self._d_rec.display, None, None)
            t = time.time()
            if ev.type in (X.KeyPress, X.KeyRelease):
                ks = self._d_rec.keycode_to_keysym(ev.detail, 1 if ev.state & X.ShiftMask else 0)
                name = XK.keysym_to_string(ks) if ks else None
                sym = _keysym_name(self._d_rec, ev.detail)
                if sym in MOD_KEYSYMS:
                    (self._mods.add if ev.type == X.KeyPress else self._mods.discard)(MOD_KEYSYMS[sym])
                    continue
                if ev.type != X.KeyPress:
                    continue
                if self.ignore_chord and self.ignore_chord[0] <= self._mods and sym and sym.lower() == self.ignore_chord[1]:
                    continue
                char = name if name and len(name) == 1 else None
                self.events.append({'t': t, 'kind': 'key', 'text': key_text(sym or '', char, self._mods)})
            elif ev.type == X.ButtonPress:
                if ev.detail in (4, 5, 6, 7):
                    self.events.append({'t': t, 'kind': 'wheel', 'dir': {4: 'Up', 5: 'Down', 6: 'Left', 7: 'Right'}[ev.detail]})
                else:
                    self._press = (t, ev.detail, ev.root_x, ev.root_y)
            elif ev.type == X.ButtonRelease and self._press and ev.detail == self._press[1]:
                pt, b, x, y = self._press
                self._press = None
                button = {1: 'Left', 2: 'Middle', 3: 'Right'}.get(b, 'Left')
                if b == 1 and (abs(ev.root_x - x) > 6 or abs(ev.root_y - y) > 6):
                    self.events.append({'t': pt, 'kind': 'drag', 'x': x, 'y': y, 'x2': ev.root_x, 'y2': ev.root_y})
                else:
                    self.events.append({'t': pt, 'kind': 'click', 'button': button, 'x': x, 'y': y})

    def stop(self):
        try:
            self._d_ctl.record_disable_context(self._ctx)
            self._d_ctl.flush()
            if self._thread:
                self._thread.join(2)
            self._d_ctl.record_free_context(self._ctx)
        except Exception:
            pass
        return self.events


def _keysym_name(d, keycode):
    from Xlib import XK
    ks = d.keycode_to_keysym(keycode, 0)
    for name in ('Return', 'Tab', 'Escape', 'BackSpace', 'Delete', 'Insert', 'Up', 'Down', 'Left', 'Right', 'Home',
                 'End', 'Prior', 'Next', 'space', 'KP_Enter') + tuple(MOD_KEYSYMS) + tuple('F%d' % i for i in range(1, 25)):
        if XK.string_to_keysym(name) == ks:
            return name
    s = XK.keysym_to_string(ks)
    return s or ''
