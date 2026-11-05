"""Interpreter and recorder tests: no screen, a FakeBackend records what would happen. python3 -m unittest"""
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from mantra_macro.backend import FakeBackend, send_plan          # noqa: E402
from mantra_macro.script import Interp, ScriptError, parse       # noqa: E402
from mantra_macro.recorder import events_to_script, key_text     # noqa: E402


def run(text, **kw):
    b = FakeBackend(**kw)
    it = Interp(b, log=lambda m: None)
    it.run(text)
    return b.calls, it.vars


class Script(unittest.TestCase):
    def test_click_send_sleep(self):
        calls, _ = run('; c\nClick 640, 400\nSleep 1\nSend "Hello{Enter}"')
        self.assertEqual(calls, [('click', 640, 400, 'Left', 1), ('send', 'Hello{Enter}')])

    def test_click_forms(self):
        calls, _ = run('Click 1, 2, 2\nClick 3, 4, "Right"\nClick\nClick "5 6"\nMouseClick "Right", 7, 8')
        self.assertEqual(calls, [('click', 1, 2, 'Left', 2), ('click', 3, 4, 'Right', 1),
                                 ('click', None, None, 'Left', 1), ('click', 5, 6, 'Left', 1),
                                 ('click', 7, 8, 'Right', 1)])

    def test_loop_if_else_break(self):
        calls, v = run('n := 0\nLoop 10 {\n  n += 1\n  if (n = 3) {\n    break\n  }\n}\n'
                       'if n >= 3\n  Send "yes"\nelse\n  Send "no"')
        self.assertEqual(v['n'], 3)
        self.assertEqual(calls, [('send', 'yes')])

    def test_else_if_and_strings(self):
        calls, v = run('a := "x" . 2\nif (a = "y") {\nSend "1"\n} else if (a = "x2") {\nSend "2"\n} else {\nSend "3"\n}')
        self.assertEqual(calls, [('send', '2')])

    def test_while_and_a_index(self):
        _, v = run('s := 0\nwhile (A_Index < 100 && s < 10)\n  s += 2')
        self.assertEqual(v['s'], 10)

    def test_windows(self):
        calls, v = run('if WinActive("Chrome")\n  Send "a"\nWinActivate "Terminal"', windows=('Google Chrome', 'Terminal'))
        self.assertIn(('activate', 'Terminal'), calls)
        with self.assertRaises(ScriptError):
            run('WinActivate "Nope"')
        _, v = run('WinGetPos &x, &y, &w, &h, "Chrome"')
        self.assertEqual((v['x'], v['y'], v['w'], v['h']), (10, 20, 800, 600))

    def test_run_and_exit(self):
        calls, _ = run('Run "python3 x.py selfReload"\nExitApp\nSend "never"')
        self.assertEqual(calls, [('run', 'python3 x.py selfReload')])

    def test_errors_carry_the_line(self):
        with self.assertRaises(ScriptError) as e:
            run('Click 1, 2\nFrobnicate 3')
        self.assertEqual(e.exception.line, 2)
        with self.assertRaises(ScriptError):
            parse('}')

    def test_send_plan(self):
        self.assertEqual(send_plan('^c'), [('key', 'ctrl+c')])
        self.assertEqual(send_plan('ab{Enter 2}'), [('type', 'ab'), ('key', 'Return'), ('key', 'Return')])
        self.assertEqual(send_plan('#{Tab}'), [('key', 'super+Tab')])
        self.assertEqual(send_plan('{Ctrl down}x{Ctrl up}'), [('down', 'ctrl'), ('type', 'x'), ('up', 'ctrl')])
        self.assertEqual(send_plan('{WheelDown 3}'), [('wheel', 5, 3)])
        self.assertEqual(send_plan('{!}'), [('key', 'exclam')])


class Recorder(unittest.TestCase):
    def test_events_to_script(self):
        ev = [{'t': 0.0, 'kind': 'click', 'button': 'Left', 'x': 10, 'y': 20},
              {'t': 0.1, 'kind': 'click', 'button': 'Left', 'x': 11, 'y': 20},
              {'t': 1.0, 'kind': 'key', 'text': 'h'}, {'t': 1.05, 'kind': 'key', 'text': 'i'},
              {'t': 1.1, 'kind': 'key', 'text': '{Enter}'},
              {'t': 2.0, 'kind': 'wheel', 'dir': 'Down'}, {'t': 2.01, 'kind': 'wheel', 'dir': 'Down'}]
        lines = events_to_script(ev, 'n').splitlines()[1:]
        self.assertEqual(lines, ['Click 10, 20, 2', 'Sleep 900', 'Send "hi{Enter}"', 'Sleep 900',
                                 'Send "{WheelDown 2}"'])
        # what it writes, it can play
        calls, _ = run(events_to_script(ev, 'n').replace('Sleep 900', 'Sleep 1').replace('Sleep 900', 'Sleep 1'))
        self.assertEqual(calls[0], ('click', 10, 20, 'Left', 2))

    def test_key_text(self):
        self.assertEqual(key_text('c', 'c', {'^'}), '^c')
        self.assertEqual(key_text('Return', None, set()), '{Enter}')
        self.assertEqual(key_text('exclam', '!', set()), '{!}')
        self.assertEqual(key_text('A', 'A', {'+'}), 'A')


if __name__ == '__main__':
    unittest.main()
