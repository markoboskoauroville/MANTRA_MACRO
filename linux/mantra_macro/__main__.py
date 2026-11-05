"""python3 mantra_macro.pyz [--hidden] [--version] [--check FILE]"""
import sys

from . import VERSION


def main():
    a = sys.argv[1:]
    if '--version' in a:
        print('%d-mantra_macro_linux-v%d' % (VERSION, VERSION))
        return
    if '--check' in a:                      # parse a script without running it (no screen needed)
        from .script import parse, ScriptError
        try:
            parse(open(a[a.index('--check') + 1]).read())
            print('ok')
        except ScriptError as e:
            print('line %d: %s' % (e.line, e))
            sys.exit(1)
        return
    from .app import main as run
    run(show='--hidden' not in a)


main()
