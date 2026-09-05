-- macro.lua
--
-- THE MACRO RECORDER. Marko's request, 4.9.2026: "It's very simple. It records
-- everything I'm doing and repeating. Control+Option+Command+R records,
-- Control+Option+Command+P plays. When it's checked, it works. It listens to my
-- keyboard and also plays back. In the settings I have speed, I can ignore the
-- traveling of the mouse, I can add a simple delay between clicks of the mouse,
-- and all the clicks are in the same rhythm."
--
-- And 5.9.2026: "Open macros folder is the top item. Settings as a web page,
-- small one and big one like the other apps. Custom keyboard shortcuts for
-- every action. Option 1 to 0 loads a stored macro into the player, Control 1
-- to 0 runs it. I assign any macro to any slot with check marks, rename them
-- here or on disk, and reorder the slots in the web interface."
--
-- WHAT IT IS. One eventtap that writes down keys, clicks, drags, scrolls and
-- mouse travel with the time between them; one player that posts them back in
-- the same order. It is started by the star menu and by nothing else, so it
-- listens only while its box is ticked.
--
-- A MACRO IS A SCRIPT, since 5.9.2026: AutoHotkey v2 syntax, read by
-- script.lua. A recording is written down as one (Click x, y · Sleep ms ·
-- Send "text") the moment it stops, so every macro can be read and edited.
--
-- THE FILES, all under ~/.mantra_macro:
--   settings.json          speed, clickDelay, the keys, the slots, the window
--   macros/<name>.ahk      the macros. Any name; rename on disk or on the page.
--   macros/<name>.json     a recording from before the language; still plays
--   images/<name>.png      the pictures ClickImage looks for on the screen
--   last.ahk               the plain last recording, what Play plays with no macro chosen
--   recordings/<date>.json the raw events of every recording ever made, kept
--   trash/                 whatever the page's bin removed, never deleted
--
-- THE PARTS of the code: this file (record, the host the language runs on,
-- keys, slots, the star's submenu), slots.lua (the ten slots, pure Lua),
-- script.lua (the language, pure Lua), settings_page.lua (the page, its
-- server, the small window), editor_page.lua (the script editor and the
-- documentation) and find.py (the eye: a picture found on a screen shot).
-- The page is loaded on start and let go on stop, like everything else.
--
-- THE STATUS goes small, bottom right of the screen, never mid screen: a red
-- dot with REC while recording, a green one with PLAY while playing, gone when
-- neither. His rule: never an overlay, never a fright.

local M = { name = "Macro Recorder", key = "macro" }

local HERE = debug.getinfo(1, "S").source:match("^@(.*/)") or
             ((os.getenv("HOME") or "") .. "/Developer/MANTRA_MACRO/")
local HOME = os.getenv("HOME") or ""
M.dir      = HOME .. "/.mantra_macro"
M.file     = M.dir .. "/last.json"
M.recDir   = M.dir .. "/recordings"
M.macDir   = M.dir .. "/macros"        -- the named ones
M.trashDir = M.dir .. "/trash"
M.setFile  = M.dir .. "/settings.json"

M.imgDir   = M.dir .. "/images"       -- the pictures ClickImage looks for
M.tmpDir   = M.dir .. "/tmp"          -- screen shots taken while searching
M.lastFile = M.dir .. "/last.ahk"     -- the plain last recording, as a script

local SLOTS  = dofile(HERE .. "slots.lua")
local SCRIPT = dofile(HERE .. "script.lua")
M.SLOTS, M.SCRIPT = SLOTS, SCRIPT
M.findPy = HERE .. "find.py"
local PYTHON = (function()
    local p = HOME .. "/.pyenv/versions/3.10.14/bin/python3"
    return hs.fs.attributes(p) and p or "python3"
end)()
M.text = nil          -- the script in the player
M.lastError = nil     -- { name=, line=, msg=, at= } from the last run that failed

------------------------------------------------------------------ the keys

-- EVERY ACTION HAS A KEY AND EVERY KEY CAN BE CHANGED, from the page. These are
-- the defaults; settings.json overrides them one by one, so a key added later
-- still has its default on an older file.
M.ACTIONS = {
    { id = "record",   label = "Record, and stop recording" },
    { id = "play",     label = "Play the macro in the player, and stop it" },
    { id = "stop",     label = "Stop whatever is running" },
    { id = "newMacro", label = "New macro: name it, then record" },
    { id = "settings", label = "Open the settings window" },
}
local DEFAULT_KEYS = {
    record   = { mods = { "ctrl", "alt", "cmd" }, key = "r" },
    play     = { mods = { "ctrl", "alt", "cmd" }, key = "p" },
    stop     = { mods = { "ctrl", "alt", "cmd" }, key = "." },
    newMacro = { mods = { "ctrl", "alt", "cmd" }, key = "n" },
    settings = { mods = { "ctrl", "alt", "cmd" }, key = "m" },
    loadMods = { "alt" },       -- ⌥1 .. ⌥0 put the slot's macro in the player
    runMods  = { "ctrl" },      -- ⌃1 .. ⌃0 run the slot's macro now
}

local function copy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = copy(v) end
    return out
end

M.settings = { speed = 1, ignoreTravel = false, clickDelay = 0,
               autoSmall = true, onTop = false, lan = false,
               keys = copy(DEFAULT_KEYS), slots = {}, zones = {} }

-- A SEARCH ZONE is a rectangle in absolute screen points where a picture is
-- looked for; no zone means every screen. Read from disk safely: only string
-- keys with four numbers survive.
local function normaliseZones(t)
    local out = {}
    if type(t) ~= "table" then return out end
    for k, v in pairs(t) do
        if type(k) == "string" and type(v) == "table"
           and type(v.x) == "number" and type(v.y) == "number"
           and type(v.w) == "number" and type(v.h) == "number" and v.w > 0 and v.h > 0 then
            out[k] = { x = v.x, y = v.y, w = v.w, h = v.h, screen = v.screen }
        end
    end
    return out
end
M.SPEEDS = { 0.5, 1, 2, 4, 8 }
M.DELAYS = { 0, 0.25, 0.5, 1, 2 }

M.events    = nil     -- the recording in memory, a list of {t=, kind=, ...}
M.current   = nil     -- the name of the macro in the player, nil for the plain last recording
M.pending   = nil     -- the name a New Macro recording will be saved under
M.recording = false
M.playing   = false
M.loaded    = false   -- the star's running()
M.capture   = nil     -- the action whose key is being captured, while it is
M.note      = nil     -- one line for the page and the badge: { text=, at= }
M.hotkeys   = {}

------------------------------------------------------------------ settings

local function loadSettings()
    M.settings.keys = copy(DEFAULT_KEYS)
    if not hs.fs.attributes(M.setFile) then return end    -- first run: the defaults
    local ok, s = pcall(hs.json.read, M.setFile)
    if ok and type(s) == "table" then
        for k, v in pairs(s) do
            if k == "keys" and type(v) == "table" then
                for id, b in pairs(v) do
                    if DEFAULT_KEYS[id] ~= nil then M.settings.keys[id] = copy(b) end
                end
            elseif k == "slots" then
                M.settings.slots = SLOTS.normalise(v)
            elseif k == "zones" then
                M.settings.zones = normaliseZones(v)
            else
                M.settings[k] = v
            end
        end
    end
    M.settings.slots = SLOTS.normalise(M.settings.slots)
    M.settings.zones = normaliseZones(M.settings.zones)
end

function M.saveSettings()
    hs.fs.mkdir(M.dir)
    pcall(hs.json.write, M.settings, M.setFile, true, true)
end

function M.setSpeed(v)      M.settings.speed = v;        M.saveSettings() end
function M.setDelay(v)      M.settings.clickDelay = v;   M.saveSettings() end
function M.setIgnore(v)     M.settings.ignoreTravel = v; M.saveSettings() end

------------------------------------------------------------------ status, bottom right

M.badge = nil

local function badge(text, colour)
    if not M.badge then
        M.badge = hs.canvas.new({ x = 0, y = 0, w = 10, h = 10 })
        M.badge:level(hs.canvas.windowLevels.overlay)
        M.badge:behavior({ "canJoinAllSpaces", "stationary" })
        M.badge[1] = { type = "rectangle", action = "fill",
                       fillColor = { red = 0.04, green = 0.05, blue = 0.06, alpha = 0.92 },
                       roundedRectRadii = { xRadius = 5, yRadius = 5 } }
        M.badge[2] = { type = "circle", action = "fill", fillColor = colour,
                       center = { x = 12, y = 12 }, radius = 4 }
        M.badge[3] = { type = "text", text = "", textSize = 11,
                       textColor = { white = 1, alpha = 1 },
                       frame = { x = 22, y = 4, w = 300, h = 16 } }
    end
    local scr = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
    local f = scr:frame()
    local w = math.max(70, math.min(440, 34 + #text * 7))
    local h = 26
    -- BOTTOM MIDDLE, his request 6.9.2026: centred along the bottom edge, not in
    -- a corner. A little above the very edge so it clears the Dock.
    M.badge:frame({ x = f.x + (f.w - w) / 2, y = f.y + f.h - h - 46, w = w, h = h })
    M.badge[3].frame = { x = 22, y = 5, w = w - 26, h = 18 }
    M.badge[2].fillColor = colour
    M.badge[3].text = text
    M.badge:show()
end

local function badgeOff()
    if M.badge then M.badge:hide() end
end

local GREY = { white = 0.6, alpha = 1 }

-- A WORD FOR A MOMENT: the badge shows it and the page shows it, then it goes.
-- Never mid screen. If a recording or a play is running, the badge is theirs
-- and only the page gets the note.
function M.say(text, colour, seconds)
    M.note = { text = text, at = hs.timer.secondsSinceEpoch() }
    if M.recording or M.playing then return end
    -- a badge that cannot be drawn must never break the action that spoke
    if not pcall(badge, text, colour or GREY) then return end
    if M.noteTimer then M.noteTimer:stop() end
    M.noteTimer = hs.timer.doAfter(seconds or 1.4, function()
        if not M.recording and not M.playing then badgeOff() end
    end)
end

-- THE STAR ITSELF turns red while recording and green while playing, his
-- request 4.9.2026. The star menu offers STAR.tint; if it is not there (the
-- module run on its own) the badge alone tells the state.
local function star(colour)
    if STAR and STAR.tint then pcall(STAR.tint, colour) end
end

------------------------------------------------------------------ recording

local et = hs.eventtap.event.types

local function flagList(flags)
    local out = {}
    for _, m in ipairs({ "cmd", "alt", "ctrl", "shift", "fn" }) do
        if flags and flags[m] then out[#out + 1] = m end
    end
    return out
end

-- do these flags hold exactly this set of modifiers (fn aside)?
local function flagsMatch(flags, mods)
    if not flags then return false end
    local want = {}
    for _, m in ipairs(mods or {}) do want[m] = true end
    for _, m in ipairs({ "cmd", "alt", "ctrl", "shift" }) do
        if (flags[m] and true or false) ~= (want[m] and true or false) then return false end
    end
    return true
end

local function codeOf(b)
    return b and b.key and hs.keycodes.map[b.key] or nil
end

-- The keys that start and stop the recording must not become part of it: the
-- record key, the stop key, and any of them in the first second, when the
-- fingers are still coming off the chord.
local function isOurHotkey(code, flags, sinceStart)
    local k = M.settings.keys
    for _, id in ipairs({ "record", "stop", "play" }) do
        local b = k[id]
        if b and codeOf(b) == code then
            if flagsMatch(flags, b.mods) or sinceStart < 1.0 then return true end
        end
    end
    return false
end

local function now() return hs.timer.secondsSinceEpoch() end

local RECORDED = {
    [et.keyDown] = "keyDown", [et.keyUp] = "keyUp",
    [et.leftMouseDown] = "leftMouseDown", [et.leftMouseUp] = "leftMouseUp",
    [et.rightMouseDown] = "rightMouseDown", [et.rightMouseUp] = "rightMouseUp",
    [et.otherMouseDown] = "otherMouseDown", [et.otherMouseUp] = "otherMouseUp",
    [et.mouseMoved] = "mouseMoved",
    [et.leftMouseDragged] = "leftMouseDragged", [et.rightMouseDragged] = "rightMouseDragged",
    [et.otherMouseDragged] = "otherMouseDragged",
    [et.scrollWheel] = "scrollWheel",
}

local function onEvent(e)
    if not M.recording then return false end
    local kind = RECORDED[e:getType()]
    if not kind then return false end
    local t = now() - M.t0
    local flags = e:getFlags()
    local ev = { t = t, kind = kind, mods = flagList(flags) }
    if kind == "keyDown" or kind == "keyUp" then
        local code = e:getKeyCode()
        if isOurHotkey(code, flags, t) then return false end
        if kind == "keyDown" and e:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat) ~= 0 then
            return false      -- a held key repeats by itself when played
        end
        ev.code = code
    elseif kind == "scrollWheel" then
        local p = hs.eventtap.event.properties
        ev.dy = e:getProperty(p.scrollWheelEventPointDeltaAxis1) or 0
        ev.dx = e:getProperty(p.scrollWheelEventPointDeltaAxis2) or 0
        local loc = e:location(); ev.x, ev.y = loc.x, loc.y
    else
        local loc = e:location(); ev.x, ev.y = loc.x, loc.y
        if kind:find("other") then
            ev.button = e:getProperty(hs.eventtap.event.properties.mouseEventButtonNumber)
        end
    end
    M.events[#M.events + 1] = ev
    return false
end

local function keys(tbl) local out = {} for k in pairs(tbl) do out[#out + 1] = k end return out end

function M.startRecording()
    if M.playing then M.stopPlaying() end
    M.events = {}
    M.t0 = now()
    M.tap = hs.eventtap.new(keys(RECORDED), onEvent)
    M.tap:start()
    M.recording = true
    badge("REC" .. (M.pending and ("  " .. M.pending) or ""), { red = 0.95, green = 0.2, blue = 0.2, alpha = 1 })
    star("red")
end

function M.stopRecording()
    M.recording = false
    if M.tap then M.tap:stop(); M.tap = nil end
    badgeOff()
    star(nil)
    local evs = M.events or {}
    -- the chord he pressed to stop is not part of the recording; anything at
    -- the very end that is one of our keys is dropped.
    local ours = {}
    for _, id in ipairs({ "record", "stop", "play" }) do
        local c = codeOf(M.settings.keys[id])
        if c then ours[c] = true end
    end
    while #evs > 0 do
        local last = evs[#evs]
        if (last.kind == "keyDown" or last.kind == "keyUp") and ours[last.code] then
            evs[#evs] = nil
        else break end
    end
    M.events = evs
    hs.fs.mkdir(M.dir); hs.fs.mkdir(M.recDir)
    local rec = { version = 1, recorded = os.date("%Y-%m-%d %H:%M:%S"), events = evs }
    -- the raw events are kept by date, always; the macro itself is a script
    pcall(hs.json.write, rec, M.file, false, true)
    pcall(hs.json.write, rec, M.recDir .. "/" .. M.croName() .. ".json", false, true)
    local title = (M.pending or "last recording") .. ", recorded " .. rec.recorded
    local text = SCRIPT.fromEvents(evs, M.keyNames(), { title, "Edit freely: Click x, y  ·  Send \"text\"  ·  Sleep ms  ·  ClickImage \"button.png\"" })
    local lf = io.open(M.lastFile, "w"); if lf then lf:write(text); lf:close() end
    M.text = text
    if M.pending then
        M.writeScript(M.pending, text)
        M.current, M.pending = M.pending, nil
        -- a new macro lands in the first free slot by itself
        local slot = SLOTS.autoPlace(M.settings.slots, M.current)
        M.say(slot and ("saved " .. M.current .. "  in slot " .. slot) or ("saved " .. M.current),
              { red = 0.3, green = 0.85, blue = 0.4, alpha = 1 }, 2)
    else
        M.current = nil
        M.say(#evs .. " events recorded", GREY, 1.4)
    end
    M.settings.current = M.current
    M.saveSettings()
    M.infoCache = nil
    return #evs
end

------------------------------------------------------------------ named macros

-- THE NAME A MACRO GETS BY ITSELF, Croatian style, his request 4.9.2026: the
-- day, the month, then the hour. No year, nothing else. "4.9. 18.52". The
-- minutes are there so two macros in one hour do not fall on one name.
function M.croName(t)
    t = t or os.time()
    local d = os.date("*t", t)
    return string.format("%d.%d. %02d.%02d", d.day, d.month, d.hour, d.min)
end

-- A name safe as a file name: no slashes, no colons, no control characters,
-- no leading dot (a hidden file he could never see in the folder).
function M.cleanName(name)
    name = tostring(name or ""):gsub("[/\\:%c]", "-"):gsub("^%s+", ""):gsub("%s+$", "")
    name = name:gsub("^%.+", "")
    return name
end

-- A MACRO IS A SCRIPT, <name>.ahk in the folder. A <name>.json from before
-- the language (a recording) is still listed and still plays: it is turned
-- into a script when it is read, and becomes one on disk when it is saved
-- from the editor.
local function ahkOf(name)  return M.macDir .. "/" .. name .. ".ahk" end
local function jsonOf(name) return M.macDir .. "/" .. name .. ".json" end
local function has(p) return p ~= nil and hs.fs.attributes(p) ~= nil end

function M.kindOf(name)
    if not name or name == "" then return nil end
    if has(ahkOf(name)) then return "script" end
    if has(jsonOf(name)) then return "recording" end
    return nil
end

function M.exists(name) return M.kindOf(name) ~= nil end

function M.listMacros()
    local set, names = {}, {}
    if has(M.macDir) then
        for f in hs.fs.dir(M.macDir) do
            local n = f:match("^(.+)%.ahk$") or f:match("^(.+)%.json$")
            if n and f:sub(1, 1) ~= "." and not set[n] then set[n] = true; names[#names + 1] = n end
        end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

-- the key code -> name table the language needs to write a recording down
M.keyNamesCache = nil
function M.keyNames()
    if M.keyNamesCache then return M.keyNamesCache end
    local out = {}
    for k, v in pairs(hs.keycodes.map or {}) do
        if type(k) == "number" and type(v) == "string" then out[k] = v end
        if type(k) == "string" and type(v) == "number" and out[v] == nil then out[v] = k end
    end
    M.keyNamesCache = out
    return out
end

-- THE TEXT OF A MACRO: a script as written, a recording turned into one.
-- Returns text, kind; or nil, reason.
function M.readScript(name)
    local kind = M.kindOf(name)
    if kind == "script" then
        local f = io.open(ahkOf(name), "r")
        if not f then return nil, "cannot read " .. name end
        local t = f:read("a"); f:close()
        return t, "script"
    elseif kind == "recording" then
        local ok, rec = pcall(hs.json.read, jsonOf(name))
        if not ok or type(rec) ~= "table" or type(rec.events) ~= "table" then return nil, "cannot read " .. name end
        return SCRIPT.fromEvents(rec.events, M.keyNames(), { name .. ", recorded " .. tostring(rec.recorded or "") }), "recording"
    end
    return nil, "no macro called " .. tostring(name)
end

function M.writeScript(name, text)
    hs.fs.mkdir(M.dir); hs.fs.mkdir(M.macDir)
    local f, err = io.open(ahkOf(name), "w")
    if not f then return false, "cannot write " .. name .. ": " .. tostring(err) end
    f:write(text or ""); f:close()
    -- a recording of the same name is superseded: it goes to the trash folder, never deleted
    if has(jsonOf(name)) then
        hs.fs.mkdir(M.trashDir)
        os.rename(jsonOf(name), M.trashDir .. "/" .. name .. " (recording).json")
    end
    M.infoCache = nil
    return true
end

-- SAVE from the editor. The text is kept whatever it says: a half-written
-- script is never lost. A parse error comes back as a warning with its line.
function M.saveScript(name, text)
    name = M.cleanName(name)
    if name == "" then return false, "no name" end
    local ok, err = M.writeScript(name, text)
    if not ok then return false, err end
    if M.current == name then M.text = text end
    local prog, perr = SCRIPT.parse(text or "")
    if not prog then return true, nil, "saved, but line " .. perr.line .. ": " .. perr.msg, perr.line end
    return true
end

function M.checkScript(text)
    local prog, perr = SCRIPT.parse(text or "")
    if prog then return true end
    return false, "line " .. perr.line .. ": " .. perr.msg, perr.line
end

-- A NEW, EMPTY SCRIPT to write in the editor. It takes the first free slot.
function M.newScript(name)
    name = M.cleanName(name)
    if name == "" then name = M.croName() end
    if M.exists(name) then return false, "there is already a macro called " .. name end
    local ok, err = M.writeScript(name, "; " .. name .. "\n; Click x, y  ·  Send \"text\"  ·  Sleep ms  ·  ClickImage \"button.png\"\n\n")
    if not ok then return false, err end
    SLOTS.autoPlace(M.settings.slots, name)
    M.saveSettings()
    return true, name
end

-- EVERYTHING THE PAGE NEEDS TO KNOW ABOUT EACH MACRO. Read from disk each
-- time it is asked for, so a rename or a new file in the folder shows on the
-- next poll; the counts are cached by the file's modification time.
M.infoCache = {}
function M.macroInfo()
    local out, cache = {}, M.infoCache or {}
    local fresh = {}
    for _, n in ipairs(M.listMacros()) do
        local kind = M.kindOf(n)
        local p = kind == "script" and ahkOf(n) or jsonOf(n)
        local a = hs.fs.attributes(p)
        local mtime = a and a.modification or 0
        local c = cache[n]
        if not c or c.mtime ~= mtime or c.kind ~= kind then
            c = { mtime = mtime, kind = kind, lines = 0, events = 0, recorded = "", bad = false }
            if kind == "script" then
                local f = io.open(p, "r")
                if f then
                    local first
                    for line in f:lines() do
                        if not line:match("^%s*$") and not line:match("^%s*;") then c.lines = c.lines + 1 end
                        if not first and line:match("^%s*;") then first = line:gsub("^%s*;%s*", "") end
                    end
                    f:close()
                    c.recorded = first and first:match("recorded (.+)$") or ""
                else c.bad = true end
            else
                local ok, rec = pcall(hs.json.read, p)
                if ok and type(rec) == "table" and type(rec.events) == "table" then
                    c.events = #rec.events
                    c.recorded = tostring(rec.recorded or "")
                else c.bad = true end
            end
        end
        fresh[n] = c
        out[#out + 1] = { name = n, kind = kind, lines = c.lines, events = c.events, recorded = c.recorded, bad = c.bad,
                          slot = SLOTS.slotOf(M.settings.slots, n),
                          inPlayer = (M.current == n) }
    end
    M.infoCache = fresh
    return out
end

-- NEW MACRO from the star menu: ask for a name in a box, then record. The
-- recording is saved under that name when the record key stops it, and
-- becomes the one in the player.
function M.newMacro()
    if M.recording then M.stopRecording() end
    if M.playing then M.stopPlaying() end
    local rec = M.keyLabel(M.settings.keys.record)
    local button, text = hs.dialog.textPrompt("New macro", "Name it, then press " .. rec .. " when you are done recording.",
                                              M.croName(), "Record", "Cancel")
    if button ~= "Record" then return false, "cancelled" end
    return M.newMacroNamed(text)
end

-- NEW MACRO with the name already given, from the page.
function M.newMacroNamed(text)
    if M.recording then M.stopRecording() end
    if M.playing then M.stopPlaying() end
    local name = M.cleanName(text)
    if name == "" then name = M.croName() end
    if M.exists(name) then
        M.say("there is already a macro called " .. name, GREY, 2)
        return false, "there is already a macro called " .. name
    end
    M.pending = name
    M.startRecording()
    return true, "recording " .. name
end

-- LOAD MACRO: the named one goes into the player, what the play key plays.
function M.loadMacro(name, quiet)
    local text, kind = M.readScript(name)
    if not text then
        if not quiet then M.say(kind, GREY, 2) end
        return false, kind
    end
    M.text    = text
    M.current = name
    M.settings.current = name
    M.saveSettings()
    if not quiet then M.say("in the player: " .. name, GREY, 1.4) end
    return true, "loaded " .. name
end

-- RENAME, from the page. The file moves on disk, the slot follows, the player
-- follows. A name that is already taken is refused rather than overwritten.
function M.renameMacro(old, new)
    new = M.cleanName(new)
    if new == "" then return false, "no name" end
    if new == old then return true, "same name" end
    if not M.exists(old) then return false, "no macro called " .. tostring(old) end
    if M.exists(new) then return false, "there is already a macro called " .. new end
    for _, ext in ipairs({ ".ahk", ".json" }) do
        local from = M.macDir .. "/" .. old .. ext
        if has(from) then
            local ok, err = os.rename(from, M.macDir .. "/" .. new .. ext)
            if not ok then return false, "could not rename: " .. tostring(err) end
        end
    end
    SLOTS.rename(M.settings.slots, old, new)
    if M.current == old then M.current = new; M.settings.current = new end
    M.saveSettings()
    M.infoCache = nil
    M.say("renamed to " .. new, GREY, 1.4)
    return true, "renamed"
end

-- REMOVE, from the page: the file goes to ~/.mantra_macro/trash, never deleted,
-- and the slot it sat in is freed. His folder is his; nothing is lost.
function M.trashMacro(name)
    if not M.exists(name) then return false, "no macro called " .. tostring(name) end
    hs.fs.mkdir(M.trashDir)
    for _, ext in ipairs({ ".ahk", ".json" }) do
        local from = M.macDir .. "/" .. name .. ext
        if has(from) then
            local dest = M.trashDir .. "/" .. name .. ext
            if has(dest) then dest = M.trashDir .. "/" .. name .. " " .. os.date("%Y%m%d-%H%M%S") .. ext end
            local ok, err = os.rename(from, dest)
            if not ok then return false, "could not move: " .. tostring(err) end
        end
    end
    SLOTS.remove(M.settings.slots, name)
    if M.current == name then M.current = nil; M.settings.current = nil; M.text = nil end
    M.saveSettings()
    M.infoCache = nil
    M.say(name .. " moved to the trash folder", GREY, 1.6)
    return true, "moved to trash"
end

function M.toggleRecording()
    if M.recording then M.stopRecording() else M.startRecording() end
end

------------------------------------------------------------------ the pictures

local GREEN2 = { red = 0.3, green = 0.85, blue = 0.4, alpha = 1 }

function M.listImages()
    local names = {}
    if has(M.imgDir) then
        for f in hs.fs.dir(M.imgDir) do
            if f:sub(1, 1) ~= "." and (f:match("%.png$") or f:match("%.jpe?g$")) then names[#names + 1] = f end
        end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

-- The pictures with their search zones, for the page.
function M.pictureInfo()
    local out = {}
    for _, n in ipairs(M.listImages()) do
        local z = M.settings.zones[n]
        out[#out + 1] = { name = n, zone = z and { x = math.floor(z.x), y = math.floor(z.y), w = math.floor(z.w), h = math.floor(z.h) } or false }
    end
    return out
end

function M.imagePath(file)
    if file:sub(1, 1) == "/" then return file end
    if file:sub(1, 2) == "~/" then return HOME .. file:sub(2) end
    return M.imgDir .. "/" .. file
end

------------------------------------------------------------------ the search spinner

-- A SMALL SPINNER, bottom right, his rule: never mid screen, never a fright.
-- One canvas, a turning arc and the words "searching for a pattern". It is
-- reference counted, so a ClickImage that searches again and again keeps one
-- steady spinner rather than a flicker.
M.spin = { canvas = nil, timer = nil, depth = 0, angle = 0 }

local function spinnerDraw()
    local S = M.spin
    if not S.canvas then
        S.canvas = hs.canvas.new({ x = 0, y = 0, w = 10, h = 10 })
        S.canvas:level(hs.canvas.windowLevels.overlay)
        S.canvas:behavior({ "canJoinAllSpaces", "stationary" })
    end
    local scr = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
    local f = scr:frame()
    local w, h = 210, 30
    -- bottom middle, with the recorder's status line, his request 6.9.2026
    S.canvas:frame({ x = f.x + (f.w - w) / 2, y = f.y + f.h - h - 46, w = w, h = h })
    local cx, cy, r = 15, 15, 8
    local a0 = S.angle
    local elements = {
        { type = "rectangle", action = "fill",
          fillColor = { red = 0.04, green = 0.05, blue = 0.06, alpha = 0.92 },
          roundedRectRadii = { xRadius = 6, yRadius = 6 } },
        { type = "text", text = "searching for a pattern", textSize = 12,
          textColor = { white = 1, alpha = 0.95 }, frame = { x = 30, y = 7, w = w - 34, h = 18 } },
    }
    -- a turning arc drawn as short segments, brightest at the head
    local segs = 12
    for i = 0, segs - 1 do
        local a = a0 - i * (2 * math.pi / segs)
        local alpha = 0.15 + 0.85 * (1 - i / segs)
        elements[#elements + 1] = {
            type = "segments", action = "stroke", strokeWidth = 2.4,
            strokeColor = { red = 0.3, green = 0.85, blue = 0.4, alpha = alpha },
            strokeCapStyle = "round",
            coordinates = {
                { x = cx + math.cos(a) * (r - 3), y = cy + math.sin(a) * (r - 3) },
                { x = cx + math.cos(a) * r,       y = cy + math.sin(a) * r },
            },
        }
    end
    S.canvas:replaceElements(elements)
    S.canvas:show()
end

function M.searchStart()
    local S = M.spin
    S.depth = S.depth + 1
    if S.depth == 1 then
        if S.timer then S.timer:stop() end
        S.timer = hs.timer.doEvery(0.07, function()
            S.angle = S.angle - 0.5
            pcall(spinnerDraw)
        end)
        pcall(spinnerDraw)
    end
end

function M.searchEnd()
    local S = M.spin
    S.depth = math.max(0, S.depth - 1)
    if S.depth == 0 then
        if S.timer then S.timer:stop(); S.timer = nil end
        if S.canvas then S.canvas:hide() end
    end
end

local function spinnerKill()
    local S = M.spin
    S.depth = 0
    if S.timer then S.timer:stop(); S.timer = nil end
    if S.canvas then S.canvas:delete(); S.canvas = nil end
end

------------------------------------------------------------------ finding, the core

-- the screen whose full frame holds a point, or the main screen
local function screenAt(x, y)
    for _, scr in ipairs(hs.screen.allScreens()) do
        local f = scr:fullFrame()
        if x >= f.x and x < f.x + f.w and y >= f.y and y < f.y + f.h then return scr end
    end
    return hs.screen.mainScreen()
end

-- SEARCH THE SCREENS for a template PATH, without blocking. `region` (absolute
-- points) limits the look to one rectangle; nil searches every screen. Each
-- region is shot to a BMP and matched by find.py as a background task, so the
-- main thread stays free and the spinner turns. Calls back with the best
-- { x, y, w, h, score } in points across the screens searched, or nil.
-- `threshold` is passed to find.py; it defaults to 0.85.
local function searchForPath(path, region, cb, threshold)
    local function later(v) hs.timer.doAfter(0, function() cb(v) end) end
    if not has(path) then return later(nil) end
    if not has(M.findPy) then M.say("find.py is missing", GREY, 3); return later(nil) end
    hs.fs.mkdir(M.dir); hs.fs.mkdir(M.tmpDir)
    local jobs = {}
    if region then
        jobs[1] = { rect = region, scr = screenAt(region.x + region.w / 2, region.y + region.h / 2) }
    else
        for _, scr in ipairs(hs.screen.allScreens()) do
            jobs[#jobs + 1] = { rect = scr:fullFrame(), scr = scr }
        end
    end
    M.searchStart()
    local finished, best = false, nil
    local function finish() if finished then return end finished = true; M.searchEnd(); cb(best) end
    local thr = tostring(threshold or 0.85)
    local i = 0
    local function runNext()
        i = i + 1
        if i > #jobs then return finish() end
        local job = jobs[i]
        local rect = job.rect
        -- snapshot takes the rect in the SCREEN'S OWN coordinates (0,0 at that
        -- screen's top-left), while zones and clicks are in global points; so
        -- subtract the screen's full-frame origin.
        local ff = job.scr:fullFrame()
        local shot = job.scr:snapshot({ x = rect.x - ff.x, y = rect.y - ff.y, w = rect.w, h = rect.h })
        if not shot then return runNext() end
        -- BMP, not PNG: encoding a full Retina screen to PNG is slow, and this
        -- picture is thrown away the moment find.py has read it.
        local tmp = M.tmpDir .. "/search" .. i .. ".bmp"
        shot:saveToFile(tmp, "bmp")
        hs.task.new(PYTHON, function(_, out, _)
            out = out or ""
            local px, py, pw, ph, score, sw = out:match("(%d+) (%d+) (%d+) (%d+) ([%d%.]+) (%d+)")
            if px then
                local scale = (tonumber(sw) and tonumber(sw) > 0) and (tonumber(sw) / rect.w) or 1
                local x = rect.x + tonumber(px) / scale
                local y = rect.y + tonumber(py) / scale
                local w, h = tonumber(pw) / scale, tonumber(ph) / scale
                local hit = { x = math.floor(x + 0.5), y = math.floor(y + 0.5),
                              w = math.floor(w + 0.5), h = math.floor(h + 0.5), score = tonumber(score) }
                if not best or hit.score > best.score then best = hit end
            end
            runNext()     -- keep looking: the best across all screens wins, not the first
        end, { M.findPy, tmp, path, thr }):start()
    end
    runNext()
end
M.searchForPath = searchForPath

------------------------------------------------------------------ snapping a picture

-- SNAP A PICTURE: the system's own selection cross-hair, drag over the button,
-- the file lands in the images folder. Run as a task, not inline, so
-- Hammerspoon is not held while he drags. `then_` is called with the file name
-- when it saved, or nil.
function M.snap(name, then_)
    hs.fs.mkdir(M.dir); hs.fs.mkdir(M.imgDir)
    name = M.cleanName(name):gsub("%.png$", "")
    if name == "" then name = "button " .. M.croName() end
    local path = M.imgDir .. "/" .. name .. ".png"
    local n = 2
    while has(path) do path = M.imgDir .. "/" .. name .. " " .. n .. ".png"; n = n + 1 end
    local file = path:match("([^/]+)$")
    M.snapTask = hs.task.new("/usr/sbin/screencapture", function()
        M.snapTask = nil
        if has(path) then
            M.say("picture saved: " .. file, GREEN2, 2.5)
            M.infoCache = nil
            if then_ then then_(file) end
        else
            M.say("no picture taken", GREY, 1.6)
            if then_ then then_(nil) end
        end
    end, { "-i", "-x", path }):start()
    M.say("drag over the button on the screen. Esc cancels", GREY, 12)
    return true, file
end

-- CAPTURE A ZONE with the SAME cross-hair as snapping a button, then keep only
-- its coordinates. His request, 6.9.2026: the drag-overlay selector did not
-- work (a canvas at that level swallows the mouse before an eventtap sees it),
-- so use screencapture -i for the zone too. The selected region is saved, its
-- rectangle is recovered by finding that image back on the screen, and the
-- image is thrown away. Esc (no file) cancels.
function M.captureRegionRect(prompt, cb)
    hs.fs.mkdir(M.dir); hs.fs.mkdir(M.tmpDir)
    local tmp = M.tmpDir .. "/zone.png"
    os.remove(tmp)
    M.say(prompt or "drag the SEARCH ZONE on the screen. Esc cancels", GREY, 12)
    M.zoneTask = hs.task.new("/usr/sbin/screencapture", function()
        M.zoneTask = nil
        if not has(tmp) then if cb then cb(nil) end return end
        M.say("placing the zone…", GREY, 3)
        -- a just-captured region matches its own place at ~1.0; a gentle bar
        -- lets a touch of drift through, and the region is distinctive (it holds
        -- the button he dragged over), so it is not placed somewhere else.
        searchForPath(tmp, nil, function(rect)
            os.remove(tmp)
            if cb then cb(rect) end
        end, 0.7)
    end, { "-i", "-x", tmp }):start()
    return true
end

-- SET THE SEARCH ZONE for a picture: draw the rectangle with the cross-hair,
-- store its coordinates. No zone means every screen.
function M.setZone(file)
    if not has(M.imgDir .. "/" .. file) then return false, "no picture called " .. tostring(file) end
    M.captureRegionRect("drag the SEARCH ZONE for " .. file .. " (over the button, a little around it). Esc keeps all screens", function(rect)
        if rect then
            M.settings.zones[file] = { x = rect.x, y = rect.y, w = rect.w, h = rect.h }
            M.saveSettings()
            M.say(string.format("zone for %s: %d × %d", file, math.floor(rect.w), math.floor(rect.h)), GREEN2, 2.2)
        else
            M.say("zone unchanged (could not place it, or cancelled)", GREY, 2)
        end
    end)
    return true
end

function M.clearZone(file)
    M.settings.zones[file] = nil
    M.saveSettings()
    M.say(file .. " searches all screens", GREY, 1.6)
    return true
end

-- NEW PATTERN, the two steps he asked for: snap the button, then draw its
-- search zone, both with the cross-hair. Esc on the zone step leaves it
-- searching all screens.
function M.newPattern(name)
    return M.snap(name, function(file)
        if not file then return end
        hs.timer.doAfter(0.5, function()
            M.captureRegionRect("now drag the SEARCH ZONE for " .. file .. ", or Esc to search all screens", function(rect)
                if rect then
                    M.settings.zones[file] = { x = rect.x, y = rect.y, w = rect.w, h = rect.h }
                    M.saveSettings()
                    M.say(string.format("%s ready, zone %d × %d", file, math.floor(rect.w), math.floor(rect.h)), GREEN2, 2.5)
                else
                    M.say(file .. " ready, searches all screens", GREEN2, 2.2)
                end
            end)
        end)
    end)
end

------------------------------------------------------------------ finding a picture

-- WHICH RECTANGLE TO SEARCH: an explicit region (from ImageSearch's x1..y2),
-- else the picture's stored zone, else nil for every screen.
local function regionFor(file, x1, y1, x2, y2)
    if x1 and y1 and x2 and y2 and x2 > x1 and y2 > y1 then
        return { x = x1, y = y1, w = x2 - x1, h = y2 - y1 }
    end
    local z = M.settings.zones[file]
    if z then return { x = z.x, y = z.y, w = z.w, h = z.h } end
    return nil
end

-- FIND A NAMED PICTURE: resolve the name to a file and search (its own zone,
-- or every screen). Calls back with { x, y, w, h, score } in points, or nil.
function M.findImageAsync(file, region, cb)
    local path = M.imagePath(file)
    if not has(path) then
        M.say("no picture called " .. tostring(file), GREY, 2)
        hs.timer.doAfter(0, function() cb(nil) end)
        return
    end
    searchForPath(path, region, cb)
end

-- "Find on screen" on the page: look (with the picture's own zone), move the
-- mouse there, say the score.
function M.findTest(file)
    M.findImageAsync(file, regionFor(file), function(r)
        if not r then M.say("not on the screen now: " .. file, GREY, 2.5); return end
        hs.mouse.absolutePosition({ x = r.x + r.w / 2, y = r.y + r.h / 2 })
        M.say(string.format("found %s at %d, %d (%.0f%%)", file, r.x, r.y, (r.score or 0) * 100), GREEN2, 2.5)
    end)
    return true
end

function M.trashImage(file)
    local path = M.imgDir .. "/" .. file
    if not has(path) then return false, "no picture called " .. file end
    hs.fs.mkdir(M.trashDir)
    local dest = M.trashDir .. "/" .. file
    if has(dest) then dest = M.trashDir .. "/" .. os.date("%Y%m%d-%H%M%S") .. " " .. file end
    local ok, err = os.rename(path, dest)
    if not ok then return false, "could not move: " .. tostring(err) end
    M.settings.zones[file] = nil     -- the zone goes with the picture
    M.saveSettings()
    M.say(file .. " moved to the trash folder", GREY, 1.6)
    return true
end

------------------------------------------------------------------ the slots

-- Assign, clear, move, swap: the page's verbs, each saved at once.
function M.assignSlot(slot, name)
    if not M.exists(name) then return false, "no macro called " .. tostring(name) end
    local ok, err = SLOTS.assign(M.settings.slots, slot, name)
    if ok then M.saveSettings() end
    return ok, err
end

function M.clearSlot(slot)
    local ok, err = SLOTS.clear(M.settings.slots, slot)
    if ok then M.saveSettings() end
    return ok, err
end

function M.moveSlot(from, to)
    local ok, err = SLOTS.move(M.settings.slots, from, to)
    if ok then M.saveSettings() end
    return ok, err
end

function M.swapSlot(a, b)
    local ok, err = SLOTS.swap(M.settings.slots, a, b)
    if ok then M.saveSettings() end
    return ok, err
end

-- ⌥N: the slot's macro goes into the player.
function M.loadSlot(slot)
    local name = M.settings.slots[tostring(slot)]
    if not name then
        M.say("slot " .. tostring(slot) .. " is empty", GREY, 1.4)
        return false, "slot " .. tostring(slot) .. " is empty"
    end
    return M.loadMacro(name)
end

-- ⌃N: the slot's macro goes into the player and plays at once.
function M.runSlot(slot)
    local name = M.settings.slots[tostring(slot)]
    if not name then
        M.say("slot " .. tostring(slot) .. " is empty", GREY, 1.4)
        return false, "slot " .. tostring(slot) .. " is empty"
    end
    if M.recording then M.stopRecording() end
    return M.runNamed(name)
end

------------------------------------------------------------------ the schedule

-- PURE: recorded events in, a play list with times out. This is what the
-- settings act on, and it is tested in plain Lua with no Hammerspoon.
--
-- speed divides every gap. ignoreTravel drops mouseMoved. clickDelay, when
-- above 0, puts every mouse-down exactly clickDelay after the previous one and
-- fits the events between two clicks into that gap in proportion, so the order
-- never changes and the rhythm is one.
local function isClick(ev)
    return ev.kind == "leftMouseDown" or ev.kind == "rightMouseDown" or ev.kind == "otherMouseDown"
end

function M.schedule(events, settings)
    local speed  = (settings.speed and settings.speed > 0) and settings.speed or 1
    local delay  = settings.clickDelay or 0
    local list   = {}
    for _, ev in ipairs(events or {}) do
        if not (settings.ignoreTravel and ev.kind == "mouseMoved") then
            list[#list + 1] = ev
        end
    end
    local out = {}
    if delay <= 0 then
        for i, ev in ipairs(list) do
            out[i] = { ev = ev, at = ev.t / speed }
        end
        return out
    end
    -- rhythm: walk from click to click
    local lastClickIdx, lastClickAt = nil, nil
    local i = 1
    while i <= #list do
        local ev = list[i]
        if isClick(ev) then
            if lastClickIdx then
                -- fit everything after the previous click, up to and including this click, into delay
                local span = ev.t - list[lastClickIdx].t
                for j = lastClickIdx + 1, i do
                    local o = list[j].t - list[lastClickIdx].t
                    local frac = span > 0 and (o / span) or 1
                    out[j] = { ev = list[j], at = lastClickAt + frac * delay }
                end
            else
                -- everything before the first click keeps its own timing, at speed
                for j = 1, i do out[j] = { ev = list[j], at = list[j].t / speed } end
            end
            lastClickIdx, lastClickAt = i, out[i].at
        end
        i = i + 1
    end
    -- after the last click (or with no click at all): own timing at speed
    local base = lastClickIdx and list[lastClickIdx].t or 0
    local baseAt = lastClickAt or 0
    for j = (lastClickIdx or 0) + 1, #list do
        out[j] = { ev = list[j], at = baseAt + (list[j].t - base) / speed }
    end
    return out
end

------------------------------------------------------------------ playing

-- THE PLAYER RUNS SCRIPTS. The interpreter in script.lua asks this HOST for
-- every click, key, wait and picture; the host does it with Hammerspoon. It
-- runs inside a coroutine: a wait yields the seconds, the driver below
-- resumes it on a timer, and stop drops the coroutine.
local GREEN = { red = 0.3, green = 0.85, blue = 0.4, alpha = 1 }
local BUTTONS = { left = { "leftMouseDown", "leftMouseUp" }, right = { "rightMouseDown", "rightMouseUp" },
                  middle = { "otherMouseDown", "otherMouseUp" } }

local function mouseEvent(kind, x, y, mods, button, clickState)
    local e = hs.eventtap.event.newMouseEvent(et[kind], { x = x, y = y }, mods or {})
    if button == "middle" then e:setProperty(hs.eventtap.event.properties.mouseEventButtonNumber, 2) end
    if clickState then e:setProperty(hs.eventtap.event.properties.mouseEventClickState, clickState) end
    e:post()
end

local function wait(sec) coroutine.yield(sec) end

local function expand(p)
    if p:sub(1, 2) == "~/" then return HOME .. p:sub(2) end
    return p
end

local host = {}
host.now = now
host.sleep = function(sec)
    if sec and sec > 0 then wait(sec / ((M.settings.speed and M.settings.speed > 0) and M.settings.speed or 1))
    else wait(0) end
end
host.mouseMove = function(x, y) hs.mouse.absolutePosition({ x = x, y = y }) end
host.click = function(button, x, y, times, mods)
    local b = BUTTONS[button] or BUTTONS.left
    if not x or not y then local p = hs.mouse.absolutePosition(); x, y = p.x, p.y end
    -- the rhythm setting: every click at least this long after the last one
    local d = M.settings.clickDelay or 0
    if d > 0 then
        local since = now() - (M.lastClickAt or 0)
        if since < d then wait(d - since) end
    end
    hs.mouse.absolutePosition({ x = x, y = y })
    wait(0.01)
    for i = 1, (times or 1) do
        mouseEvent(b[1], x, y, mods, button, i)
        mouseEvent(b[2], x, y, mods, button, i)
        if i < (times or 1) then wait(0.06) end
    end
    M.lastClickAt = now()
end
host.buttonDownUp = function(button, ud, x, y, mods)
    local b = BUTTONS[button] or BUTTONS.left
    if not x or not y then local p = hs.mouse.absolutePosition(); x, y = p.x, p.y end
    hs.mouse.absolutePosition({ x = x, y = y })
    mouseEvent(ud == "down" and b[1] or b[2], x, y, mods, button)
end
host.drag = function(button, x1, y1, x2, y2, mods)
    local b = BUTTONS[button] or BUTTONS.left
    local dragKind = b[1]:gsub("Down", "Dragged")
    hs.mouse.absolutePosition({ x = x1, y = y1 })
    wait(0.02)
    mouseEvent(b[1], x1, y1, mods, button)
    for i = 1, 12 do
        local t = i / 12
        mouseEvent(dragKind, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, mods, button)
        wait(0.015)
    end
    mouseEvent(b[2], x2, y2, mods, button)
    M.lastClickAt = now()
end
host.mousePos = function() local p = hs.mouse.absolutePosition(); return math.floor(p.x + 0.5), math.floor(p.y + 0.5) end
host.key = function(mods, name)
    local code = hs.keycodes.map[name]
    if not code then error("no key called {" .. tostring(name) .. "}", 0) end
    hs.eventtap.event.newKeyEvent(mods or {}, code, true):post()
    hs.eventtap.event.newKeyEvent(mods or {}, code, false):post()
    wait(0.012)
end
host.keyDownUp = function(name, down, mods)
    local code = hs.keycodes.map[name]
    if not code then error("no key called {" .. tostring(name) .. "}", 0) end
    hs.eventtap.event.newKeyEvent(mods or {}, code, down and true or false):post()
end
host.type = function(text) hs.eventtap.keyStrokes(text); wait(0.01 * #text) end
host.wheel = function(dir, times, mods)
    local dx, dy = 0, 0
    if dir == "down" then dy = -times elseif dir == "up" then dy = times
    elseif dir == "left" then dx = times elseif dir == "right" then dx = -times end
    hs.eventtap.event.newScrollEvent({ dx, dy }, mods or {}, "line"):post()
    wait(0.05)
end
-- The search runs as a background task so the main thread stays free and the
-- spinner turns. The coroutine yields an await marker; the search's callback
-- resumes it with the result. In the interpreter this looks synchronous.
host.imageSearch = function(file, x1, y1, x2, y2)
    local co = M.co
    local region = regionFor(file, x1, y1, x2, y2)
    local result = nil
    M.findImageAsync(file, region, function(r)
        result = r
        if M.co == co and M.playing and M.resume then M.resume() end
    end)
    coroutine.yield({ await = true })
    return result
end
-- ClickImage and WaitImage loop; this keeps one steady spinner across the tries.
host.searchHold = function(on) if on then M.searchStart() else M.searchEnd() end end
host.pixel = function(x, y)
    for _, scr in ipairs(hs.screen.allScreens()) do
        local f = scr:fullFrame()
        if x >= f.x and x < f.x + f.w and y >= f.y and y < f.y + f.h then
            local img = scr:snapshot({ x = x - f.x, y = y - f.y, w = 1, h = 1 })
            local c = img and img:colorAt({ x = 0, y = 0 })
            if c then return string.format("0x%02X%02X%02X", math.floor(c.red * 255 + 0.5), math.floor(c.green * 255 + 0.5), math.floor(c.blue * 255 + 0.5)) end
        end
    end
    return "0x000000"
end
host.say = function(text, long) M.sayWhilePlaying(text, long and 3 or 1.6) end
host.run = function(what)
    if what:match("^https?://") or what:match("^/") or what:match("^~") or what:match("^file:") then
        hs.execute("open " .. string.format("%q", expand(what)))
    elseif not hs.application.launchOrFocus(what) then
        hs.execute("open " .. string.format("%q", what))
    end
end
host.activate = function(title)
    if hs.application.launchOrFocus(title) then return true end
    local w = hs.window.find(title)
    if w then w:focus(); return true end
    return false
end
host.winExists = function(title) return hs.application.find(title) ~= nil or hs.window.find(title) ~= nil end
host.clipboard = function() return hs.pasteboard.getContents() or "" end
host.setClipboard = function(v) hs.pasteboard.setContents(v) end
host.screen = function() local f = hs.screen.mainScreen():frame(); return f.w, f.h end
host.fileExist = function(p) return hs.fs.attributes(expand(p)) ~= nil end
host.fileRead = function(p) local f = io.open(expand(p), "r"); if not f then return "" end local t = f:read("a"); f:close(); return t end
host.fileAppend = function(text, p) local f = io.open(expand(p), "a"); if f then f:write(text); f:close() end end
M.host = host

-- A WORD WHILE PLAYING: MsgBox and ToolTip show bottom right without taking
-- the PLAY badge away for good.
function M.sayWhilePlaying(text, seconds)
    if not M.playing then return M.say(text, GREY, seconds) end
    M.note = { text = text, at = now() }
    pcall(badge, text, GREEN)
    if M.noteTimer then M.noteTimer:stop() end
    M.noteTimer = hs.timer.doAfter(seconds or 1.6, function()
        if M.playing then pcall(badge, "PLAY  " .. (M.current or "last recording"), GREEN) end
    end)
end

function M.loadLast()
    local f = io.open(M.lastFile, "r")
    if not f then return nil end
    local t = f:read("a"); f:close()
    return t
end

-- RUN A SCRIPT. Parse first: an error names its line and nothing moves.
function M.runScript(text, name)
    if M.playing then M.stopPlaying() end
    name = name or "script"
    local prog, perr = SCRIPT.parse(text or "")
    if not prog then
        M.lastError = { name = name, line = perr.line, msg = "line " .. perr.line .. ": " .. perr.msg, at = now() }
        M.say(M.lastError.msg, GREY, 4)
        return false, M.lastError.msg, perr.line
    end
    M.playing = true
    M.lastError = nil
    M.lastClickAt = 0
    pcall(badge, "PLAY  " .. name, GREEN)
    star("green")
    local co = coroutine.create(function() return SCRIPT.run(prog, host, { speed = M.settings.speed }) end)
    M.co = co
    local function step()
        if not M.playing or M.co ~= co then return end
        local ok, a, b, c = coroutine.resume(co)
        if M.co ~= co then return end       -- stopped while running
        if not ok then
            M.lastError = { name = name, msg = tostring(a), at = now() }
            M.stopPlaying()
            M.say("error: " .. tostring(a), GREY, 4)
            return
        end
        if coroutine.status(co) == "dead" then
            M.stopPlaying()
            if a then M.say("done: " .. name, GREY, 1.2)
            else
                M.lastError = { name = name, msg = tostring(b), line = c, at = now() }
                M.say(tostring(b), GREY, 4)
            end
            return
        end
        -- a search yields an await marker: do not schedule; its callback resumes.
        if type(a) == "table" and a.await then return end
        M.timer = hs.timer.doAfter(math.max(tonumber(a) or 0, 0.001), step)
    end
    M.resume = step
    step()
    return true, "running " .. name
end

-- PLAY: what is in the player, else the last recording.
function M.play()
    if M.recording then M.stopRecording() end
    local text, name = M.text, M.current
    if not text or text == "" then text = M.loadLast(); name = "last recording" end
    if not text or text == "" then
        M.say("nothing in the player yet", GREY, 1.4)
        return false, "nothing recorded yet"
    end
    return M.runScript(text, name or "last recording")
end

-- RUN A NAMED MACRO NOW: into the player and off it goes.
function M.runNamed(name)
    local ok, err = M.loadMacro(name, true)
    if not ok then M.say(err, GREY, 2); return false, err end
    return M.runScript(M.text, name)
end

function M.stopPlaying()
    M.playing = false
    M.co = nil
    M.resume = nil
    if M.timer then M.timer:stop(); M.timer = nil end
    spinnerKill()
    badgeOff()
    star(nil)
end

function M.togglePlay()
    if M.playing then M.stopPlaying() else M.play() end
end

-- THE STOP KEY: whatever is running, stops. A recording stops and is saved.
function M.stopAll()
    if M.recording then M.stopRecording() end
    if M.playing then M.stopPlaying() end
end

------------------------------------------------------------------ key labels and binding

local GLYPH = { ctrl = "⌃", alt = "⌥", shift = "⇧", cmd = "⌘" }
local MOD_ORDER = { "ctrl", "alt", "shift", "cmd" }
local KEYNAME = { escape = "Esc", space = "Space", ["return"] = "↩", tab = "⇥",
                  delete = "⌫", forwarddelete = "⌦", up = "↑", down = "↓",
                  left = "←", right = "→", home = "Home", ["end"] = "End",
                  pageup = "PgUp", pagedown = "PgDn" }

function M.modsLabel(mods)
    local out = {}
    for _, m in ipairs(MOD_ORDER) do
        for _, x in ipairs(mods or {}) do
            if x == m then out[#out + 1] = GLYPH[m] end
        end
    end
    return table.concat(out)
end

function M.keyLabel(b)
    if not b or not b.key then return "none" end
    local k = KEYNAME[b.key] or (#b.key == 1 and b.key:upper() or b.key)
    return M.modsLabel(b.mods) .. k
end

local function sameMods(a, b)
    local sa, sb = {}, {}
    for _, m in ipairs(a or {}) do sa[m] = true end
    for _, m in ipairs(b or {}) do sb[m] = true end
    for _, m in ipairs(MOD_ORDER) do if (sa[m] or false) ~= (sb[m] or false) then return false end end
    return true
end

local DIGITS = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" }
local ISDIGIT = {}
for _, d in ipairs(DIGITS) do ISDIGIT[d] = true end

-- WHAT ALREADY USES THIS CHORD, or nil. A key is refused rather than bound
-- twice, because two things on one chord means one of them is silently gone.
function M.usedBy(mods, key, exceptId)
    local k = M.settings.keys
    for _, a in ipairs(M.ACTIONS) do
        local b = k[a.id]
        if a.id ~= exceptId and b and b.key == key and sameMods(b.mods, mods) then return a.label end
    end
    if ISDIGIT[key] then
        if exceptId ~= "loadMods" and sameMods(k.loadMods, mods) then return "loading slot " .. key end
        if exceptId ~= "runMods"  and sameMods(k.runMods, mods)  then return "running slot " .. key end
    end
    return nil
end

local function bindOne(mods, key, fn)
    local ok, hk = pcall(hs.hotkey.bind, mods, key, fn)
    if ok and hk then M.hotkeys[#M.hotkeys + 1] = hk end
end

-- BIND EVERY KEY FROM THE SETTINGS. Called on start and again after any
-- change, and it always starts by letting every earlier binding go, so a
-- changed key never leaves its old chord behind.
function M.bindKeys()
    M.unbindKeys()
    local k = M.settings.keys
    local fns = {
        record   = M.toggleRecording,
        play     = M.togglePlay,
        stop     = M.stopAll,
        newMacro = M.newMacro,
        settings = function() if M.page then M.page.toggleSmall() end end,
    }
    for _, a in ipairs(M.ACTIONS) do
        local b = k[a.id]
        if b and b.key then bindOne(b.mods or {}, b.key, fns[a.id]) end
    end
    if k.loadMods and #k.loadMods > 0 then
        for _, d in ipairs(DIGITS) do bindOne(k.loadMods, d, function() M.loadSlot(d) end) end
    end
    if k.runMods and #k.runMods > 0 and not sameMods(k.runMods, k.loadMods) then
        for _, d in ipairs(DIGITS) do bindOne(k.runMods, d, function() M.runSlot(d) end) end
    end
end

function M.unbindKeys()
    for _, hk in ipairs(M.hotkeys or {}) do pcall(function() hk:delete() end) end
    M.hotkeys = {}
end

-- SET A KEY OUTRIGHT (used by the capture below and by a test).
function M.setKey(id, mods, key)
    if not DEFAULT_KEYS[id] or id == "loadMods" or id == "runMods" then return false, "no action " .. tostring(id) end
    local taken = M.usedBy(mods, key, id)
    if taken then return false, "that key already does: " .. taken end
    M.settings.keys[id] = { mods = mods, key = key }
    M.saveSettings()
    if M.loaded then M.bindKeys() end
    return true
end

-- THE SLOT MODIFIERS: which chord loads a slot and which runs it. Each must
-- hold at least one modifier (a bare digit would take the digits away from
-- typing) and the two must differ.
function M.setMods(which, mods)
    if which ~= "loadMods" and which ~= "runMods" then return false, "no such setting" end
    local clean = {}
    for _, m in ipairs(MOD_ORDER) do
        for _, x in ipairs(mods or {}) do if x == m then clean[#clean + 1] = m end end
    end
    if #clean == 0 then return false, "hold at least one modifier, or the digits could not be typed" end
    local other = which == "loadMods" and "runMods" or "loadMods"
    if sameMods(clean, M.settings.keys[other]) then
        return false, "loading and running cannot share one chord"
    end
    for _, d in ipairs(DIGITS) do
        local taken = M.usedBy(clean, d, which)
        if taken then return false, "that chord with " .. d .. " already does: " .. taken end
    end
    M.settings.keys[which] = clean
    M.saveSettings()
    if M.loaded then M.bindKeys() end
    return true
end

-- CAPTURE A KEY FROM THE MAC. The page says "press the keys now"; the next
-- chord with a modifier (or a function key) becomes the action's key. Escape
-- keeps the old one. Fifteen seconds and it gives up, so a capture started
-- from the phone and forgotten does not swallow the next keystroke an hour
-- later.
function M.captureKey(id)
    local known = false
    for _, a in ipairs(M.ACTIONS) do if a.id == id then known = true end end
    if not known then return false, "no action " .. tostring(id) end
    if M.capture then return false, "already capturing" end
    M.capture = id
    local function done(text)
        if M.captureTap then M.captureTap:stop(); M.captureTap = nil end
        if M.captureTimer then M.captureTimer:stop(); M.captureTimer = nil end
        M.capture = nil
        if text then M.say(text, GREY, 2) end
    end
    M.captureTap = hs.eventtap.new({ et.keyDown }, function(ev)
        local code = ev:getKeyCode()
        local name = hs.keycodes.map[code]
        if not name then return true end
        if name == "escape" then done("kept " .. M.keyLabel(M.settings.keys[id])); return true end
        local f, mods = ev:getFlags(), {}
        for _, m in ipairs(MOD_ORDER) do if f[m] then mods[#mods + 1] = m end end
        if #mods == 0 and not name:match("^f%d+$") then
            M.say("hold a modifier, or use a function key", GREY, 2)
            return true
        end
        local ok, err = M.setKey(id, mods, name)
        if ok then done("the key is now " .. M.keyLabel(M.settings.keys[id]))
        else M.say(err, GREY, 2.5) end
        return true
    end)
    M.captureTap:start()
    M.captureTimer = hs.timer.doAfter(15, function() done("no key pressed, kept " .. M.keyLabel(M.settings.keys[id])) end)
    M.say("press the keys now on the Mac. Esc keeps " .. M.keyLabel(M.settings.keys[id]), GREY, 15)
    return true
end

function M.resetKeys()
    M.settings.keys = copy(DEFAULT_KEYS)
    M.saveSettings()
    if M.loaded then M.bindKeys() end
    M.say("keys back to the defaults", GREY, 1.6)
    return true
end

------------------------------------------------------------------ the folder

function M.openFolder()
    hs.fs.mkdir(M.dir); hs.fs.mkdir(M.macDir)
    hs.execute("open " .. string.format("%q", M.macDir))
    return true
end

------------------------------------------------------------------ the star's switch

function M.running() return M.loaded end

function M.start()
    if M.loaded then return true, "already running" end
    hs.fs.mkdir(M.dir); hs.fs.mkdir(M.macDir); hs.fs.mkdir(M.imgDir)
    loadSettings()
    M.hotkeys = {}
    if M.settings.current then M.loadMacro(M.settings.current, true) end   -- the one he had chosen
    M.loaded = true
    M.bindKeys()
    -- the settings page, its server and its small window
    local ok, page = pcall(dofile, HERE .. "settings_page.lua")
    if ok and type(page) == "function" then
        local okp, p = pcall(page, M)
        if okp then M.page = p else M.say("settings page failed: " .. tostring(p), GREY, 4) end
    else
        M.say("settings page failed to load: " .. tostring(page), GREY, 4)
    end
    return true, "macro recorder listening"
end

function M.stop()
    if M.recording then M.stopRecording() end
    if M.playing   then M.stopPlaying()   end
    if M.captureTap then M.captureTap:stop(); M.captureTap = nil end
    if M.captureTimer then M.captureTimer:stop(); M.captureTimer = nil end
    if M.noteTimer then M.noteTimer:stop(); M.noteTimer = nil end
    if M.zoneTask then pcall(function() M.zoneTask:terminate() end); M.zoneTask = nil end
    spinnerKill()
    M.capture = nil
    M.unbindKeys()
    if M.page and M.page.stop then pcall(M.page.stop) end
    M.page = nil
    if M.badge  then M.badge:delete();  M.badge  = nil end
    star(nil)
    M.loaded = false
    return true, "macro recorder stopped"
end

------------------------------------------------------------------ the star's submenu

-- Built fresh each time the menu opens so every check mark is the current
-- value. The folder is the top item, his request 5.9.2026; then the two ways
-- into the settings page; then the player, the slots, the playback settings.
function M.menu()
    local K = M.settings.keys
    local rows = {}
    rows[#rows + 1] = { title = "Open the macros folder", fn = M.openFolder }
    rows[#rows + 1] = { title = "Settings, small window   " .. M.keyLabel(K.settings),
                        fn = function() if M.page then M.page.small() end end, disabled = (M.page == nil) }
    rows[#rows + 1] = { title = "Settings, in the browser",
                        fn = function() if M.page then M.page.big() end end, disabled = (M.page == nil) }
    rows[#rows + 1] = { title = "Script editor" .. (M.current and ("  (" .. M.current .. ")") or ""),
                        fn = function() if M.page then M.page.editor(M.current) end end, disabled = (M.page == nil or M.current == nil) }
    rows[#rows + 1] = { title = "The language, documentation",
                        fn = function() if M.page then M.page.docs() end end, disabled = (M.page == nil) }
    rows[#rows + 1] = { title = "-" }
    rows[#rows + 1] = { title = "In the player: " .. (M.current or ((M.text and M.text ~= "") and "last recording") or "nothing"), disabled = true }
    rows[#rows + 1] = { title = "Record   " .. M.keyLabel(K.record), fn = M.toggleRecording }
    local canPlay = (M.text and M.text ~= "") or hs.fs.attributes(M.lastFile) ~= nil
    rows[#rows + 1] = { title = "Play   " .. M.keyLabel(K.play), fn = M.togglePlay, disabled = not canPlay }
    rows[#rows + 1] = { title = "Stop   " .. M.keyLabel(K.stop), fn = M.stopAll, disabled = not (M.recording or M.playing) }
    rows[#rows + 1] = { title = "New Macro…   " .. M.keyLabel(K.newMacro), fn = M.newMacro }
    local names = M.listMacros()
    local sub = {}
    for _, nm in ipairs(names) do
        sub[#sub + 1] = { title = nm, checked = (M.current == nm), fn = function() M.loadMacro(nm) end }
    end
    if #sub == 0 then sub[1] = { title = "(none yet)", disabled = true } end
    rows[#rows + 1] = { title = "Load Macro", menu = sub }
    -- the slots: load with the load chord, run with the run chord
    local slots = {}
    slots[#slots + 1] = { title = M.modsLabel(K.loadMods) .. "digit loads, " .. M.modsLabel(K.runMods) .. "digit runs", disabled = true }
    for _, r in ipairs(SLOTS.rows(M.settings.slots)) do
        local s = r.slot
        slots[#slots + 1] = { title = s .. "   " .. (r.name or "empty"), disabled = (r.name == nil),
                              checked = (r.name ~= nil and M.current == r.name),
                              fn = function() M.loadSlot(s) end }
    end
    rows[#rows + 1] = { title = "Slots", menu = slots }
    rows[#rows + 1] = { title = "-" }
    rows[#rows + 1] = { title = "Speed", disabled = true }
    for _, v in ipairs(M.SPEEDS) do
        rows[#rows + 1] = { title = "  " .. tostring(v) .. "x", checked = (M.settings.speed == v),
                            fn = function() M.setSpeed(v) end }
    end
    rows[#rows + 1] = { title = "-" }
    rows[#rows + 1] = { title = "Delay between clicks", disabled = true }
    for _, v in ipairs(M.DELAYS) do
        local label = v == 0 and "  as recorded" or ("  " .. tostring(v) .. " s")
        rows[#rows + 1] = { title = label, checked = (M.settings.clickDelay == v),
                            fn = function() M.setDelay(v) end }
    end
    return rows
end

M._defaults = DEFAULT_KEYS
MACRO = M     -- global on purpose, like the other apps, so `hs -c` can reach it
return M
