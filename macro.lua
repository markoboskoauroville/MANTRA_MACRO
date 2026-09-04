-- macro.lua
--
-- THE MACRO RECORDER. Marko's request, 4.9.2026: "It's very simple. It records
-- everything I'm doing and repeating. Control+Option+Command+R records,
-- Control+Option+Command+P plays. When it's checked, it works. It listens to my
-- keyboard and also plays back. In the settings I have speed, I can ignore the
-- traveling of the mouse, I can add a simple delay between clicks of the mouse,
-- and all the clicks are in the same rhythm."
--
-- WHAT IT IS. One eventtap that writes down keys, clicks, drags, scrolls and
-- mouse travel with the time between them; one player that posts them back in
-- the same order. Nothing more. It is started by the star menu and by nothing
-- else, so it listens only while its box is ticked.
--
-- THE THREE SETTINGS, kept in ~/.mantra_macro/settings.json:
--   speed        how many times faster than recorded. 1 is as recorded.
--   ignoreTravel true drops the mouse travel between clicks; the pointer jumps
--                straight to where each click happened. Drags are kept, they
--                are the selection, not the travel.
--   clickDelay   seconds between clicks. 0 is as recorded. Above 0, every click
--                lands exactly clickDelay after the one before, so all the
--                clicks are in one rhythm; what happened between two clicks is
--                squeezed or stretched to fit the gap, in the same order.
--
-- THE RECORDING lives in ~/.mantra_macro/last.json and is what P plays. Every
-- recording is also kept under ~/.mantra_macro/recordings/ by date so nothing
-- he recorded is ever lost by recording again.
--
-- THE STATUS goes small, bottom right of the screen, never mid screen: a red
-- dot with REC while recording, a triangle with PLAY while playing, gone when
-- neither. His rule: never an overlay, never a fright.

local M = { name = "Macro Recorder", key = "macro" }

local HOME = os.getenv("HOME") or ""
M.dir      = HOME .. "/.mantra_macro"
M.file     = M.dir .. "/last.json"
M.recDir   = M.dir .. "/recordings"
M.macDir   = M.dir .. "/macros"        -- the named ones: New Macro, Load Macro
M.setFile  = M.dir .. "/settings.json"

M.MODS   = { "ctrl", "alt", "cmd" }
M.KEY_REC  = "r"
M.KEY_PLAY = "p"

M.settings = { speed = 1, ignoreTravel = false, clickDelay = 0 }
M.SPEEDS = { 0.5, 1, 2, 4, 8 }
M.DELAYS = { 0, 0.25, 0.5, 1, 2 }

M.events    = nil     -- the recording in memory, a list of {t=, kind=, ...}
M.current   = nil     -- the name of the macro in memory, nil for the plain last recording
M.pending   = nil     -- the name a New Macro recording will be saved under
M.recording = false
M.playing   = false
M.loaded    = false   -- the star's running()

------------------------------------------------------------------ settings

local function loadSettings()
    if not hs.fs.attributes(M.setFile) then return end    -- first run: the defaults
    local ok, s = pcall(hs.json.read, M.setFile)
    if ok and type(s) == "table" then
        for k, v in pairs(s) do M.settings[k] = v end
    end
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
                       frame = { x = 22, y = 4, w = 80, h = 16 } }
    end
    local scr = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
    local f = scr:frame()
    local w, h = 70, 24
    M.badge:frame({ x = f.x + f.w - w - 10, y = f.y + f.h - h - 10, w = w, h = h })
    M.badge[2].fillColor = colour
    M.badge[3].text = text
    M.badge:show()
end

local function badgeOff()
    if M.badge then M.badge:hide() end
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

local function hasAllMods(flags)
    return flags and flags.ctrl and flags.alt and flags.cmd and true or false
end

-- The hotkeys that start and stop the recording must not become part of it.
local CODE_R = hs.keycodes.map[M.KEY_REC]
local CODE_P = hs.keycodes.map[M.KEY_PLAY]
local function isOurHotkey(code, flags, sinceStart)
    if code ~= CODE_R and code ~= CODE_P then return false end
    return hasAllMods(flags) or sinceStart < 1.0
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
    badge("REC", { red = 0.95, green = 0.2, blue = 0.2, alpha = 1 })
    star("red")
end

function M.stopRecording()
    M.recording = false
    if M.tap then M.tap:stop(); M.tap = nil end
    badgeOff()
    star(nil)
    local evs = M.events or {}
    -- the modifier keys he pressed to stop are not part of the recording;
    -- anything in the last moment that is one of our keys is dropped.
    while #evs > 0 do
        local last = evs[#evs]
        if (last.kind == "keyDown" or last.kind == "keyUp") and (last.code == CODE_R or last.code == CODE_P) then
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
    else
        M.current = nil
    end
    M.settings.current = M.current
    M.saveSettings()
    return #evs
end

------------------------------------------------------------------ named macros

-- THE NAME A MACRO GETS BY ITSELF, Croatian style, his request 4.9.2026: the
-- day, the month, then the hour. No year, nothing else. "4.9. 18.52". The
-- minutes are there so two macros in one hour do not fall on one name.
function M.croName(t)
    t = t or os.time()
    return os.date("%-d.%-m. %H.%M", t)
end

-- A name safe as a file name: letters, digits, space, dash, underscore, dot.
local function cleanName(name)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("[/\\:%c]", "-")
    return name
end

function M.listMacros()
    local names = {}
    if hs.fs.attributes(M.macDir) then
        for f in hs.fs.dir(M.macDir) do
            local n = f:match("^(.+)%.json$")
            if n then names[#names + 1] = n end
        end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

-- NEW MACRO: ask for a name, then record. The recording is saved under that
-- name when ⌃⌥⌘R stops it, and becomes the one P plays.
function M.newMacro()
    if M.recording then M.stopRecording() end
    if M.playing then M.stopPlaying() end
    local button, text = hs.dialog.textPrompt("New macro", "Name it, then press ⌃⌥⌘R when you are done recording.",
                                              M.croName(), "Record", "Cancel")
    if button ~= "Record" then return false, "cancelled" end
    local name = cleanName(text)
    if name == "" then return false, "no name" end
    M.pending = name
    M.startRecording()
    return true, "recording " .. name
end

-- LOAD MACRO: the named one becomes what P plays.
function M.loadMacro(name)
    local path = M.macDir .. "/" .. name .. ".json"
    if not hs.fs.attributes(path) then return false, "no macro called " .. name end
    local ok, rec = pcall(hs.json.read, path)
    if not ok or type(rec) ~= "table" or type(rec.events) ~= "table" then return false, "cannot read " .. name end
    M.events  = rec.events
    M.current = name
    M.settings.current = name
    M.saveSettings()
    return true, "loaded " .. name .. " (" .. #rec.events .. " events)"
end

function M.toggleRecording()
    if M.recording then M.stopRecording() else M.startRecording() end
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
        badge("EMPTY", { white = 0.6, alpha = 1 })
        hs.timer.doAfter(1.2, badgeOff)
        return false, "nothing recorded yet"
    end
    local plan = M.schedule(evs, M.settings)
    M.playing = true
    badge("PLAY", { red = 0.3, green = 0.85, blue = 0.4, alpha = 1 })
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

------------------------------------------------------------------ the star's switch

function M.running() return M.loaded end

function M.start()
    if M.loaded then return true, "already running" end
    hs.fs.mkdir(M.dir)
    loadSettings()
    if M.settings.current then M.loadMacro(M.settings.current) end   -- the one he had chosen
    M.hkRec  = hs.hotkey.bind(M.MODS, M.KEY_REC,  M.toggleRecording)
    M.hkPlay = hs.hotkey.bind(M.MODS, M.KEY_PLAY, M.togglePlay)
    M.loaded = true
    return true, "macro recorder listening"
end

function M.stop()
    if M.recording then M.stopRecording() end
    if M.playing   then M.stopPlaying()   end
    if M.hkRec  then M.hkRec:delete();  M.hkRec  = nil end
    if M.hkPlay then M.hkPlay:delete(); M.hkPlay = nil end
    if M.badge  then M.badge:delete();  M.badge  = nil end
    star(nil)
    M.loaded = false
    return true, "macro recorder stopped"
end

-- THE SETTINGS SUBMENU for the star. Built fresh each time the menu opens so
-- every check mark is the current value.
function M.menu()
    local rows = {}
    rows[#rows + 1] = { title = "Macro: " .. (M.current or (M.events and #M.events > 0 and "last recording") or "none"), disabled = true }
    rows[#rows + 1] = { title = "New Macro…", fn = M.newMacro }
    local names = M.listMacros()
    local sub = {}
    for _, n in ipairs(names) do
        sub[#sub + 1] = { title = n, checked = (M.current == n), fn = function() M.loadMacro(n) end }
    end
    if #sub == 0 then sub[1] = { title = "(none yet)", disabled = true } end
    rows[#rows + 1] = { title = "Load Macro", menu = sub }
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
    rows[#rows + 1] = { title = "-" }
    local n = (M.events and #M.events) or 0
    rows[#rows + 1] = { title = "Record   ⌃⌥⌘R", fn = M.toggleRecording }
    rows[#rows + 1] = { title = "Play   ⌃⌥⌘P", fn = M.togglePlay, disabled = (n == 0 and not hs.fs.attributes(M.file)) }
    rows[#rows + 1] = { title = "Open the macros folder", fn = function() hs.fs.mkdir(M.macDir); hs.execute("open " .. M.macDir) end }
    return rows
end

MACRO = M     -- global on purpose, like the other apps, so `hs -c` can reach it
return M
