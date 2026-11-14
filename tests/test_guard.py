#!/usr/bin/env python3
"""test_guard.py: the guard end to end (v27, 14.11.2026). Harmless targets only: a NEW iTerm2 window running `cat -u > file`
(the "user"), a NEW untitled TextEdit document (the "automation"). Nothing is sent anywhere, nothing saved.

1 the user's window is in front; 2 the guard is taken; 3 a simulated user types "hello marko 42x" + Backspace + Return as
unmarked key events (as his hands would) while 4 `macro do` activates TextEdit and types the automation's sentence;
5 the guard is given back. Pass = the cat file holds exactly the user's line, TextEdit exactly the automation's text,
iTerm2 is in front again, and `guard last` reports the keys replayed into iTerm2.
"""
import json, os, subprocess, sys, tempfile, threading, time
import Quartz

sys.path.insert(0, os.path.expanduser('~/Developer/MANTRA_MACRO/tools'))
import guard  # noqa: E402

D = tempfile.mkdtemp(prefix='guardtest-')
USER_FILE = os.path.join(D, 'user.txt')
AUTO_TEXT = '1 automation typed this'   # starts with a digit: TextEdit capitalises a first letter
USER_KEYS = [(4, 'h'), (14, 'e'), (37, 'l'), (37, 'l'), (31, 'o'), (49, ' '), (46, 'm'), (0, 'a'), (15, 'r'), (40, 'k'),
             (31, 'o'), (49, ' '), (21, '4'), (19, '2'), (7, 'x'), (51, ''), (36, '\r')]
USER_EXPECT = 'hello marko 42\n'
OWNER = ('guardtest-%d' % os.getpid(), os.getpid())


def osa(s):
    return subprocess.run(['osascript', '-e', s], capture_output=True, text=True).stdout.strip()


def front():
    return osa('tell application "System Events" to get name of first process whose frontmost is true')


def user_types():
    time.sleep(0.4)
    for code, ch in USER_KEYS:
        for down in (True, False):
            e = Quartz.CGEventCreateKeyboardEvent(None, code, down)
            if ch:
                Quartz.CGEventKeyboardSetUnicodeString(e, len(ch), ch)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, e)
            time.sleep(0.02)
        time.sleep(0.05)


def main():
    print('scratch', D)
    osa('tell application "TextEdit" to make new document')
    osa(f'tell application "iTerm2" to create window with default profile command "/bin/sh -c \'/bin/cat -u > {USER_FILE}\'"')
    osa('tell application "iTerm2" to activate')
    time.sleep(1.5)
    f0 = front()
    print('front before:', f0)
    ok = True
    try:
        guard.begin('guard test: automation into TextEdit', 30, True, own=OWNER)
        t = threading.Thread(target=user_types)
        t.start()
        env = dict(os.environ, GUARD_OWNER=OWNER[0], GUARD_PID=str(OWNER[1]), MACRO_LINGER='0')
        r = subprocess.run(['macro', 'do', f'WinActivate "TextEdit"\nSleep 300\nSendText "{AUTO_TEXT}"'], env=env,
                           capture_output=True, text=True, timeout=60)
        print('macro do:', (r.stdout + r.stderr).strip())
        t.join()
        time.sleep(0.3)
        print('status while held:', json.dumps({k: v for k, v in guard.status().items() if k in ('lock', 'owner', 'buffered_keys', 'front_app')}))
    finally:
        print('end:', guard.end(0, own=OWNER))
    time.sleep(2.5)
    f1 = front()
    user = open(USER_FILE).read() if os.path.exists(USER_FILE) else None
    if user and user.startswith('claude\n'):
        user = user[len('claude\n'):]     # iTerm2's default profile sends "claude" at start; not the user's keys
    auto = osa('tell application "TextEdit" to get text of front document')
    last = guard.last()
    print('front after:', f1)
    print('user file:', repr(user))
    print('TextEdit :', repr(auto))
    print('notice   :', last.get('notice'))
    checks = {'user text exact': user == USER_EXPECT, 'automation text exact': auto == AUTO_TEXT,
              'front back': f1 == f0, 'replayed count': last.get('replayed') == len(USER_KEYS) - 0}
    for k, v in checks.items():
        print(('PASS ' if v else 'FAIL ') + k)
        ok = ok and v
    # tidy: the test window and document go away, nothing saved
    osa('tell application "TextEdit" to close front document saving no')
    subprocess.run(['pkill', '-f', 'cat -u > ' + USER_FILE])
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
