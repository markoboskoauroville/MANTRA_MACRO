#!/bin/bash
# deploy_site.sh: mantramacrorecorder.pages.dev (site/public) on Cloudflare Pages. The account id and token are read
# from Marko's API folder, never printed. The DMG on the page is the one tools/make_dmg.sh made (copied by this script).
set -euo pipefail
cd "$(dirname "$0")/.."
V=$(sed -n 's/^let VERSION = \([0-9]*\)/\1/p' app/App.swift)
[ -f "build/MantraMacroRecorder-$V.dmg" ] || { echo "no build/MantraMacroRecorder-$V.dmg: run build.sh and tools/make_dmg.sh"; exit 1; }
rm -f site/public/MantraMacroRecorder-*.dmg; cp "build/MantraMacroRecorder-$V.dmg" site/public/
grep -q "MantraMacroRecorder-$V.dmg" site/public/index.html || { echo "index.html does not link MantraMacroRecorder-$V.dmg"; exit 1; }
# every page with the donation bowl is search-engine optimised (Marko, 31.10.2026)
python3 ~/Developer/MANTRA_MANIFEST/kits/seo/seo_app_page.py site/public --url https://mantramacrorecorder.pages.dev --name "Macro Recorder (Mantra)" --version "$V" --download "MantraMacroRecorder-$V.dmg" --keywords "macro recorder mac, AutoHotkey for Mac, mouse recorder, keyboard macro, automation macOS, free macro app" --image shot-window.png
eval "$(python3 - <<'PY'
import re,os
raw=open(os.path.expanduser('~/Downloads/API/Cloudflare.api.txt')).read()
acc=re.search(r'dash\.cloudflare\.com/([0-9a-f]{32})', raw).group(1)
tok=[l.strip() for l in raw.splitlines() if re.fullmatch(r'[A-Za-z0-9_\-]{30,}', l.strip())][-1]
print(f"export CLOUDFLARE_ACCOUNT_ID={acc}; export CLOUDFLARE_API_TOKEN={tok}")
PY
)"
npx --yes wrangler@3 pages project create mantramacrorecorder --production-branch main >/dev/null 2>&1 || true
npx --yes wrangler@3 pages deploy site/public --project-name mantramacrorecorder --branch main --commit-dirty=true 2>&1 | grep -v -i "token\|account" | tail -3
