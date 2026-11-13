"""app.py: Macro Recorder (Mantra) for Linux. One window, the keys, and the inbox Claude drives it through.

- Ctrl+Alt+Super+R records (again: stops and saves), Ctrl+Alt+Super+P plays the last macro, Ctrl+Super+1..0 plays
  that slot. (Ctrl+1..0 as on the Mac would take Chrome's tab keys on Linux.)
- The inbox (~/.mantra_macro/inbox/<id>.ahk -> <id>.result.json) is the same as the Mac app's: a script, or
  `run: <name>`, `record: <name>`, `stop:`, `list:`. The `macro` command writes it and waits.
- One script at a time; never while recording. ESC is not a stop key here: Ctrl+Alt+Super+S stops a playing macro.
"""
import json
import os
import queue
import threading
import time
import traceback

import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GLib, Gdk  # noqa: E402

try:
    gi.require_version('Keybinder', '3.0')
    from gi.repository import Keybinder  # noqa: E402
except (ValueError, ImportError):
    Keybinder = None

from . import store, verbs, VERSION                # noqa: E402
from .backend import Backend, Stopped               # noqa: E402
from .recorder import Recorder, events_to_script    # noqa: E402
from .script import Interp, ScriptError, Stop       # noqa: E402

REC_KEY, PLAY_KEY, STOP_KEY = '<Ctrl><Alt><Super>r', '<Ctrl><Alt><Super>p', '<Ctrl><Alt><Super>s'
PIDFILE = os.path.join(store.DIR, 'linux.pid')


class App:
    def __init__(self):
        self.backend = Backend()
        self.recorder = None
        self.rec_name = None
        self.playing = None
        self.jobs = queue.Queue()
        self.last = None
        self.status_text = 'ready'
        self.build_window()
        self.bind_keys()
        threading.Thread(target=self.worker, daemon=True).start()
        GLib.timeout_add(200, self.poll_inbox)
        with open(PIDFILE, 'w') as f:
            f.write(str(os.getpid()))

    # ------------------------------------------------------------------------------------------- window
    def build_window(self):
        w = self.win = Gtk.Window(title='Macro Recorder (Mantra)')
        w.set_default_size(560, 520)
        w.set_wmclass('mantra-macro', 'Mantra-macro')
        w.connect('delete-event', lambda *a: (w.hide(), True)[1])   # closing hides; quit from the star or QUIT
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin=12)
        w.add(box)

        top = Gtk.Box(spacing=8)
        self.rec_btn = Gtk.Button(label='● RECORD')
        self.rec_btn.connect('clicked', lambda *_: self.toggle_record())
        self.name_entry = Gtk.Entry(placeholder_text='name of the new macro')
        self.name_entry.set_hexpand(True)
        stop = Gtk.Button(label='■ STOP')
        stop.connect('clicked', lambda *_: self.stop_all())
        top.pack_start(self.rec_btn, False, False, 0)
        top.pack_start(self.name_entry, True, True, 0)
        top.pack_start(stop, False, False, 0)
        box.pack_start(top, False, False, 0)

        self.status = Gtk.Label(xalign=0)
        box.pack_start(self.status, False, False, 0)

        self.listbox = Gtk.ListBox()
        sc = Gtk.ScrolledWindow()
        sc.add(self.listbox)
        box.pack_start(sc, True, True, 0)

        bottom = Gtk.Box(spacing=8)
        folder = Gtk.Button(label='MACROS FOLDER')
        folder.connect('clicked', lambda *_: self.backend.run(store.MACROS))
        quit_ = Gtk.Button(label='QUIT')
        quit_.connect('clicked', lambda *_: self.quit())
        ver = Gtk.Label(label='Linux v%d · %s' % (VERSION, 'keys: Ctrl+Alt+Super R record, P play, S stop'), xalign=1)
        bottom.pack_start(folder, False, False, 0)
        bottom.pack_start(quit_, False, False, 0)
        bottom.pack_end(ver, True, True, 0)
        box.pack_start(bottom, False, False, 0)
        self.refresh()
        self.set_status('ready')

    def refresh(self):
        for c in self.listbox.get_children():
            self.listbox.remove(c)
        slots = {v: k for k, v in store.slots().items()}
        for name in store.names():
            row = Gtk.Box(spacing=6, margin=4)
            play = Gtk.Button(label='▶')
            play.connect('clicked', lambda _b, n=name: self.jobs.put(('run', n, None)))
            lab = Gtk.Label(label=name, xalign=0)
            lab.set_hexpand(True)
            slot = Gtk.ComboBoxText()
            slot.append('', '–')
            for k in '1234567890':
                slot.append(k, k)
            slot.set_active_id(slots.get(name, ''))
            slot.connect('changed', lambda c, n=name: (store.set_slot(c.get_active_id(), n) if c.get_active_id()
                                                        else store.set_slot(slots.get(n, ''), None)))
            edit = Gtk.Button(label='EDIT')
            edit.connect('clicked', lambda _b, n=name: self.backend.run(store.path(n)))
            dele = Gtk.Button(label='✕')
            dele.connect('clicked', lambda _b, n=name: (store.delete(n), self.refresh()))
            for wdg, exp in ((play, False), (lab, True), (slot, False), (edit, False), (dele, False)):
                row.pack_start(wdg, exp, exp, 0)
            self.listbox.add(row)
        self.listbox.show_all()

    def set_status(self, text):
        self.status_text = text
        GLib.idle_add(lambda: (self.status.set_markup('<b>%s</b>' % GLib.markup_escape_text(text)), False)[1])

    def show(self):
        self.win.show_all()
        self.win.present()

    def quit(self):
        try:
            os.remove(PIDFILE)
        except OSError:
            pass
        Gtk.main_quit()

    # --------------------------------------------------------------------------------------------- keys
    def bind_keys(self):
        if not Keybinder:
            self.set_status('ready (no global keys: gir1.2-keybinder-3.0 missing)')
            return
        Keybinder.init()
        Keybinder.bind(REC_KEY, lambda *_: self.toggle_record())
        Keybinder.bind(PLAY_KEY, lambda *_: self.last and self.jobs.put(('run', self.last, None)))
        Keybinder.bind(STOP_KEY, lambda *_: self.stop_all())
        for k in '1234567890':
            Keybinder.bind('<Ctrl><Super>' + k, lambda _k, key=k: self.play_slot(key))

    def play_slot(self, key):
        n = store.slots().get(key)
        if n:
            self.jobs.put(('run', n, None))

    # ------------------------------------------------------------------------------------- record / stop
    def toggle_record(self, name=None):
        if self.recorder:
            return self.stop_record()
        return self.start_record(name)

    def start_record(self, name=None):
        if self.playing:
            return False, 'a macro is playing'
        if self.recorder:
            return False, 'already recording "%s"' % self.rec_name
        self.rec_name = store.safe_name(name or self.name_entry.get_text())
        self.recorder = Recorder(ignore_chord=({'^', '!', '#'}, 'r'))
        self.recorder.start()
        self.set_status('● RECORDING "%s" (Ctrl+Alt+Super+R stops)' % self.rec_name)
        GLib.idle_add(lambda: (self.rec_btn.set_label('■ STOP RECORDING'), False)[1])
        return True, 'recording "%s"' % self.rec_name

    def stop_record(self):
        if not self.recorder:
            return False, 'not recording'
        events = self.recorder.stop()
        text = events_to_script(events, self.rec_name, self.recorder.started)
        p = store.write(self.rec_name, text)
        self.last = self.rec_name
        self.recorder = None
        self.set_status('saved "%s" (%d steps)' % (self.rec_name, len(events)))
        GLib.idle_add(lambda: (self.rec_btn.set_label('● RECORD'), self.refresh(), False)[2])
        return True, 'saved %s' % p

    def stop_all(self):
        self.backend.stop_event.set()
        if self.recorder:
            self.stop_record()

    # --------------------------------------------------------------------------------------- playing
    def play_text(self, text, label):
        self.backend.stop_event.clear()
        self.playing = label
        self.set_status('▶ playing %s' % label)
        it = Interp(self.backend, log=lambda m: self.set_status(m), run_macro=lambda n: it.run(store.read(n)))
        try:
            it.run(text)
            self.set_status('done: %s' % label)
            return {'ok': True, 'message': 'ok', 'line': 0}
        except (Stop,):
            self.set_status('done: %s' % label)
            return {'ok': True, 'message': 'ok', 'line': 0}
        except Stopped:
            self.set_status('stopped: %s' % label)
            return {'ok': False, 'message': 'stopped', 'line': 0}
        except ScriptError as e:
            self.set_status('error in %s, line %d: %s' % (label, e.line, e))
            return {'ok': False, 'message': str(e), 'line': e.line}
        except Exception as e:
            traceback.print_exc()
            return {'ok': False, 'message': repr(e), 'line': 0}
        finally:
            self.playing = None

    def worker(self):
        while True:
            kind, arg, reply = self.jobs.get()
            if self.recorder:
                res = {'ok': False, 'message': 'recording: only stop: is taken', 'line': 0}
            elif kind == 'run':
                if not os.path.exists(store.path(arg)):
                    res = {'ok': False, 'message': 'no macro "%s"' % arg, 'line': 0}
                else:
                    self.last = arg
                    res = self.play_text(store.read(arg), '"%s"' % arg)
            else:
                res = self.play_text(arg, 'a script from the inbox')
            if reply:
                reply(res)

    # ----------------------------------------------------------------------------------------- inbox
    def poll_inbox(self):
        try:
            files = sorted(f for f in os.listdir(store.INBOX) if f.endswith('.ahk'))
        except OSError:
            return True
        for f in files:
            p = os.path.join(store.INBOX, f)
            try:
                text = open(p).read()
            except OSError:
                continue
            os.remove(p)
            out = os.path.join(store.INBOX, f[:-4] + '.result.json')

            def reply(res, out=out):
                tmp = out + '.part'
                with open(tmp, 'w') as fh:
                    json.dump(res, fh)
                os.replace(tmp, out)

            head = text.strip()
            low = head.lower()
            if low.startswith('stop:'):
                ok, msg = self.stop_record() if self.recorder else (True, 'stopped')
                self.backend.stop_event.set()
                reply({'ok': ok, 'message': msg, 'line': 0})
            elif self.recorder:
                reply({'ok': False, 'message': 'recording: only stop: is taken', 'line': 0})
            elif low.startswith('record:'):
                ok, msg = self.start_record(head[7:].strip())
                reply({'ok': ok, 'message': msg, 'line': 0})
            elif low.startswith('list:'):
                reply({'ok': True, 'message': '\n'.join(store.names()), 'line': 0})
            elif low.startswith('show:'):
                GLib.idle_add(lambda: (self.show(), False)[1])
                reply({'ok': True, 'message': 'shown', 'line': 0})
            elif low.startswith('run:'):
                self.jobs.put(('run', head[4:].strip(), reply))
            elif verbs.is_verb(head):           # captures, windows, OCR, lock (v3); run off the GTK thread
                threading.Thread(target=lambda h=head, r=reply: r(verbs.dispatch(h)[1]), daemon=True).start()
            else:
                self.jobs.put(('script', text, reply))
        return True


def main(show=True):
    Gdk.set_program_class('Mantra-macro')
    app = App()
    if show:
        app.show()
    Gtk.main()
