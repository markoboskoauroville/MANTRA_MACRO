-- settings_page.lua
--
-- THE MACRO RECORDER'S SETTINGS, AS A WEB PAGE. Marko's request, 5.9.2026:
-- "develop the settings menu as a web page, small one and big one, same as we
-- have with the other apps." So: one page served on 127.0.0.1:8829, opened
-- two ways, a small floating window from the star menu (or its own key) and a
-- tab in the browser. It is ONE page, not two: the small window asks for
-- ?mini and the same page draws itself tighter. One page to fix, no drift.
--
-- WHAT IS ON IT, top to bottom: the transport (record, play, stop, new
-- macro), the ten slots with their chords and the arrows and drag to reorder,
-- the macros on disk with rename and the check marks that put one into a
-- slot, the keys with Change for each, the playback settings, the window
-- settings and the folder. Everything is always drawn; what cannot be used
-- is dimmed, never removed, so the layout never jumps under a finger.
--
-- NOTHING HERE KEEPS ITS OWN STATE. Every poll asks macro.lua what is true
-- now and draws that. The macros come from the folder each time, so a file
-- renamed in the Finder shows on the next poll, and a slot that still points
-- at the old name says "missing" instead of pretending.
--
-- ALSO SERVED HERE: /editor (the script editor, editor_page.lua), /docs (the
-- language), /script and /commands (what the editor reads), /images and
-- /image (the pictures ClickImage looks for).
--
-- This file is a function: macro.lua calls it with itself on start and gets
-- back the page object; stop() closes the window and the server.

return function(M)

local P = {}
local PORT  = 8829
local SLOTS = M.SLOTS
local SCRIPT = M.SCRIPT
local HERE = debug.getinfo(1, "S").source:match("^@(.*/)") or ""
local EDITOR = dofile(HERE .. "editor_page.lua")
P.port = PORT

------------------------------------------------------------------ the state

-- Everything the page draws, as one table, encoded with hs.json.
local function state()
    local K = M.settings.keys
    local names = {}
    local macros = M.macroInfo()
    for _, m in ipairs(macros) do names[m.name] = true end
    local actions = {}
    for _, a in ipairs(M.ACTIONS) do
        local b = K[a.id] or {}
        actions[#actions + 1] = { id = a.id, label = a.label, mods = b.mods or {}, key = b.key or "",
                                  keyLabel = M.keyLabel(b) }
    end
    local note = false
    if M.note and M.note.text then
        note = { text = M.note.text, at = M.note.at }
    end
    local url, localUrl = P.url()
    local lastError = false
    if M.lastError then lastError = { name = M.lastError.name or "", line = M.lastError.line or 0, msg = M.lastError.msg or "", at = M.lastError.at or 0 } end
    return {
        build = P.build,
        lastError = lastError,
        images = M.listImages(),
        recording = M.recording, playing = M.playing,
        capture = M.capture or "",
        pending = M.pending or "",
        current = M.current or "",
        inPlayer = (M.text and #M.text > 0) and 1 or 0,
        lastExists = hs.fs.attributes(M.lastFile) ~= nil,
        note = note,
        speed = M.settings.speed, ignoreTravel = M.settings.ignoreTravel and true or false,
        clickDelay = M.settings.clickDelay,
        speeds = M.SPEEDS, delays = M.DELAYS,
        autoSmall = M.settings.autoSmall and true or false,
        onTop = M.settings.onTop and true or false,
        lan = M.settings.lan and true or false,
        actions = actions,
        loadMods = K.loadMods or {}, loadLabel = M.modsLabel(K.loadMods),
        runMods  = K.runMods  or {}, runLabel  = M.modsLabel(K.runMods),
        slots = SLOTS.rows(M.settings.slots, names),
        macros = macros,
        folder = M.macDir,
        url = url, localUrl = localUrl,
        defaultName = M.croName(),
    }
end

------------------------------------------------------------------ the actions

local GREY = { white = 0.6, alpha = 1 }

-- One verb per request, a JSON body with `a` and its arguments. Anything that
-- starts posting events (record, play, run) is scheduled a beat later so this
-- reply goes back to the page first. A refusal is spoken through M.say so the
-- page and the badge both carry the reason.
local function act(d)
    local a = d.a
    local later = function(fn) M.later = hs.timer.doAfter(0.05, function() pcall(fn) end) end
    local ok, err, extra = true, nil, nil
    if a == "record" then later(M.toggleRecording)
    elseif a == "play" then later(M.togglePlay)
    elseif a == "stop" then M.stopAll()
    elseif a == "new" then later(function() M.newMacroNamed(d.name) end)
    elseif a == "runslot" then later(function() M.runSlot(d.slot) end)
    elseif a == "loadslot" then ok, err = M.loadSlot(d.slot)
    elseif a == "assign" then ok, err = M.assignSlot(d.slot, d.name)
    elseif a == "clear" then ok, err = M.clearSlot(d.slot)
    elseif a == "move" then ok, err = M.moveSlot(d.from, d.to)
    elseif a == "swap" then ok, err = M.swapSlot(d.a1, d.b1)
    elseif a == "up" or a == "down" then
        local other = SLOTS.neighbour(d.slot, a == "up" and -1 or 1)
        if other then ok, err = M.swapSlot(d.slot, other) end
    elseif a == "rename" then ok, err = M.renameMacro(d.old, d.new)
    elseif a == "trash" then ok, err = M.trashMacro(d.name)
    elseif a == "capture" then ok, err = M.captureKey(d.id)
    elseif a == "mods" then ok, err = M.setMods(d.which, d.mods)
    elseif a == "resetkeys" then M.resetKeys()
    elseif a == "speed" then M.setSpeed(tonumber(d.v) or 1)
    elseif a == "ignore" then M.setIgnore(not M.settings.ignoreTravel)
    elseif a == "delay" then M.setDelay(tonumber(d.v) or 0)
    elseif a == "autosmall" then P.toggleAutoSmall()
    elseif a == "ontop" then P.toggleOnTop()
    elseif a == "lan" then P.toggleLan()
    elseif a == "folder" then M.openFolder()
    elseif a == "big" then P.big()
    -- the editor and the pictures
    elseif a == "savescript" then
        local okS, errS, warning, line = M.saveScript(d.name, d.text)
        ok, err = okS, errS
        if warning then extra = { warning = warning, line = line } end
    elseif a == "check" then
        local okC, errC, line = M.checkScript(d.text)
        ok, err = okC, errC
        if line then extra = { line = line } end
        if not okC then return ok, err, extra end        -- a check is not spoken aloud
    elseif a == "runscript" then
        local okR, errR, line = M.runNamed(d.name)
        ok, err = okR, errR
        if line then extra = { line = line } end
    elseif a == "newscript" then
        local okN, nameOrErr = M.newScript(d.name)
        ok = okN
        if okN then extra = { name = nameOrErr } else err = nameOrErr end
    elseif a == "edit" then P.editor(d.name)
    elseif a == "docs" then P.docs()
    elseif a == "snap" then ok, err = M.snap(d.name or "")
    elseif a == "findtest" then later(function() M.findTest(d.name) end)
    elseif a == "trashimage" then ok, err = M.trashImage(d.name)
    else ok, err = false, "unknown action " .. tostring(a) end
    if not ok and err then M.say(err, GREY, 2.5) end
    return ok, err, extra
end

------------------------------------------------------------------ the page

local PAGE = [==[
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>Macro Recorder</title>
<style>
  :root{
    --black:#0B0D10; --panel:#141A21; --slate:#23303D; --line:#2a3542;
    --sand:#F2DDB4; --amber:#F59E0B; --dim:#6E7681; --red:#F04E4E; --green:#4FD98A;
    --gap:14px;
  }
  *{box-sizing:border-box;margin:0;padding:0}
  html,body{background:var(--black);color:var(--sand);overflow-x:hidden;
    font:15px/1.45 ui-sans-serif,-apple-system,"Helvetica Neue",Arial,sans-serif;
    -webkit-text-size-adjust:100%}
  body{padding:var(--gap);max-width:760px;margin:0 auto}
  h1{font-size:12px;letter-spacing:.22em;text-transform:uppercase;color:var(--dim);font-weight:600}
  h2{font-size:11px;letter-spacing:.2em;text-transform:uppercase;color:var(--dim);font-weight:600;
    margin:0 0 8px}
  section{background:var(--panel);border:1px solid var(--line);border-radius:12px;
    padding:12px var(--gap);margin-bottom:var(--gap)}
  .hint{font-size:12px;color:var(--dim);line-height:1.35}
  button{font:inherit;color:var(--sand);background:var(--slate);border:0;border-radius:8px;
    padding:8px 12px;cursor:pointer;
    box-shadow:inset 0 1px 0 rgba(255,255,255,.08),inset 0 -2px 0 rgba(0,0,0,.35)}
  button:hover:not(:disabled){background:#2c3b4a}
  button:active:not(:disabled){transform:translateY(1px)}
  button:disabled{opacity:.35;cursor:default}
  button.icon{padding:6px 9px;min-width:34px;font-size:14px}
  button.danger{color:#ffb4b4}
  input[type=text]{font:inherit;color:var(--sand);background:#0a0d11;border:1px solid var(--line);
    border-radius:8px;padding:8px 10px;width:100%;min-width:0}
  input[type=text]:focus{outline:none;border-color:var(--amber)}

  /* THE TRANSPORT. A readout that says one line, and three keys with a lamp. */
  .deckhead{display:flex;align-items:center;gap:10px;margin-bottom:10px}
  .lcd{flex:1;min-width:0;background:#0a0d08;color:var(--amber);border:1px solid #1f2a1a;
    border-radius:6px;padding:6px 10px;font:12px/1.3 ui-monospace,Menlo,monospace;
    min-height:2.6em;display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;
    overflow:hidden;text-shadow:0 0 6px rgba(245,158,11,.45)}
  .lcd.rec{color:var(--red);text-shadow:0 0 6px rgba(240,78,78,.5)}
  .lcd.play{color:var(--green);text-shadow:0 0 6px rgba(79,217,138,.5)}
  .keys{display:flex;gap:8px}
  .dk{flex:1;display:flex;flex-direction:column;align-items:center;gap:6px;padding:12px 6px 10px;
    border-radius:8px;background:linear-gradient(180deg,#34424f 0%,#23303D 55%,#1c2732 100%);
    box-shadow:inset 0 1px 0 rgba(255,255,255,.10),inset 0 -4px 0 rgba(0,0,0,.45),0 2px 0 #0b0d10}
  .dk .lamp{width:9px;height:9px;border-radius:50%;background:#2a3542;box-shadow:inset 0 1px 2px rgba(0,0,0,.6)}
  .dk.rec .lamp{background:var(--red);box-shadow:0 0 8px var(--red)}
  .dk.play .lamp{background:var(--green);box-shadow:0 0 8px var(--green)}
  .dk .word{font-size:12px;letter-spacing:.14em;text-transform:uppercase}
  .dk .cap{font-size:11px;color:var(--dim)}
  .newrow{display:flex;gap:8px;margin-top:10px}
  .newrow input{flex:1}

  /* THE SLOTS. Ten rows, always ten, in keyboard order. */
  .slot{display:flex;align-items:center;gap:8px;padding:6px 0;border-top:1px solid var(--line)}
  .slot:first-of-type{border-top:0}
  .slot.over{background:rgba(245,158,11,.08)}
  .slot .grip{color:var(--dim);cursor:grab;padding:0 4px;font-size:16px;user-select:none}
  .slot .digit{width:40px;height:40px;border-radius:8px;background:var(--slate);
    display:flex;align-items:center;justify-content:center;font-size:20px;font-weight:600;
    box-shadow:inset 0 1px 0 rgba(255,255,255,.08),inset 0 -3px 0 rgba(0,0,0,.4);flex:0 0 auto}
  .slot .body{flex:1;min-width:0}
  .slot .name{font-size:16px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .slot .name.empty{color:var(--dim);font-weight:400}
  .slot .name.missing{color:#ffb4b4}
  .slot .chords{font-size:11px;color:var(--dim)}
  .slot .chords b{color:var(--sand);font-weight:600}
  .slot .acts{display:flex;gap:4px;flex:0 0 auto}

  /* THE MACROS. One row per file in the folder, any name. */
  .macro{padding:8px 0;border-top:1px solid var(--line)}
  .macro:first-of-type{border-top:0}
  .macro .top{display:flex;align-items:center;gap:8px}
  .macro .name{flex:1;min-width:0;font-size:16px;font-weight:600;white-space:nowrap;
    overflow:hidden;text-overflow:ellipsis;cursor:text}
  .macro .name:hover{text-decoration:underline dotted var(--dim)}
  .macro .tag{font-size:10px;letter-spacing:.12em;text-transform:uppercase;color:var(--green);
    border:1px solid rgba(79,217,138,.4);border-radius:5px;padding:2px 6px}
  .macro .meta{font-size:12px;color:var(--dim);margin-top:2px}
  .macro .meta.bad{color:#ffb4b4}
  .checks{display:flex;gap:4px;margin-top:6px;flex-wrap:wrap;align-items:center}
  .checks .lbl{font-size:11px;color:var(--dim);margin-right:4px}
  .chk{width:30px;height:30px;border-radius:7px;background:#0a0d11;border:1px solid var(--line);
    color:var(--dim);font-size:13px;display:flex;align-items:center;justify-content:center;
    cursor:pointer;user-select:none}
  .chk:hover{border-color:var(--amber);color:var(--sand)}
  .chk.on{background:var(--amber);color:#111;border-color:var(--amber);font-weight:700}
  .chk.taken{border-style:dashed}

  /* THE KEYS. */
  .krow{display:flex;align-items:center;gap:10px;padding:7px 0;border-top:1px solid var(--line)}
  .krow:first-of-type{border-top:0}
  .krow .what{flex:1;min-width:0;font-size:14px}
  .cap{font:600 14px/1 ui-sans-serif,-apple-system,sans-serif;color:var(--sand);
    background:var(--slate);border-radius:6px;padding:7px 10px;white-space:nowrap;
    box-shadow:inset 0 1px 0 rgba(255,255,255,.08),inset 0 -2px 0 rgba(0,0,0,.4)}
  .cap.wait{color:var(--amber);animation:blink 1s infinite}
  @keyframes blink{50%{opacity:.4}}
  .mods{display:flex;gap:4px}

  /* CHIPS, one row of choices with one lit. */
  .chips{display:flex;gap:6px;flex-wrap:wrap;margin:6px 0 10px}
  .chip{padding:7px 12px;border-radius:999px;background:#0a0d11;border:1px solid var(--line);
    color:var(--sand);font-size:13px;cursor:pointer;user-select:none}
  .chip.on{background:var(--amber);color:#111;border-color:var(--amber);font-weight:600}
  .toggle{display:flex;align-items:center;justify-content:space-between;gap:10px;
    padding:8px 0;border-top:1px solid var(--line)}
  .toggle:first-of-type{border-top:0}
  .toggle .sw{width:44px;height:26px;border-radius:13px;background:#0a0d11;border:1px solid var(--line);
    position:relative;cursor:pointer;flex:0 0 auto}
  .toggle .sw::after{content:"";position:absolute;top:3px;left:3px;width:18px;height:18px;
    border-radius:50%;background:var(--dim);transition:left .15s}
  .toggle .sw.on{background:var(--amber);border-color:var(--amber)}
  .toggle .sw.on::after{left:21px;background:#111}
  .path{font:12px ui-monospace,Menlo,monospace;color:var(--dim);word-break:break-all}
  .row2{display:flex;gap:8px;flex-wrap:wrap;margin-top:8px}
  a.btn{font:inherit;color:var(--sand);background:var(--slate);border-radius:8px;padding:8px 12px;text-decoration:none;display:inline-block}
  .pic{display:flex;align-items:center;gap:10px;padding:6px 0;border-top:1px solid var(--line)}
  .pic:first-of-type{border-top:0}
  .pic img{max-width:120px;max-height:48px;border-radius:4px;background:#fff;flex:0 0 auto}
  .pic .name{flex:1;min-width:0;font:13px ui-monospace,Menlo,monospace;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .macro .kind{font-size:10px;letter-spacing:.12em;text-transform:uppercase;color:var(--dim);border:1px solid var(--line);border-radius:5px;padding:2px 6px}

  /* THE MINI VIEW: the same page, tighter, in the small window. Nothing is
     dropped; a small view that hides half the rows is a second app to learn. */
  body.mini{padding:8px;font-size:13px}
  body.mini section{padding:8px 10px;margin-bottom:8px;border-radius:9px}
  body.mini .slot .digit{width:30px;height:30px;font-size:15px}
  body.mini .slot .name,body.mini .macro .name{font-size:14px}
  body.mini .dk{padding:8px 4px 7px}
  body.mini .chk{width:24px;height:24px;font-size:11px}
  body.mini button.icon{min-width:28px;padding:5px 7px}
  body.mini .hint{font-size:11px}
  ::-webkit-scrollbar{width:8px}
  ::-webkit-scrollbar-thumb{background:var(--slate);border-radius:4px}
</style>
</head>
<body>

<section id="deck">
  <div class="deckhead"><h1>Macro Recorder</h1><div class="lcd" id="lcd">…</div></div>
  <div class="keys">
    <button class="dk" id="kRec"><span class="lamp"></span><span class="word">Record</span><span class="cap" id="cRec"></span></button>
    <button class="dk" id="kPlay"><span class="lamp"></span><span class="word">Play</span><span class="cap" id="cPlay"></span></button>
    <button class="dk" id="kStop"><span class="lamp"></span><span class="word">Stop</span><span class="cap" id="cStop"></span></button>
  </div>
  <div class="newrow">
    <input type="text" id="newName" placeholder="name for a new macro">
    <button id="kNew">Record new</button>
    <button id="kWrite">Write new</button>
  </div>
  <div class="hint" id="newHint">Record new: do the thing, then press the record key to stop. Write new: an empty script opens in the editor. Either lands in the first free slot.</div>
</section>

<section id="slotsSec">
  <h2>Slots</h2>
  <div class="hint" id="slotHint"></div>
  <div id="slots"></div>
</section>

<section id="macrosSec">
  <h2>Macros in the folder</h2>
  <div class="hint">Click a name to rename it. Tick a digit to put the macro in that slot. Edit opens the script. Any file you drop or rename in the folder shows here.</div>
  <div id="macros"></div>
</section>

<section id="imagesSec">
  <h2>Pictures</h2>
  <div class="hint">A picture of a button, cut from the screen. A script finds it with ClickImage "name.png" wherever it is. Snap: drag over the button on the screen.</div>
  <div class="newrow">
    <input type="text" id="snapName" placeholder="name for the picture">
    <button id="kSnap">Snap a picture</button>
  </div>
  <div id="images"></div>
  <div class="row2"><a class="btn" id="kDocs" href="/docs" target="_blank">The language, documentation</a></div>
</section>

<section id="keysSec">
  <h2>Keys</h2>
  <div id="keys"></div>
  <div class="krow"><div class="what">Load a slot into the player with</div><div class="mods" id="loadMods"></div></div>
  <div class="krow"><div class="what">Run a slot with</div><div class="mods" id="runMods"></div></div>
  <div class="hint">Change asks you to press the keys on the Mac. Escape keeps the old key. A key that is already used is refused.</div>
  <div class="row2"><button id="kReset">Back to the default keys</button></div>
</section>

<section id="playSec">
  <h2>Playback</h2>
  <div class="hint">Speed</div><div class="chips" id="speeds"></div>
  <div class="hint">Delay between clicks, one rhythm</div><div class="chips" id="delays"></div>
  <div class="hint">A recording keeps the clicks, keys, drags and scrolls with the time between them; the mouse travel between clicks is left out.</div>
</section>

<section id="winSec">
  <h2>Window</h2>
  <div class="toggle"><div>Open the small window when the recorder starts</div><div class="sw" id="swAuto"></div></div>
  <div class="toggle"><div>Keep the small window on top</div><div class="sw" id="swTop"></div></div>
  <div class="toggle"><div>Reachable from the phone on this wifi</div><div class="sw" id="swLan"></div></div>
  <div class="path" id="addr"></div>
  <div class="row2"><button id="kBig">Open in the browser</button><button id="kFolder">Open the macros folder</button></div>
  <div class="path" id="folder"></div>
</section>

<script>
var BUILD = null, S = null, lastTxt = "", editing = null, armed = {}, dragFrom = null;

function esc(s){ return String(s == null ? "" : s).replace(/[&<>"']/g, function(c){
  return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]; }); }
function send(d){
  return fetch("/do", {method:"POST", body: JSON.stringify(d), cache:"no-store"})
    .then(function(){ setTimeout(poll, 120); }).catch(function(){});
}
function digitLabel(mods, d){ return mods + d; }

// THE READOUT: recording, playing, a fresh note, or what is in the player.
function drawLcd(s){
  var el = document.getElementById("lcd");
  var cls = "lcd", text;
  var fresh = s.note && (Date.now()/1000 - s.note.at) < 6;
  if (s.recording) { cls += " rec"; text = "REC " + (s.pending ? s.pending : "") + "  press " + s.actions[0].keyLabel + " to stop"; }
  else if (s.playing) { cls += " play"; text = "PLAY " + (s.current || "last recording"); }
  else if (s.capture) { text = "press the keys on the Mac now. Esc keeps the old key"; }
  else if (fresh) { text = s.note.text; }
  else if (s.lastError && (Date.now()/1000 - s.lastError.at) < 20) { text = s.lastError.name + ": " + s.lastError.msg; }
  else if (s.current) { text = "in the player: " + s.current + " · " + s.inPlayer + " events"; }
  else if (s.inPlayer > 0 || s.lastExists) { text = "in the player: last recording"; }
  else { text = "nothing in the player. Record, or load a slot"; }
  el.className = cls; el.textContent = text;
  var kr = document.getElementById("kRec"), kp = document.getElementById("kPlay");
  kr.className = "dk" + (s.recording ? " rec" : ""); kp.className = "dk" + (s.playing ? " play" : "");
  document.getElementById("kStop").disabled = !(s.recording || s.playing);
  kp.disabled = !(s.inPlayer > 0 || s.lastExists) && !s.playing;
  var byId = {}; s.actions.forEach(function(a){ byId[a.id] = a.keyLabel; });
  document.getElementById("cRec").textContent = byId.record; document.getElementById("cPlay").textContent = byId.play;
  document.getElementById("cStop").textContent = byId.stop;
  var inp = document.getElementById("newName");
  if (!inp.dataset.touched && document.activeElement !== inp) inp.placeholder = s.defaultName;
}

function drawSlots(s){
  document.getElementById("slotHint").textContent = s.loadLabel + "digit puts the slot's macro in the player. " + s.runLabel + "digit runs it. Drag a row, or use the arrows, to reorder.";
  var h = "";
  s.slots.forEach(function(r, i){
    var name = r.name ? esc(r.name) : "empty";
    var cls = "name" + (r.name ? "" : " empty") + (r.missing ? " missing" : "");
    var inP = r.name && r.name === s.current;
    h += '<div class="slot" draggable="true" data-slot="' + r.slot + '">'
      + '<span class="grip" title="drag to reorder">⋮⋮</span>'
      + '<div class="digit">' + r.slot + '</div>'
      + '<div class="body"><div class="' + cls + '">' + name + (r.missing ? ' · not in the folder' : '') + (inP ? ' · in the player' : '') + '</div>'
      + '<div class="chords"><b>' + esc(s.loadLabel) + r.slot + '</b> loads · <b>' + esc(s.runLabel) + r.slot + '</b> runs</div></div>'
      + '<div class="acts">'
      + '<button class="icon" data-a="runslot" data-slot="' + r.slot + '" title="run now"' + (r.name && !r.missing ? '' : ' disabled') + '>▶</button>'
      + '<button class="icon" data-a="up" data-slot="' + r.slot + '" title="move up"' + (i > 0 ? '' : ' disabled') + '>▲</button>'
      + '<button class="icon" data-a="down" data-slot="' + r.slot + '" title="move down"' + (i < 9 ? '' : ' disabled') + '>▼</button>'
      + '<button class="icon" data-a="clear" data-slot="' + r.slot + '" title="empty this slot"' + (r.name ? '' : ' disabled') + '>×</button>'
      + '</div></div>';
  });
  document.getElementById("slots").innerHTML = h;
}

function drawMacros(s){
  var box = document.getElementById("macros");
  if (!s.macros.length) { box.innerHTML = '<div class="hint">No macros yet. Name one above and press New macro.</div>'; return; }
  var taken = {}; s.slots.forEach(function(r){ if (r.name) taken[r.slot] = r.name; });
  var h = "";
  s.macros.forEach(function(m, i){
    h += '<div class="macro" data-i="' + i + '"><div class="top">'
      + '<div class="name" data-a="edit" data-i="' + i + '" title="click to rename">' + esc(m.name) + '</div>'
      + (m.inPlayer ? '<span class="tag">in the player</span>' : '')
      + '<span class="kind">' + (m.kind === 'script' ? 'script' : 'recording') + '</span>'
      + '<a class="btn icon" href="/editor?name=' + encodeURIComponent(m.name) + '&v=' + s.build + '" title="open in the script editor">Edit</a>'
      + '<button class="icon danger" data-a="trash" data-i="' + i + '" title="move to the trash folder">' + (armed[m.name] ? 'sure?' : '🗑') + '</button>'
      + '</div>'
      + '<div class="meta' + (m.bad ? ' bad' : '') + '">' + (m.bad ? 'cannot be read' : ((m.kind === 'script' ? m.lines + ' lines' : m.events + ' events') + (m.recorded ? ' · recorded ' + esc(m.recorded) : ''))) + '</div>'
      + '<div class="checks"><span class="lbl">slot</span>';
    s.slots.forEach(function(r){
      var on = m.slot === r.slot;
      var other = !on && taken[r.slot];
      h += '<span class="chk' + (on ? ' on' : '') + (other ? ' taken' : '') + '" data-a="tick" data-i="' + i + '" data-slot="' + r.slot + '" title="'
         + (on ? 'take it out of slot ' + r.slot : (other ? 'slot ' + r.slot + ' has ' + esc(other) + ', replace it' : 'put it in slot ' + r.slot)) + '">' + r.slot + '</span>';
    });
    h += '</div></div>';
  });
  box.innerHTML = h;
}

function modChips(id, mods, which){
  var have = {}; mods.forEach(function(m){ have[m] = true; });
  var h = "";
  [["ctrl","⌃"],["alt","⌥"],["shift","⇧"],["cmd","⌘"]].forEach(function(p){
    h += '<span class="chk' + (have[p[0]] ? ' on' : '') + '" data-a="mod" data-which="' + which + '" data-mod="' + p[0] + '">' + p[1] + '</span>';
  });
  document.getElementById(id).innerHTML = h;
}

function drawKeys(s){
  var h = "";
  s.actions.forEach(function(a){
    var waiting = s.capture === a.id;
    h += '<div class="krow"><div class="what">' + esc(a.label) + '</div>'
      + '<span class="cap' + (waiting ? ' wait' : '') + '">' + (waiting ? 'press keys…' : esc(a.keyLabel)) + '</span>'
      + '<button data-a="capture" data-id="' + a.id + '"' + (s.capture ? ' disabled' : '') + '>Change</button></div>';
  });
  document.getElementById("keys").innerHTML = h;
  modChips("loadMods", s.loadMods, "loadMods");
  modChips("runMods", s.runMods, "runMods");
}

function drawImages(s){
  var box = document.getElementById("images");
  if (!s.images.length) { box.innerHTML = '<div class="hint">No pictures yet.</div>'; return; }
  var h = "";
  s.images.forEach(function(n){
    h += '<div class="pic"><img src="/image?name=' + encodeURIComponent(n) + '&v=' + s.build + '" alt="">'
      + '<div class="name" title="' + esc(n) + '">' + esc(n) + '</div>'
      + '<button class="icon" data-a="findtest" data-name="' + esc(n) + '" title="find it on the screen now and move the mouse there">find</button>'
      + '<button class="icon danger" data-a="trashimage" data-name="' + esc(n) + '" title="move to the trash folder">' + (armed["img:" + n] ? 'sure?' : '🗑') + '</button></div>';
  });
  box.innerHTML = h;
}

function drawPlayback(s){
  var h = "";
  s.speeds.forEach(function(v){ h += '<span class="chip' + (v === s.speed ? ' on' : '') + '" data-a="speed" data-v="' + v + '">' + v + 'x</span>'; });
  document.getElementById("speeds").innerHTML = h;
  h = "";
  s.delays.forEach(function(v){ h += '<span class="chip' + (v === s.clickDelay ? ' on' : '') + '" data-a="delay" data-v="' + v + '">' + (v === 0 ? 'as recorded' : v + ' s') + '</span>'; });
  document.getElementById("delays").innerHTML = h;
  document.getElementById("swAuto").className = "sw" + (s.autoSmall ? " on" : "");
  document.getElementById("swTop").className = "sw" + (s.onTop ? " on" : "");
  document.getElementById("swLan").className = "sw" + (s.lan ? " on" : "");
  document.getElementById("addr").textContent = s.lan ? ("on the phone: " + s.url) : s.localUrl;
  document.getElementById("folder").textContent = s.folder;
}

function draw(s){
  drawLcd(s);
  if (editing !== null) return;      // a rename in progress is not redrawn under the cursor
  drawSlots(s); drawMacros(s); drawImages(s); drawKeys(s); drawPlayback(s);
}

// BUILD CHECK: a tab from yesterday running yesterday's javascript reloads itself.
function poll(){
  fetch("/state", {cache:"no-store"}).then(function(r){ return r.text(); }).then(function(txt){
    var s = JSON.parse(txt);
    if (BUILD === null) BUILD = s.build;
    else if (s.build !== BUILD) { location.reload(); return; }
    S = s;
    if (txt === lastTxt && editing === null) { drawLcd(s); return; }
    lastTxt = txt;
    draw(s);
  }).catch(function(){
    var el = document.getElementById("lcd"); el.className = "lcd"; el.textContent = "the recorder is not answering. Is Macro Recorder ticked in the star menu?";
  });
}

// RENAME IN PLACE: the name becomes a box; Enter renames, Escape or leaving cancels.
function startEdit(i){
  if (editing !== null || !S) return;
  var m = S.macros[i]; if (!m) return;
  editing = m.name;
  var el = document.querySelector('.macro[data-i="' + i + '"] .name');
  el.innerHTML = '<input type="text" value="' + esc(m.name) + '">';
  var inp = el.firstChild; inp.focus(); inp.select();
  var finish = function(save){
    var v = inp.value; editing = null;
    if (save && v.trim() && v !== m.name) send({a:"rename", old:m.name, "new":v}); else { lastTxt = ""; poll(); }
  };
  inp.onkeydown = function(e){ if (e.key === "Enter") finish(true); else if (e.key === "Escape") finish(false); };
  inp.onblur = function(){ if (editing !== null) finish(false); };
}

document.body.addEventListener("click", function(e){
  var t = e.target.closest("[data-a]"); if (!t || t.disabled) return;
  var a = t.dataset.a;
  if (a === "edit") { startEdit(+t.dataset.i); return; }
  if (a === "tick") {
    var m = S.macros[+t.dataset.i]; if (!m) return;
    if (m.slot === t.dataset.slot) send({a:"clear", slot:t.dataset.slot});
    else send({a:"assign", slot:t.dataset.slot, name:m.name});
    return;
  }
  if (a === "trash") {
    var mm = S.macros[+t.dataset.i]; if (!mm) return;
    if (armed[mm.name]) { delete armed[mm.name]; send({a:"trash", name:mm.name}); }
    else { armed[mm.name] = true; t.textContent = "sure?"; setTimeout(function(){ delete armed[mm.name]; lastTxt = ""; poll(); }, 3000); }
    return;
  }
  if (a === "mod") {
    var which = t.dataset.which, cur = (which === "loadMods" ? S.loadMods : S.runMods).slice();
    var idx = cur.indexOf(t.dataset.mod);
    if (idx >= 0) cur.splice(idx, 1); else cur.push(t.dataset.mod);
    send({a:"mods", which:which, mods:cur});
    return;
  }
  if (a === "capture") { send({a:"capture", id:t.dataset.id}); return; }
  if (a === "findtest") { send({a:"findtest", name:t.dataset.name}); return; }
  if (a === "trashimage") {
    var key = "img:" + t.dataset.name;
    if (armed[key]) { delete armed[key]; send({a:"trashimage", name:t.dataset.name}); }
    else { armed[key] = true; t.textContent = "sure?"; setTimeout(function(){ delete armed[key]; lastTxt = ""; poll(); }, 3000); }
    return;
  }
  if (a === "speed" || a === "delay") { send({a:a, v:+t.dataset.v}); return; }
  if (a === "runslot" || a === "up" || a === "down" || a === "clear") { send({a:a, slot:t.dataset.slot}); return; }
});

document.getElementById("kRec").onclick = function(){ send({a:"record"}); };
document.getElementById("kPlay").onclick = function(){ send({a:"play"}); };
document.getElementById("kStop").onclick = function(){ send({a:"stop"}); };
document.getElementById("kNew").onclick = function(){
  var inp = document.getElementById("newName");
  send({a:"new", name: inp.value}); inp.value = ""; delete inp.dataset.touched;
};
document.getElementById("kWrite").onclick = function(){
  var inp = document.getElementById("newName");
  fetch("/do", {method:"POST", body: JSON.stringify({a:"newscript", name: inp.value}), cache:"no-store"}).then(function(r){ return r.json(); }).then(function(d){
    if (d.ok && d.name) { inp.value = ""; location.href = "/editor?name=" + encodeURIComponent(d.name) + "&v=" + (S ? S.build : 0); }
    else { lastTxt = ""; poll(); }
  }).catch(function(){});
};
document.getElementById("kSnap").onclick = function(){
  var inp = document.getElementById("snapName");
  send({a:"snap", name: inp.value}); inp.value = "";
};
document.getElementById("newName").oninput = function(){ this.dataset.touched = "1"; };
document.getElementById("newName").onkeydown = function(e){ if (e.key === "Enter") document.getElementById("kNew").onclick(); };
document.getElementById("kReset").onclick = function(){ send({a:"resetkeys"}); };
document.getElementById("swAuto").onclick = function(){ send({a:"autosmall"}); };
document.getElementById("swTop").onclick = function(){ send({a:"ontop"}); };
document.getElementById("swLan").onclick = function(){ send({a:"lan"}); };
document.getElementById("kBig").onclick = function(){ send({a:"big"}); };
document.getElementById("kFolder").onclick = function(){ send({a:"folder"}); };

// DRAG TO REORDER. Dropping row A on row B moves A to B's place; the rows
// between shift by one. The same move the arrows make, one step at a time.
var slotsBox = document.getElementById("slots");
slotsBox.addEventListener("dragstart", function(e){
  var r = e.target.closest(".slot"); if (!r) return;
  dragFrom = r.dataset.slot; e.dataTransfer.effectAllowed = "move";
  try { e.dataTransfer.setData("text/plain", dragFrom); } catch(x){}
});
slotsBox.addEventListener("dragover", function(e){
  var r = e.target.closest(".slot"); if (!r) return;
  e.preventDefault(); e.dataTransfer.dropEffect = "move";
  Array.prototype.forEach.call(slotsBox.querySelectorAll(".slot.over"), function(x){ x.classList.remove("over"); });
  r.classList.add("over");
});
slotsBox.addEventListener("dragleave", function(e){ var r = e.target.closest(".slot"); if (r) r.classList.remove("over"); });
slotsBox.addEventListener("drop", function(e){
  var r = e.target.closest(".slot"); if (!r || dragFrom === null) return;
  e.preventDefault();
  var to = r.dataset.slot, from = dragFrom; dragFrom = null;
  if (from !== to) send({a:"move", from:from, to:to});
});
slotsBox.addEventListener("dragend", function(){
  dragFrom = null;
  Array.prototype.forEach.call(slotsBox.querySelectorAll(".slot.over"), function(x){ x.classList.remove("over"); });
});

if (location.search.indexOf("mini") >= 0) { document.body.className = "mini"; }
poll();
setInterval(poll, 1000);
</script>
</body>
</html>
]==]

-- THE STAMP, from the page text itself, so a tab running an older page sees
-- it change and reloads. Right by construction; nothing to remember.
local function stampOf(text)
    local h = 5381
    for i = 1, #text do h = (h * 33 + text:byte(i)) % 4294967296 end
    return h
end
P.build = stampOf(PAGE)

------------------------------------------------------------------ the server

local function reply(body, code, ctype)
    return body, code or 200, { ["Content-Type"] = ctype or "application/json",
                                ["Cache-Control"] = "no-store" }
end

local function query(path, key)
    local v = path:match("[?&]" .. key .. "=([^&]*)")
    if not v then return nil end
    v = v:gsub("+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
    return v
end

local function readDocs()
    local f = io.open(HERE .. "docs/SCRIPT.md", "r")
    if not f then return "# MANTRA SCRIPT\n\ndocs/SCRIPT.md is missing." end
    local t = f:read("a"); f:close()
    return t
end

local function commandsJson()
    local cmds = {}
    for _, c in ipairs(SCRIPT.COMMANDS) do
        local isFunction = c.sig:match("^" .. c.name .. "%(") ~= nil
        cmds[#cmds + 1] = { name = c.name, sig = c.sig, doc = c.doc, isFunction = isFunction, snippet = c.sig }
    end
    return { commands = cmds, variables = SCRIPT.VARIABLES, keys = SCRIPT.KEYNAMES, images = M.listImages() }
end

local function handle(method, path, headers, body)
    if path:sub(1, 7) == "/editor" then
        return reply(EDITOR.EDITOR, 200, "text/html; charset=utf-8")
    end
    if path:sub(1, 5) == "/docs" then
        return reply(EDITOR.renderDocs(readDocs(), "MANTRA SCRIPT, the language"), 200, "text/html; charset=utf-8")
    end
    if path:sub(1, 7) == "/script" then
        local name = query(path, "name") or ""
        local text, kind = M.readScript(name)
        local okE, txt = pcall(hs.json.encode, text and { name = name, text = text, kind = kind } or { name = name, error = kind })
        return reply(okE and txt or '{"error":"cannot encode"}')
    end
    if path:sub(1, 9) == "/commands" then
        local okE, txt = pcall(hs.json.encode, commandsJson())
        return reply(okE and txt or '{"commands":[],"variables":[],"keys":[],"images":[]}')
    end
    if path:sub(1, 7) == "/images" then
        local okE, txt = pcall(hs.json.encode, { images = M.listImages() })
        return reply(okE and txt or '{"images":[]}')
    end
    if path:sub(1, 6) == "/image" then
        local name = query(path, "name") or ""
        if name:find("/", 1, true) or name:find("..", 1, true) then return reply("no", 404, "text/plain") end
        local f = io.open(M.imgDir .. "/" .. name, "rb")
        if not f then return reply("no such picture", 404, "text/plain") end
        local bytes = f:read("a"); f:close()
        return bytes, 200, { ["Content-Type"] = name:match("%.png$") and "image/png" or "image/jpeg", ["Cache-Control"] = "no-store" }
    end
    if path:sub(1, 6) == "/state" then
        local ok, txt = pcall(hs.json.encode, state())
        if not ok then return reply('{"error":' .. string.format("%q", tostring(txt)) .. '}', 500) end
        return reply(txt)
    end
    if path:sub(1, 3) == "/do" then
        local d = {}
        if body and #body > 0 then
            local ok, t = pcall(hs.json.decode, body)
            if ok and type(t) == "table" then d = t end
        end
        if not d.a then d.a = path:match("[?&]a=([%w]+)") end
        local ok, err, extra = act(d)
        local out = { ok = ok and true or false }
        if err and not ok then out.error = tostring(err) end
        for k, v in pairs(extra or {}) do out[k] = v end
        local okE, txt = pcall(hs.json.encode, out)
        return reply(okE and txt or '{"ok":false,"error":"cannot encode the reply"}')
    end
    if path:sub(1, 7) == "/health" then return reply("ok", 200, "text/plain") end
    return reply(PAGE, 200, "text/html; charset=utf-8")
end

-- ON THIS MAC ONLY BY DEFAULT. This page can press keys and click, so it is
-- not left open to the wifi unless he switches "reachable from the phone"
-- on. The server is rebuilt on that switch: the interface is set before
-- start and cannot be changed under a running one.
local function startServer()
    if P.server then pcall(function() P.server:stop() end); P.server = nil end
    local srv = hs.httpserver.new(false, false)
    srv:setPort(PORT)
    if not M.settings.lan then srv:setInterface("localhost") end
    srv:setCallback(handle)
    local ok = pcall(function() srv:start() end)
    if not ok then M.say("the settings page could not take port " .. PORT, GREY, 4); return false end
    P.server = srv
    return true
end

-- THE ADDRESS CARRIES THE STAMP, so a browser cannot hand back an old page.
function P.url()
    local host = "127.0.0.1"
    if M.settings.lan then
        for _, a in ipairs(hs.host.addresses() or {}) do
            if a:match("^%d+%.%d+%.%d+%.%d+$") and a ~= "127.0.0.1" then host = a break end
        end
    end
    local q = "/?v=" .. P.build
    return "http://" .. host .. ":" .. PORT .. q, "http://127.0.0.1:" .. PORT .. q
end

------------------------------------------------------------------ the small window

local WIN = { w = 380, h = 680, pad = 16 }
local FRAME_KEY = "mantra_macro.miniFrame"

local function rememberedFrame()
    local f = hs.settings.get(FRAME_KEY)
    if type(f) ~= "table" or not (f.x and f.y and f.w and f.h) then return nil end
    if f.w < 240 or f.h < 240 then return nil end
    for _, s in ipairs(hs.screen.allScreens()) do
        local sf = s:frame()
        if f.x >= sf.x - 40 and f.y >= sf.y - 40
           and f.x + f.w <= sf.x + sf.w + 40 and f.y + f.h <= sf.y + sf.h + 40 then
            return f
        end
    end
    return nil
end

local function level()
    return M.settings.onTop and hs.drawing.windowLevels.floating or hs.drawing.windowLevels.normal
end

function P.small()
    if P.win then P.win:show():bringToFront(); return end
    local scr = hs.screen.mainScreen():frame()
    local f = rememberedFrame()
            or { x = scr.x + scr.w - WIN.w - WIN.pad, y = scr.y + WIN.pad, w = WIN.w, h = WIN.h }
    local _, localUrl = P.url()
    P.win = hs.webview.new(f)
        :windowStyle({ "titled", "closable", "resizable" })
        :level(level())
        :allowTextEntry(true)          -- the rename box and the new macro's name
        :shadow(true)
        :deleteOnClose(true)
        :windowTitle("Macro Recorder")
        :url(localUrl .. "&mini")
    P.win:windowCallback(function(action, wv)
        if action == "closing" then
            P.win = nil
        elseif action == "frameChange" and wv then
            local ok, fr = pcall(function() return wv:frame() end)
            if ok and fr and fr.w and fr.w >= 240 then
                hs.settings.set(FRAME_KEY, { x = fr.x, y = fr.y, w = fr.w, h = fr.h })
            end
        end
    end)
    P.win:show():bringToFront()
    P.win:level(level())        -- set again after show, or it comes up floating regardless
end

function P.closeSmall()
    if P.win then pcall(function() P.win:delete() end); P.win = nil end
end

function P.toggleSmall()
    if P.win then P.closeSmall() else P.small() end
end

function P.big()
    local _, localUrl = P.url()
    hs.urlevent.openURL(localUrl)
end

-- THE EDITOR opens in the browser: a script wants room and a real keyboard.
function P.editor(name)
    local enc = (name or ""):gsub("[^%w%-%._~ ]", function(c) return string.format("%%%02X", c:byte()) end):gsub(" ", "%%20")
    hs.urlevent.openURL("http://127.0.0.1:" .. PORT .. "/editor?name=" .. enc .. "&v=" .. P.build)
end

function P.docs()
    hs.urlevent.openURL("http://127.0.0.1:" .. PORT .. "/docs?v=" .. P.build)
end

function P.toggleAutoSmall()
    M.settings.autoSmall = not M.settings.autoSmall
    M.saveSettings()
    return M.settings.autoSmall
end

function P.toggleOnTop()
    M.settings.onTop = not M.settings.onTop
    M.saveSettings()
    if P.win then pcall(function() P.win:level(level()) end) end
    return M.settings.onTop
end

function P.toggleLan()
    M.settings.lan = not M.settings.lan
    M.saveSettings()
    startServer()
    return M.settings.lan
end

function P.stop()
    P.closeSmall()
    if P.opener then P.opener:stop(); P.opener = nil end
    if P.server then pcall(function() P.server:stop() end); P.server = nil end
end

startServer()
if M.settings.autoSmall then
    -- a beat later, so the server above is answering when the webview asks
    P.opener = hs.timer.doAfter(0.8, function() pcall(P.small) end)
end

P._test = { state = state, act = act, page = PAGE, stampOf = stampOf }
return P

end
