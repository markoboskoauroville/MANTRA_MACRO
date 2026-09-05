-- editor_page.lua
--
-- THE SCRIPT EDITOR, a web app. Marko's request, 5.9.2026: "a full-fledged
-- code editor so while I'm starting to type, it suggests me the next command.
-- Finishing the sentence is for me. And a documentation of the language."
--
-- ONE PAGE, served by the recorder's own server at /editor?name=<macro>. The
-- editor is CodeMirror 5, fetched from cdnjs; if that cannot load (no
-- internet) the plain text box underneath still edits and saves, and the
-- command panel on the right still inserts, so nothing is lost offline.
--
-- THE SUGGESTIONS know the language from /commands, which the server builds
-- from script.lua's own command list, so the editor and the interpreter can
-- never disagree about what exists. At the start of a line the commands are
-- offered, the likely next one first (after a Click comes a Sleep, after a
-- Sleep a Send or a Click, after a WaitImage a Click...). Inside {braces} in
-- a string the key names are offered. Inside quotes after an image command
-- the pictures in the folder are offered. Elsewhere, functions, variables
-- and the names this script has assigned.
--
-- /docs renders docs/SCRIPT.md, the language documentation, with a small
-- Markdown reader written here so it works with nothing else installed.

local E = {}

E.EDITOR = [==[
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Script Editor</title>
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.16/codemirror.min.css">
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.16/addon/hint/show-hint.min.css">
<style>
  :root{ --black:#0B0D10; --panel:#141A21; --slate:#23303D; --line:#2a3542; --sand:#F2DDB4;
    --amber:#F59E0B; --dim:#6E7681; --red:#F04E4E; --green:#4FD98A; }
  *{box-sizing:border-box;margin:0;padding:0}
  html,body{height:100%;background:var(--black);color:var(--sand);
    font:14px/1.45 ui-sans-serif,-apple-system,"Helvetica Neue",Arial,sans-serif}
  body{display:flex;flex-direction:column;height:100vh}
  header{display:flex;align-items:center;gap:8px;padding:8px 12px;background:var(--panel);
    border-bottom:1px solid var(--line);flex-wrap:wrap}
  header h1{font-size:11px;letter-spacing:.22em;text-transform:uppercase;color:var(--dim);margin-right:6px}
  header .name{font-weight:600;font-size:15px;margin-right:auto;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:40vw}
  button,a.btn{font:inherit;color:var(--sand);background:var(--slate);border:0;border-radius:8px;padding:7px 12px;
    cursor:pointer;text-decoration:none;box-shadow:inset 0 1px 0 rgba(255,255,255,.08),inset 0 -2px 0 rgba(0,0,0,.35)}
  button:hover,a.btn:hover{background:#2c3b4a}
  button:disabled{opacity:.35;cursor:default}
  button.primary{background:var(--amber);color:#111;font-weight:600}
  button.primary:hover{background:#ffb02e}
  main{flex:1;display:flex;min-height:0}
  #editorBox{flex:1;min-width:0;display:flex;flex-direction:column}
  .CodeMirror{flex:1;height:auto;font:14px/1.5 ui-monospace,Menlo,Monaco,monospace;background:#0a0d11;color:#e6d8b8}
  .CodeMirror-gutters{background:#0e1216;border-right:1px solid var(--line)}
  .CodeMirror-linenumber{color:#4a5563}
  .CodeMirror-activeline-background{background:rgba(245,158,11,.06)}
  .cm-s-default .cm-comment{color:#6E7681;font-style:italic}
  .cm-s-default .cm-string{color:#9ad0a0}
  .cm-s-default .cm-number{color:#f2c46d}
  .cm-s-default .cm-keyword{color:#f59e0b;font-weight:600}
  .cm-s-default .cm-builtin{color:#7fc7ff}
  .cm-s-default .cm-variable-2{color:#d7a3ff}
  .cm-s-default .cm-def{color:#ffd166}
  .cm-s-default .cm-bracket{color:#f2ddb4}
  .cm-s-default .cm-key{color:#ffb4b4}
  .CodeMirror-hints{background:#141A21;border:1px solid var(--line);color:var(--sand);font:13px ui-monospace,Menlo,monospace;
    box-shadow:0 8px 24px rgba(0,0,0,.5);max-height:22em}
  .CodeMirror-hint{color:var(--sand);padding:3px 8px}
  li.CodeMirror-hint-active{background:var(--amber);color:#111}
  .CodeMirror-hint .sig{color:var(--dim);margin-left:8px;font-size:12px}
  li.CodeMirror-hint-active .sig{color:#333}
  .errline{background:rgba(240,78,78,.18)}
  textarea#plain{flex:1;width:100%;background:#0a0d11;color:#e6d8b8;border:0;padding:10px;
    font:14px/1.5 ui-monospace,Menlo,monospace;resize:none;outline:none}
  aside{width:300px;flex:0 0 300px;background:var(--panel);border-left:1px solid var(--line);
    display:flex;flex-direction:column;min-height:0}
  aside .search{padding:8px}
  aside input{width:100%;font:inherit;color:var(--sand);background:#0a0d11;border:1px solid var(--line);border-radius:8px;padding:7px 10px}
  aside .list{flex:1;overflow:auto;padding:0 8px 8px}
  .cmd{padding:6px 8px;border-radius:8px;cursor:pointer;border:1px solid transparent}
  .cmd:hover{background:var(--slate)}
  .cmd .n{font:600 13px ui-monospace,Menlo,monospace;color:#7fc7ff}
  .cmd .s{font:12px ui-monospace,Menlo,monospace;color:var(--sand);opacity:.9}
  .cmd .d{font-size:12px;color:var(--dim);margin-top:2px}
  .grp{font-size:10px;letter-spacing:.2em;text-transform:uppercase;color:var(--dim);padding:10px 8px 4px}
  footer{display:flex;align-items:center;gap:10px;padding:6px 12px;background:var(--panel);border-top:1px solid var(--line);
    font:12px ui-monospace,Menlo,monospace;color:var(--dim);min-height:32px}
  footer .lcd{flex:1;color:var(--amber);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  footer .lcd.bad{color:var(--red)}
  footer .lcd.good{color:var(--green)}
  @media (max-width:760px){ aside{display:none} header .name{max-width:30vw} }
</style>
</head>
<body>
<header>
  <h1>Script Editor</h1>
  <div class="name" id="name">…</div>
  <button id="bSave" class="primary" title="⌘S">Save</button>
  <button id="bRun" title="⌘↩ saves and runs">Save &amp; Run</button>
  <button id="bStop">Stop</button>
  <button id="bCheck">Check</button>
  <button id="bSnap" title="drag over a button on the screen">Snap a picture</button>
  <a class="btn" href="/docs" target="_blank">Docs</a>
  <a class="btn" id="back" href="/">Settings</a>
</header>
<main>
  <div id="editorBox"><textarea id="plain" spellcheck="false" placeholder="; type a command, or pick one on the right"></textarea></div>
  <aside>
    <div class="search"><input id="q" type="text" placeholder="find a command"></div>
    <div class="list" id="list"></div>
  </aside>
</main>
<footer><div class="lcd" id="lcd">loading…</div><div id="pos"></div></footer>

<script src="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.16/codemirror.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.16/addon/hint/show-hint.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.16/addon/edit/matchbrackets.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.16/addon/edit/closebrackets.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/codemirror/5.65.16/addon/selection/active-line.min.js"></script>
<script>
var NAME = decodeURIComponent((location.search.match(/[?&]name=([^&]*)/) || [0, ""])[1]);
var LANG = { commands: [], variables: [], keys: [], images: [] };
var cm = null, dirty = false, errMark = null, lastState = "";
var plain = document.getElementById("plain");
var lcd = document.getElementById("lcd");

function esc(s){ return String(s == null ? "" : s).replace(/[&<>"']/g, function(c){ return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]; }); }
function say(text, cls){ lcd.textContent = text; lcd.className = "lcd" + (cls ? " " + cls : ""); }
function getText(){ return cm ? cm.getValue() : plain.value; }
function setText(t){ if (cm) cm.setValue(t); else plain.value = t; dirty = false; }
function post(d){ return fetch("/do", {method:"POST", body: JSON.stringify(d), cache:"no-store"}).then(function(r){ return r.json(); }); }

// WHAT COMES NEXT. After a click one waits; after a wait one clicks or types;
// after a WaitImage one clicks. The likely next commands come first in the list.
var NEXT = {
  click: ["Sleep", "Send", "Click", "ClickImage", "WaitImage"],
  mouseclick: ["Sleep", "Send", "Click"],
  mouseclickdrag: ["Sleep", "Click", "Send"],
  mousemove: ["Click", "Sleep", "Send"],
  sleep: ["Click", "Send", "ClickImage", "WaitImage", "Sleep"],
  send: ["Sleep", "Send", "Click", "ClickImage"],
  sendtext: ["Sleep", "Send", "Click"],
  waitimage: ["ClickImage", "Click", "Send", "Sleep"],
  clickimage: ["Sleep", "WaitImage", "Send", "Click"],
  winactivate: ["Sleep", "WinWaitActive", "Click", "Send"],
  winwaitactive: ["Click", "Send", "Sleep"],
  run: ["Sleep", "WinWaitActive", "WinActivate"],
  loop: ["Sleep", "ClickImage", "If", "Break"],
  "while": ["Sleep", "Click", "Send"],
  "if": ["Click", "Send", "MsgBox", "Break", "Return"],
  msgbox: ["Sleep", "Click", "ExitApp"],
  "": ["Click", "Send", "Sleep", "ClickImage", "WaitImage", "MouseMove", "Loop", "If", "WinActivate", "MsgBox"]
};

function prevCommand(lineNo){
  for (var i = lineNo - 1; i >= 0; i--) {
    var l = (cm ? cm.getLine(i) : plain.value.split("\n")[i]) || "";
    var m = l.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)/);
    if (m && !/^\s*;/.test(l)) return m[1].toLowerCase();
    if (l.trim() === "}") return "";
  }
  return "";
}

function rankedCommands(prev){
  var first = NEXT[prev] || NEXT[""];
  var seen = {}, out = [];
  first.forEach(function(n){ LANG.commands.forEach(function(c){ if (c.name.toLowerCase() === n.toLowerCase() && !seen[c.name]) { seen[c.name] = 1; out.push(c); } }); });
  LANG.commands.forEach(function(c){ if (!seen[c.name]) { seen[c.name] = 1; out.push(c); } });
  return out;
}

function userNames(){
  var names = {}, t = getText(), re = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?::=|\+=|-=|\.=|\+\+|--)/gm, m;
  while ((m = re.exec(t))) names[m[1]] = 1;
  re = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\([^)]*\)\s*\{/gm;
  while ((m = re.exec(t))) names[m[1]] = 1;
  return Object.keys(names);
}

// THE SUGGESTIONS for CodeMirror's show-hint.
function hint(editor){
  var cur = editor.getCursor(), line = editor.getLine(cur.line), before = line.slice(0, cur.ch);
  var word = (before.match(/[A-Za-z_][A-Za-z0-9_]*$/) || [""])[0];
  var start = cur.ch - word.length, list = [];
  var inBrace = /\{[^}]*$/.test(before) && (before.split('"').length - 1) % 2 === 1;
  var inImageString = /(ImageSearch|ClickImage|WaitImage|FindImage|ImageExist)[^"]*"[^"]*$/i.test(before);
  var atStart = /^\s*[A-Za-z_]*$/.test(before);
  function item(text, disp, sig, doc){
    return { text: text, displayText: disp, sig: sig || "", doc: doc || "",
      render: function(el, self, data){ el.innerHTML = esc(data.displayText) + (data.sig ? '<span class="sig">' + esc(data.sig) + '</span>' : ''); } };
  }
  var lw = word.toLowerCase();
  if (inImageString) {
    var q = (before.match(/"([^"]*)$/) || [0, ""])[1];
    start = cur.ch - q.length;
    LANG.images.forEach(function(n){ if (n.toLowerCase().indexOf(q.toLowerCase()) === 0) list.push(item(n, n, "picture", "")); });
  } else if (inBrace) {
    var q2 = (before.match(/\{([^}]*)$/) || [0, ""])[1];
    start = cur.ch - q2.length;
    LANG.keys.forEach(function(k){ if (k.toLowerCase().indexOf(q2.toLowerCase()) === 0) list.push(item(k + "}", "{" + k + "}", "", "")); });
  } else if (atStart) {
    rankedCommands(prevCommand(cur.line)).forEach(function(c){
      if (c.name.toLowerCase().indexOf(lw) === 0) list.push(item(c.snippet || (c.name + " "), c.name, c.sig, c.doc));
    });
  } else {
    LANG.commands.forEach(function(c){ if (c.isFunction && c.name.toLowerCase().indexOf(lw) === 0) list.push(item(c.name + "(", c.name, c.sig, c.doc)); });
    LANG.variables.forEach(function(v){ if (v.name.toLowerCase().indexOf(lw) === 0) list.push(item(v.name, v.name, v.doc, "")); });
    userNames().forEach(function(n){ if (n.toLowerCase().indexOf(lw) === 0 && n.toLowerCase() !== lw) list.push(item(n, n, "yours", "")); });
  }
  if (word === "" && !inBrace && !inImageString && !atStart) list = [];
  return { list: list, from: CodeMirror.Pos(cur.line, start), to: CodeMirror.Pos(cur.line, cur.ch) };
}

// THE MODE: comments, strings with their {keys}, numbers, keywords, commands, A_ variables.
function defineMode(){
  var kw = /^(if|else|while|loop|for|in|break|continue|return|and|or|not|true|false|global|local|static|until)$/i;
  var cmds = {};
  LANG.commands.forEach(function(c){ cmds[c.name.toLowerCase()] = 1; });
  CodeMirror.defineMode("mantra", function(){
    return {
      startState: function(){ return { inStr: null }; },
      token: function(stream, state){
        if (state.inStr) {
          while (!stream.eol()) {
            var ch = stream.next();
            if (ch === "`") { stream.next(); continue; }
            if (ch === "{") { var rest = stream.string.slice(stream.pos); var j = rest.indexOf("}"); if (j >= 0) { stream.pos += j + 1; return "key"; } }
            if (ch === state.inStr) { if (stream.peek() === state.inStr) { stream.next(); continue; } state.inStr = null; return "string"; }
          }
          return "string";
        }
        if (stream.sol() && stream.match(/^\s*;.*/)) return "comment";
        if (stream.eatSpace()) return null;
        if (stream.match(/^;.*/)) return "comment";
        if (stream.match(/^\/\*.*?\*\//)) return "comment";
        var c = stream.peek();
        if (c === '"' || c === "'") { stream.next(); state.inStr = c; return "string"; }
        if (stream.match(/^#[A-Za-z]+/)) return "meta";
        if (stream.match(/^(0x[0-9a-fA-F]+|\d+\.?\d*(e[-+]?\d+)?)/)) return "number";
        if (stream.match(/^[A-Za-z_][A-Za-z0-9_]*/)) {
          var w = stream.current();
          if (kw.test(w)) return "keyword";
          if (/^A_/i.test(w)) return "variable-2";
          if (cmds[w.toLowerCase()]) return "builtin";
          if (stream.match(/^\s*\([^)]*\)\s*\{/, false)) return "def";
          return "variable";
        }
        if (stream.match(/^[{}()\[\]]/)) return "bracket";
        stream.next();
        return null;
      }
    };
  });
}

function setup(){
  if (!window.CodeMirror) { say("editor library did not load; the plain box works", "bad"); plain.addEventListener("input", function(){ dirty = true; }); return; }
  defineMode();
  cm = CodeMirror.fromTextArea(plain, {
    mode: "mantra", lineNumbers: true, indentUnit: 4, tabSize: 4, indentWithTabs: false,
    matchBrackets: true, autoCloseBrackets: true, styleActiveLine: true, lineWrapping: false,
    extraKeys: {
      "Ctrl-Space": function(c){ c.showHint({ hint: hint, completeSingle: false }); },
      "Cmd-S": function(){ save(); }, "Ctrl-S": function(){ save(); },
      "Cmd-Enter": function(){ saveAndRun(); }, "Ctrl-Enter": function(){ saveAndRun(); },
      "Tab": function(c){ if (c.somethingSelected()) c.indentSelection("add"); else c.replaceSelection("    ", "end"); }
    }
  });
  cm.on("change", function(){ dirty = true; clearErr(); });
  cm.on("inputRead", function(c, ch){
    if (ch.origin !== "+input") return;
    var t = ch.text[0];
    if (/[A-Za-z_{"]/.test(t) || t === "") c.showHint({ hint: hint, completeSingle: false });
  });
  cm.on("cursorActivity", function(c){ var p = c.getCursor(); document.getElementById("pos").textContent = (p.line + 1) + ":" + (p.ch + 1); });
}

function clearErr(){ if (cm && errMark != null) { cm.removeLineClass(errMark, "background", "errline"); errMark = null; } }
function showErr(line, msg){
  say(msg, "bad");
  if (cm && line > 0) { errMark = line - 1; cm.addLineClass(errMark, "background", "errline"); cm.scrollIntoView({line: errMark, ch: 0}, 100); }
}

function load(){
  return fetch("/script?name=" + encodeURIComponent(NAME), {cache:"no-store"}).then(function(r){ return r.json(); }).then(function(d){
    if (d.error) { say(d.error, "bad"); return; }
    document.getElementById("name").textContent = d.name + (d.kind === "recording" ? " · a recording, saved as a script when you save" : "");
    document.title = d.name + " · Script Editor";
    setText(d.text || "");
    say(d.kind === "recording" ? "this is a recording shown as a script. Save keeps it as a script." : "ready. Start typing: the next command is suggested. ⌘S saves, ⌘↩ saves and runs.");
  });
}

function save(){
  var text = getText();
  return post({a:"savescript", name: NAME, text: text}).then(function(d){
    if (d.ok) { dirty = false; clearErr(); say("saved " + NAME + (d.warning ? " · " + d.warning : ""), d.warning ? "bad" : "good"); }
    else showErr(d.line || 0, d.error || "could not save");
    return d;
  });
}
function saveAndRun(){
  save().then(function(d){ if (d && d.ok && !d.warning) post({a:"runscript", name: NAME}).then(function(r){ if (!r.ok) showErr(r.line || 0, r.error); else say("running " + NAME + "…", "good"); }); });
}
function check(){
  post({a:"check", text: getText()}).then(function(d){ if (d.ok) { clearErr(); say("no errors", "good"); } else showErr(d.line || 0, d.error); });
}

function insert(text){
  if (cm) {
    var cur = cm.getCursor(), line = cm.getLine(cur.line);
    var prefix = line.trim() === "" ? "" : "\n";
    cm.replaceRange(prefix + text, cur);
    cm.focus();
    var m = text.match(/^(\S+)\s/);
    if (m) { var l = cur.line + (prefix ? 1 : 0); cm.setCursor({line: l, ch: m[1].length + 1}); }
  } else {
    var s = plain.selectionStart; plain.value = plain.value.slice(0, s) + text + plain.value.slice(s); plain.focus();
  }
  dirty = true;
}

function drawList(q){
  q = (q || "").toLowerCase();
  var h = "";
  var groups = [["Mouse", /^(Click|MouseMove|MouseClick|MouseClickDrag|MouseGetPos)$/], ["Keys", /^(Send|SendText)$/], ["Time", /^Sleep$/],
                ["Pictures", /^(ImageSearch|ClickImage|WaitImage|FindImage|ImageExist|PixelGetColor)$/], ["Apps", /^(WinActivate|WinExist|WinWaitActive|Run|MsgBox|ToolTip|ExitApp)$/],
                ["Flow", /^(Loop|While|For|If|Break|Continue|Return|Global)$/], ["Text and numbers", /./]];
  var used = {};
  groups.forEach(function(g){
    var rows = LANG.commands.filter(function(c){ return !used[c.name] && g[1].test(c.name) && (c.name.toLowerCase().indexOf(q) >= 0 || c.doc.toLowerCase().indexOf(q) >= 0); });
    if (!rows.length) return;
    h += '<div class="grp">' + g[0] + '</div>';
    rows.forEach(function(c){ used[c.name] = 1; h += '<div class="cmd" data-snip="' + esc(c.snippet || c.sig) + '"><div class="n">' + esc(c.name) + '</div><div class="s">' + esc(c.sig) + '</div><div class="d">' + esc(c.doc) + '</div></div>'; });
  });
  if (LANG.images.length && ("picture".indexOf(q) >= 0 || q === "")) {
    h += '<div class="grp">Pictures in the folder</div>';
    LANG.images.forEach(function(n){ h += '<div class="cmd" data-snip="ClickImage &quot;' + esc(n) + '&quot;"><div class="n">' + esc(n) + '</div><div class="d">ClickImage / WaitImage this picture</div></div>'; });
  }
  document.getElementById("list").innerHTML = h;
}
document.getElementById("list").addEventListener("click", function(e){ var t = e.target.closest(".cmd"); if (t) insert(t.dataset.snip); });
document.getElementById("q").oninput = function(){ drawList(this.value); };
document.getElementById("bSave").onclick = save;
document.getElementById("bRun").onclick = saveAndRun;
document.getElementById("bCheck").onclick = check;
document.getElementById("bStop").onclick = function(){ post({a:"stop"}); say("stopped"); };
document.getElementById("bSnap").onclick = function(){
  var n = prompt ? null : null;
  post({a:"snap", name: ""}).then(function(d){ say(d.ok ? "drag over the button on the screen; the picture lands in the folder" : (d.error || "could not snap")); setTimeout(loadLang, 4000); setTimeout(loadLang, 12000); });
};
window.addEventListener("beforeunload", function(e){ if (dirty) { e.preventDefault(); e.returnValue = ""; } });
document.addEventListener("keydown", function(e){ if ((e.metaKey || e.ctrlKey) && e.key === "s") { e.preventDefault(); save(); } });

function loadLang(){
  return fetch("/commands", {cache:"no-store"}).then(function(r){ return r.json(); }).then(function(d){ LANG = d; drawList(document.getElementById("q").value); });
}

// the run status from the recorder, so an error at line N shows here while it runs
function poll(){
  fetch("/state", {cache:"no-store"}).then(function(r){ return r.json(); }).then(function(s){
    var key = (s.playing ? "p" : "-") + (s.lastError ? s.lastError.at + s.lastError.msg : "") + (s.note ? s.note.at : "");
    if (key === lastState) return;
    lastState = key;
    if (s.playing) say("running " + (s.current || "") + "…", "good");
    else if (s.lastError && s.lastError.name === NAME && (Date.now()/1000 - s.lastError.at) < 30) showErr(s.lastError.line || 0, s.lastError.msg);
    else if (s.note && (Date.now()/1000 - s.note.at) < 6 && !dirty) say(s.note.text);
  }).catch(function(){});
}

loadLang().then(function(){ setup(); return load(); }).catch(function(){ setup(); load(); });
setInterval(poll, 1500);
</script>
</body>
</html>
]==]

------------------------------------------------------------------ the documentation

local function escapeHtml(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function inline(s)
    s = escapeHtml(s)
    s = s:gsub("`([^`]+)`", "<code>%1</code>")
    s = s:gsub("%*%*([^*]+)%*%*", "<strong>%1</strong>")
    return s
end

-- A SMALL MARKDOWN READER: headings, fenced code, bullets, paragraphs, inline
-- code and bold. Enough for SCRIPT.md, and nothing to install.
function E.renderDocs(md, title)
    local out = {}
    local inCode, inList, para = false, false, {}
    local function flushPara()
        if #para > 0 then out[#out + 1] = "<p>" .. inline(table.concat(para, " ")) .. "</p>"; para = {} end
    end
    local function closeList() if inList then out[#out + 1] = "</ul>"; inList = false end end
    for line in (md .. "\n"):gmatch("([^\n]*)\n") do
        if inCode then
            if line:match("^```") then out[#out + 1] = "</code></pre>"; inCode = false
            else out[#out + 1] = escapeHtml(line) end
        elseif line:match("^```") then
            flushPara(); closeList()
            out[#out + 1] = "<pre><code>"; inCode = true
        elseif line:match("^#") then
            flushPara(); closeList()
            local hashes, text = line:match("^(#+)%s*(.*)$")
            local n = math.min(#hashes, 4)
            out[#out + 1] = string.format("<h%d>%s</h%d>", n, inline(text), n)
        elseif line:match("^%s*[-*]%s+") then
            flushPara()
            if not inList then out[#out + 1] = "<ul>"; inList = true end
            out[#out + 1] = "<li>" .. inline(line:gsub("^%s*[-*]%s+", "")) .. "</li>"
        elseif line:match("^%s*$") then
            flushPara(); closeList()
        else
            if inList and line:match("^%s%s+") then
                out[#out] = out[#out]:gsub("</li>$", "") .. " " .. inline(line:gsub("^%s+", "")) .. "</li>"
            else
                closeList()
                para[#para + 1] = line
            end
        end
    end
    flushPara(); closeList()
    if inCode then out[#out + 1] = "</code></pre>" end
    return [[<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>]] .. escapeHtml(title or "MANTRA SCRIPT") .. [[</title>
<style>
  :root{--black:#0B0D10;--panel:#141A21;--line:#2a3542;--sand:#F2DDB4;--amber:#F59E0B;--dim:#6E7681}
  *{box-sizing:border-box}
  body{margin:0;background:var(--black);color:var(--sand);font:16px/1.55 ui-sans-serif,-apple-system,"Helvetica Neue",Arial,sans-serif}
  main{max-width:760px;margin:0 auto;padding:24px 20px 80px}
  h1{font-size:26px;margin:0 0 6px;color:#fff} h2{font-size:18px;margin:30px 0 8px;color:var(--amber);letter-spacing:.02em}
  h3{font-size:15px;margin:20px 0 6px}
  p{margin:8px 0} ul{margin:6px 0 6px 22px;padding:0} li{margin:4px 0}
  code{font:13.5px ui-monospace,Menlo,monospace;background:#1a2129;padding:1px 5px;border-radius:4px;color:#e6d8b8}
  pre{background:#0a0d11;border:1px solid var(--line);border-radius:10px;padding:12px 14px;overflow-x:auto}
  pre code{background:none;padding:0;color:#9ad0a0}
  nav{display:flex;gap:10px;margin-bottom:18px}
  nav a{color:var(--sand);text-decoration:none;background:#23303D;padding:6px 12px;border-radius:8px;font-size:14px}
  strong{color:#fff}
</style></head><body><main>
<nav><a href="/">Settings</a><a href="javascript:history.back()">Back to the editor</a></nav>
]] .. table.concat(out, "\n") .. "\n</main></body></html>"
end

return E
