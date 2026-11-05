#!/bin/sh
# build.sh (Linux): tests, then one file: dist/N-mantra_macro_linux-vN.pyz (N = VERSION in mantra_macro/__init__.py).
# A .pyz is the app zipped with its own __main__: any Linux with python3, python3-gi, gir1.2-gtk-3.0,
# gir1.2-keybinder-3.0, python3-xlib and xdotool runs it, on any CPU (the VM is arm64, the build runner x86).
set -e
cd "$(dirname "$0")"
python3 -m unittest discover -s tests
N=$(python3 -c "import re;print(re.search(r'VERSION = (\d+)', open('mantra_macro/__init__.py').read()).group(1))")
OUT="dist/$N-mantra_macro_linux-v$N.pyz"
rm -rf build dist && mkdir -p build dist
cp -r mantra_macro build/
find build -name __pycache__ -prune -exec rm -rf {} +
printf 'import runpy\nrunpy.run_module("mantra_macro", run_name="__main__")\n' > build/__main__.py
python3 -m zipapp build -o "$OUT" -p "/usr/bin/env python3"
cp macro dist/macro
python3 "$OUT" --version
echo "$OUT"
