"""script.py: MANTRA SCRIPT (AutoHotkey v2 syntax, docs/SCRIPT.md) for Linux.

The same language as app/Script.swift on the Mac, for the commands a recorded or hand-written macro uses: the mouse,
the keyboard, waiting, windows, Run, variables, if/else, Loop, while, break/continue, ExitApp. Actions go through a
Backend (backend.py: xdotool on X11), so the interpreter is tested without a screen (tests/test_script.py).
"""
import ast
import re
import time


class ScriptError(Exception):
    def __init__(self, msg, line=0):
        super().__init__(msg)
        self.line = line


class Stop(Exception):
    pass


class _Break(Exception):
    pass


class _Continue(Exception):
    pass

# ------------------------------------------------------------------------------------------------- parsing

def _strip_comment(s):
    out, q = [], False
    for i, ch in enumerate(s):
        if ch == '"':
            q = not q
        if ch == ';' and not q and (i == 0 or s[i - 1] in ' \t'):
            break
        out.append(ch)
    return ''.join(out).strip()


def _lines(text):
    """(line number, code) with comments and blank lines gone; '} else {' and '{' / '}' split into their own items."""
    out = []
    in_block_comment = False
    for n, raw in enumerate(text.splitlines(), 1):
        s = raw.strip()
        if s.startswith('/*'):
            in_block_comment = True
        if in_block_comment:
            if '*/' in s:
                in_block_comment = False
            continue
        s = _strip_comment(s)
        if not s:
            continue
        while s.startswith('}'):
            out.append((n, '}'))
            s = s[1:].strip()
        if not s:
            continue
        if s.endswith('{') and s != '{':
            out.append((n, s[:-1].strip()))
            out.append((n, '{'))
        else:
            out.append((n, s))
    return out


def parse(text):
    items = _lines(text)
    pos = 0

    def block():
        nonlocal pos
        body = []
        while pos < len(items):
            n, s = items[pos]
            if s == '}':
                pos += 1
                return body
            body.append(stmt())
        return body

    def body_after(n):
        nonlocal pos
        if pos < len(items) and items[pos][1] == '{':
            pos += 1
            return block()
        if pos < len(items):
            return [stmt()]
        raise ScriptError('missing body', n)

    def stmt():
        nonlocal pos
        n, s = items[pos]
        pos += 1
        low = s.lower()
        if low.startswith('if ') or low.startswith('if('):
            cond = s[2:].strip()
            then = body_after(n)
            els = []
            if pos < len(items) and items[pos][1].lower().startswith('else'):
                en, es = items[pos]
                pos += 1
                rest = es[4:].strip()
                if rest:  # else if ...
                    items.insert(pos, (en, rest))
                    els = [stmt()]
                else:
                    els = body_after(en)
            return ('if', n, cond, then, els)
        if low == 'loop' or low.startswith('loop ') or low.startswith('loop,'):
            count = s[4:].strip().lstrip(',').strip() or None
            return ('loop', n, count, body_after(n))
        if low.startswith('while ') or low.startswith('while('):
            return ('while', n, s[5:].strip(), body_after(n))
        return ('cmd', n, s)

    prog = []
    while pos < len(items):
        if items[pos][1] == '}':
            raise ScriptError('a } with no {', items[pos][0])
        prog.append(stmt())
    return prog

# ---------------------------------------------------------------------------------------------- expressions

_OPS = [('&&', ' and '), ('||', ' or '), ('<>', ' != ')]


def _to_python(expr):
    """AutoHotkey expression -> Python expression (outside strings only)."""
    parts = re.split(r'("(?:[^"`]|`.)*")', expr)
    out = []
    for i, p in enumerate(parts):
        if i % 2:  # a string literal: AutoHotkey escapes with a backtick
            body = p[1:-1].replace('`n', '\n').replace('`t', '\t').replace('`"', '"').replace('``', '`')
            out.append('_S(%r)' % body)
            continue
        for a, b in _OPS:
            p = p.replace(a, b)
        p = re.sub(r'(?<![!<>=:])=(?!=)', '==', p)       # AutoHotkey's = compares
        p = re.sub(r'!(?!=)', ' not ', p)
        p = re.sub(r'\bnot\b\s*', ' not ', p, flags=re.I)
        p = re.sub(r'\band\b', ' and ', p, flags=re.I)
        p = re.sub(r'\bor\b', ' or ', p, flags=re.I)
        p = re.sub(r'\btrue\b', 'True', p, flags=re.I)
        p = re.sub(r'\bfalse\b', 'False', p, flags=re.I)
        p = re.sub(r'\s\.\s', ' + ', p)                    # concatenation (strings are made to add, see _Str)
        out.append(p)
    return ''.join(out)


class _Str(str):
    """A string that concatenates with numbers and compares with them the way AutoHotkey does."""
    def _num(self):
        try:
            return float(self) if self.strip() else 0
        except ValueError:
            return None

    def _cmp(self, o, op):
        if isinstance(o, (int, float)) and not isinstance(o, bool):
            n = self._num()
            if n is not None:
                return op(n, o)
        return op(str(self), _txt(o))

    def __lt__(self, o): return self._cmp(o, lambda a, b: a < b)
    def __le__(self, o): return self._cmp(o, lambda a, b: a <= b)
    def __gt__(self, o): return self._cmp(o, lambda a, b: a > b)
    def __ge__(self, o): return self._cmp(o, lambda a, b: a >= b)
    def __eq__(self, o): return self._cmp(o, lambda a, b: a == b if not isinstance(a, str) else a.lower() == b.lower())
    def __ne__(self, o): return not self.__eq__(o)
    __hash__ = str.__hash__

    def __add__(self, o):
        return _Str(str(self) + _txt(o))

    def __radd__(self, o):
        return _Str(_txt(o) + str(self))


def _txt(v):
    if isinstance(v, bool):
        return '1' if v else '0'
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    return str(v)


class Interp:
    def __init__(self, backend, log=print, macros_dir=None, run_macro=None):
        self.b = backend
        self.log = log
        self.vars = {}
        self.macros_dir = macros_dir
        self.run_macro = run_macro
        self.funcs = {
            'WinActive': lambda t='': int(self.b.win_active(t)),
            'WinExist': lambda t='': int(self.b.win_exist(t)),
            'FileExist': lambda p: int(__import__('os').path.exists(__import__('os').path.expanduser(p))),
            'FileRead': lambda p: _Str(open(__import__('os').path.expanduser(p)).read()),
            'StrLen': lambda s: len(_txt(s)),
            'InStr': lambda h, n, *_: _txt(h).find(_txt(n)) + 1,
            'SubStr': lambda s, i, n=None: _Str(_txt(s)[int(i) - 1:(int(i) - 1 + int(n)) if n is not None else None]),
            'StrReplace': lambda s, a, b='': _Str(_txt(s).replace(_txt(a), _txt(b))),
            'Integer': lambda v: int(float(v)),
            'String': lambda v: _Str(_txt(v)),
            'Round': lambda v, n=0: round(float(v), int(n)) if n else int(round(float(v))),
            'Abs': abs, 'Min': min, 'Max': max,
            'Random': lambda a=0, b=1: __import__('random').randint(int(a), int(b)),
            'PixelGetColor': lambda x, y: _Str(self.b.pixel(int(x), int(y))),
            'A_TickCount': None,
        }

    # -- values
    def eval(self, expr, line):
        expr = expr.strip()
        if expr == '':
            return _Str('')
        py = _to_python(expr)
        names = dict(self.vars)
        names.update({k: v for k, v in self.funcs.items() if v is not None})
        names['_S'] = _Str
        names['A_TickCount'] = int(time.monotonic() * 1000)
        names['A_ScreenWidth'], names['A_ScreenHeight'] = self.b.screen_size()
        try:
            tree = ast.parse(py, mode='eval')
        except SyntaxError:
            raise ScriptError('cannot read: ' + expr, line)
        for node in ast.walk(tree):
            if isinstance(node, (ast.Attribute, ast.Lambda, ast.ListComp, ast.DictComp, ast.SetComp, ast.GeneratorExp)):
                raise ScriptError('not allowed here: ' + expr, line)
            if isinstance(node, ast.Name) and node.id not in names:
                names[node.id] = _Str('')
            if isinstance(node, ast.Constant) and isinstance(node.value, str):
                pass
        try:
            v = eval(compile(tree, '<macro>', 'eval'), {'__builtins__': {}}, names)
        except ScriptError:
            raise
        except Exception as e:
            raise ScriptError('%s: %s' % (expr, e), line)
        return _Str(v) if isinstance(v, str) and not isinstance(v, _Str) else v

    def truthy(self, v):
        if isinstance(v, str):
            return v not in ('', '0')
        return bool(v)

    # -- arguments: split at commas outside quotes, brackets and parentheses
    @staticmethod
    def split_args(s):
        out, cur, depth, q = [], [], 0, False
        for ch in s:
            if ch == '"':
                q = not q
            if not q:
                if ch in '([':
                    depth += 1
                elif ch in ')]':
                    depth -= 1
                elif ch == ',' and depth == 0:
                    out.append(''.join(cur).strip())
                    cur = []
                    continue
            cur.append(ch)
        if cur or out:
            out.append(''.join(cur).strip())
        return out

    def args(self, raw, line):
        return [self.eval(a, line) if a != '' else None for a in self.split_args(raw)]

    # -- running
    def run(self, text):
        try:
            self.exec_block(parse(text))
        except Stop:
            pass  # ExitApp / return: a normal end

    def exec_block(self, body):
        for node in body:
            self.exec(node)

    def exec(self, node):
        kind, line = node[0], node[1]
        self.b.check_stop()
        if kind == 'if':
            _, _, cond, then, els = node
            self.exec_block(then if self.truthy(self.eval(cond, line)) else els)
        elif kind == 'loop':
            _, _, count, body = node
            n = None if count is None else int(float(self.eval(count, line)))
            i = 0
            while n is None or i < n:
                i += 1
                self.vars['A_Index'] = i
                try:
                    self.exec_block(body)
                except _Break:
                    break
                except _Continue:
                    continue
        elif kind == 'while':
            _, _, cond, body = node
            i = 0
            while self.truthy(self.eval(cond, line)):
                i += 1
                self.vars['A_Index'] = i
                try:
                    self.exec_block(body)
                except _Break:
                    break
                except _Continue:
                    continue
        else:
            self.command(node[2], line)

    def command(self, s, line):
        m = re.match(r'^([A-Za-z_]\w*)\s*(\+\+|--|:=|\+=|-=|\*=|/=|\.=)\s*(.*)$', s)
        if m:
            name, op, rhs = m.groups()
            cur = self.vars.get(name, 0)
            if op == '++':
                self.vars[name] = int(float(cur or 0)) + 1
            elif op == '--':
                self.vars[name] = int(float(cur or 0)) - 1
            else:
                v = self.eval(rhs, line)
                self.vars[name] = {':=': lambda: v, '+=': lambda: cur + v, '-=': lambda: cur - v,
                                   '*=': lambda: cur * v, '/=': lambda: cur / v,
                                   '.=': lambda: _Str(_txt(cur) + _txt(v))}[op]()
            return
        low = s.lower()
        if low == 'break':
            raise _Break()
        if low == 'continue':
            raise _Continue()
        if low in ('exitapp', 'return', 'exit'):
            raise Stop()
        m = re.match(r'^([A-Za-z_]\w*)(?:\((.*)\)|\s*,?\s*(.*))$', s)
        if not m:
            raise ScriptError('cannot read: ' + s, line)
        name = m.group(1)
        raw = m.group(2) if m.group(2) is not None else (m.group(3) or '')
        fn = getattr(self, 'c_' + name.lower(), None)
        if fn is None:
            if name in self.funcs and self.funcs[name]:
                self.funcs[name](*[a for a in self.args(raw, line) if a is not None])
                return
            raise ScriptError('unknown command: ' + name, line)
        fn(raw, line)

    # -- commands: the mouse
    def _xy(self, a, i):
        return int(float(a[i])), int(float(a[i + 1]))

    def c_click(self, raw, line):
        a = self.args(raw, line) if raw.strip() else []
        if len(a) == 1 and isinstance(a[0], str) and re.match(r'^\s*-?\d+\s+-?\d+', a[0]):
            a = a[0].split()                       # Click "100 200"
        button, count = 'Left', 1
        x = y = None
        if len(a) >= 2 and a[0] is not None:
            x, y = self._xy(a, 0)
            for extra in a[2:]:
                if extra is None:
                    continue
                if isinstance(extra, str) and extra.strip().lower() in ('right', 'r', 'middle', 'm', 'left', 'l'):
                    button = {'r': 'Right', 'm': 'Middle', 'l': 'Left'}.get(extra.strip().lower()[0], 'Left')
                else:
                    count = int(float(extra))
        self.b.click(x, y, button, count)

    def c_mousemove(self, raw, line):
        a = self.args(raw, line)
        self.b.move(*self._xy(a, 0))

    def c_mouseclick(self, raw, line):
        a = self.args(raw, line)
        button = (a[0] or 'Left').capitalize() if a else 'Left'
        x = y = None
        if len(a) >= 3 and a[1] is not None:
            x, y = self._xy(a, 1)
        count = int(float(a[3])) if len(a) > 3 and a[3] is not None else 1
        self.b.click(x, y, button, count)

    def c_mouseclickdrag(self, raw, line):
        a = self.args(raw, line)
        self.b.drag((a[0] or 'Left').capitalize(), *self._xy(a, 1), *self._xy(a, 3))

    def c_mousegetpos(self, raw, line):
        names = [x.strip().lstrip('&') for x in self.split_args(raw)]
        x, y = self.b.mouse_pos()
        if names and names[0]:
            self.vars[names[0]] = x
        if len(names) > 1 and names[1]:
            self.vars[names[1]] = y

    # -- the keyboard
    def c_send(self, raw, line):
        self.b.send(_txt(self.args(raw, line)[0]))

    c_sendinput = c_send
    c_sendevent = c_send

    def c_sendtext(self, raw, line):
        self.b.type_text(_txt(self.args(raw, line)[0]))

    # -- waiting
    def c_sleep(self, raw, line):
        ms = float(self.args(raw, line)[0])
        end = time.monotonic() + ms / 1000
        while time.monotonic() < end:
            self.b.check_stop()
            time.sleep(min(0.05, max(0, end - time.monotonic())))

    # -- windows and apps
    def c_winactivate(self, raw, line):
        a = self.args(raw, line)
        if not self.b.win_activate(_txt(a[0]) if a else ''):
            raise ScriptError('no window: %s' % (a[0] if a else ''), line)

    def _wait(self, test, raw, line):
        a = self.args(raw, line)
        title = _txt(a[0]) if a else ''
        limit = float(a[2]) if len(a) > 2 and a[2] is not None else (float(a[1]) if len(a) > 1 and a[1] is not None else 0)
        end = time.monotonic() + limit if limit else None
        while not test(title):
            self.b.check_stop()
            if end and time.monotonic() > end:
                self.vars['ErrorLevel'] = 1
                return
            time.sleep(0.1)
        self.vars['ErrorLevel'] = 0

    def c_winwait(self, raw, line):
        self._wait(self.b.win_exist, raw, line)

    def c_winwaitactive(self, raw, line):
        self._wait(self.b.win_active, raw, line)

    def c_winclose(self, raw, line):
        a = self.args(raw, line)
        self.b.win_close(_txt(a[0]) if a else '')

    def c_wingetpos(self, raw, line):
        parts = self.split_args(raw)
        names = [p.strip().lstrip('&') for p in parts[:4]]
        title = _txt(self.eval(parts[4], line)) if len(parts) > 4 else ''
        geo = self.b.win_geometry(title)
        if geo is None:
            raise ScriptError('no window: ' + title, line)
        for n, v in zip(names, geo):
            if n:
                self.vars[n] = v

    def c_run(self, raw, line):
        a = self.args(raw, line)
        self.b.run(_txt(a[0]))

    def c_msgbox(self, raw, line):
        a = self.args(raw, line)
        msg = _txt(a[0]) if a else ''
        self.log(msg)
        self.b.notify(msg)

    c_tooltip = c_msgbox
    c_traytip = c_msgbox

    def c_fileappend(self, raw, line):
        a = self.args(raw, line)
        import os
        with open(os.path.expanduser(_txt(a[1])), 'a') as f:
            f.write(_txt(a[0]))

    def c_playmacro(self, raw, line):
        a = self.args(raw, line)
        if not self.run_macro:
            raise ScriptError('PlayMacro: no macro store', line)
        self.run_macro(_txt(a[0]))

    def c_settitlematchmode(self, raw, line):
        pass  # titles always match by part, as mode 2

    def c_coordmode(self, raw, line):
        pass  # coordinates are always the screen's

    def c_setkeydelay(self, raw, line):
        pass
