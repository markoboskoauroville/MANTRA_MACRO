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
-- THE FILES, all under ~/.mantra_macro:
--   settings.json          speed, ignoreTravel, clickDelay, the keys, the slots
--   macros/<name>.json     the named macros. Any name; rename on disk or here.
--   last.json              the plain last recording, what Play plays with no macro chosen
--   recordings/<date>.json every recording ever made, kept
--   trash/<name>.json      a macro removed from the page goes here, never deleted
--
-- THE THREE PARTS of the code: this file (record, play, keys, slots, the star's
-- submenu), slots.lua (the ten slots, pure Lua, tested) and settings_page.lua
-- (the web page, its server, the small window). The page is loaded on start
-- and let go on stop, like everything else.
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

local SLOTS = dofile(HERE .. "slots.lua")
M.SLOTS = SLOTS

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
               keys = copy(DEFAULT_KEYS), slots = {} }
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
            else
                M.settings[k] = v
            end
        end
    end
    M.settings.slots = SLOTS.normalise(M.settings.slots)
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
    local w = math.max(70, math.min(320, 34 + #text * 7))
    local h = 24
    M.badge:frame({ x = f.x + f.w - w - 10, y = f.y + f.h - h - 10, w = w, h = h })
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
    pcall(hs.json.write, rec, M.file, false, true)
    pcall(hs.json.write, rec, M.recDir .. "/" .. M.croName() .. ".json", false, true)
    if M.pending then
        hs.fs.mkdir(M.macDir)
        pcall(hs.json.write, rec, M.macDir .. "/" .. M.pending .. ".json", false, true)
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

local function pathOf(name) return M.macDir .. "/" .. name .. ".json" end

function M.listMacros()
    local names = {}
    if hs.fs.attributes(M.macDir) then
        for f in hs.fs.dir(M.macDir) do
            local n = f:match("^(.+)%.json$")
            if n and f:sub(1, 1) ~= "." then names[#names + 1] = n end
        end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

-- EVERYTHING THE PAGE NEEDS TO KNOW ABOUT EACH MACRO: name, how many events,
-- when it was recorded, which slot. Read from disk each time it is asked for,
-- so a rename or a new file in the folder shows on the next poll; the event
-- count is cached by the file's modification time so a big macro is not
-- parsed once a second.
M.infoCache = {}
function M.macroInfo()
    local out, cache = {}, M.infoCache or {}
    local fresh = {}
    for _, n in ipairs(M.listMacros()) do
        local p = pathOf(n)
        local a = hs.fs.attributes(p)
        local mtime = a and a.modification or 0
        local c = cache[n]
        if not c or c.mtime ~= mtime then
            c = { mtime = mtime, events = 0, recorded = "", bad = false }
            local ok, rec = pcall(hs.json.read, p)
            if ok and type(rec) == "table" and type(rec.events) == "table" then
                c.events = #rec.events
                c.recorded = tostring(rec.recorded or "")
            else
                c.bad = true
            end
        end
        fresh[n] = c
        out[#out + 1] = { name = n, events = c.events, recorded = c.recorded, bad = c.bad,
                          slot = SLOTS.slotOf(M.settings.slots, n),
                          inPlayer = (M.current == n) }
    end
    M.infoCache = fresh
    return out
end

function M.exists(name)
    return name ~= nil and name ~= "" and hs.fs.attributes(pathOf(name)) ~= nil
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
    local path = pathOf(name)
    if not hs.fs.attributes(path) then
        if not quiet then M.say("no macro called " .. name, GREY, 2) end
        return false, "no macro called " .. name
    end
    local ok, rec = pcall(hs.json.read, path)
    if not ok or type(rec) ~= "table" or type(rec.events) ~= "table" then
        if not quiet then M.say("cannot read " .. name, GREY, 2) end
        return false, "cannot read " .. name
    end
    M.events  = rec.events
    M.current = name
    M.settings.current = name
    M.saveSettings()
    if not quiet then M.say("in the player: " .. name, GREY, 1.4) end
    return true, "loaded " .. name .. " (" .. #rec.events .. " events)"
end

-- RENAME, from the page. The file moves on disk, the slot follows, the player
-- follows. A name that is already taken is refused rather than overwritten.
function M.renameMacro(old, new)
    new = M.cleanName(new)
    if new == "" then return false, "no name" end
    if new == old then return true, "same name" end
    if not M.exists(old) then return false, "no macro called " .. tostring(old) end
    if M.exists(new) then return false, "there is already a macro called " .. new end
    local ok, err = os.rename(pathOf(old), pathOf(new))
    if not ok then return false, "could not rename: " .. tostring(err) end
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
    local dest = M.trashDir .. "/" .. name .. ".json"
    if hs.fs.attributes(dest) then dest = M.trashDir .. "/" .. name .. " " .. os.date("%Y%m%d-%H%M%S") .. ".json" end
    local ok, err = os.rename(pathOf(name), dest)
    if not ok then return false, "could not move: " .. tostring(err) end
    SLOTS.remove(M.settings.slots, name)
    if M.current == name then M.current = nil; M.settings.current = nil; M.events = nil end
    M.saveSettings()
    M.infoCache = nil
    M.say(name .. " moved to the trash folder", GREY, 1.6)
    return true, "moved to trash"
end

function M.toggleRecording()
    if M.recording then M.stopRecording() else M.startRecording() end
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
    if M.playing then M.stopPlaying() end
    if M.recording then M.stopRecording() end
    local ok, err = M.loadMacro(name, true)
    if not ok then M.say(err, GREY, 2); return false, err end
    return M.play()
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

local function post(ev)
    local mods = ev.mods or {}
    if ev.kind == "keyDown" or ev.kind == "keyUp" then
        hs.eventtap.event.newKeyEvent(mods, ev.code, ev.kind == "keyDown"):post()
    elseif ev.kind == "scrollWheel" then
        hs.eventtap.event.newScrollEvent({ ev.dx or 0, ev.dy or 0 }, mods, "pixel"):post()
    else
        local e = hs.eventtap.event.newMouseEvent(et[ev.kind], { x = ev.x, y = ev.y }, mods)
        if ev.button then e:setProperty(hs.eventtap.event.properties.mouseEventButtonNumber, ev.button) end
        e:post()
    end
end

function M.loadRecording()
    if M.events and #M.events > 0 then return M.events end
    if not hs.fs.attributes(M.file) then return nil end
    local ok, rec = pcall(hs.json.read, M.file)
    if ok and type(rec) == "table" and type(rec.events) == "table" then
        M.events = rec.events
        return M.events
    end
    return nil
end

function M.play()
    if M.recording then M.stopRecording() end
    local evs = M.loadRecording()
    if not evs or #evs == 0 then
        M.say("nothing in the player yet", GREY, 1.4)
        return false, "nothing recorded yet"
    end
    local plan = M.schedule(evs, M.settings)
    M.playing = true
    badge("PLAY" .. (M.current and ("  " .. M.current) or ""), { red = 0.3, green = 0.85, blue = 0.4, alpha = 1 })
    star("green")
    local start = now()
    local i = 1
    local function step()
        if not M.playing then return end
        local elapsed = now() - start
        while i <= #plan and plan[i].at <= elapsed do
            pcall(post, plan[i].ev)
            i = i + 1
        end
        if i > #plan then M.stopPlaying(); return end
        local wait = plan[i].at - (now() - start)
        if wait < 0.001 then wait = 0.001 end
        M.timer = hs.timer.doAfter(wait, step)
    end
    step()
    return true, "playing " .. #plan .. " events"
end

function M.stopPlaying()
    M.playing = false
    if M.timer then M.timer:stop(); M.timer = nil end
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
    hs.fs.mkdir(M.dir); hs.fs.mkdir(M.macDir)
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
    rows[#rows + 1] = { title = "-" }
    rows[#rows + 1] = { title = "In the player: " .. (M.current or (M.events and #M.events > 0 and "last recording") or "nothing"), disabled = true }
    rows[#rows + 1] = { title = "Record   " .. M.keyLabel(K.record), fn = M.toggleRecording }
    local n = (M.events and #M.events) or 0
    rows[#rows + 1] = { title = "Play   " .. M.keyLabel(K.play), fn = M.togglePlay, disabled = (n == 0 and not hs.fs.attributes(M.file)) }
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
    rows[#rows + 1] = { title = "Ignore mouse travel", checked = M.settings.ignoreTravel and true or false,
                        fn = function() M.setIgnore(not M.settings.ignoreTravel) end }
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
