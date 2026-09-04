-- tests/test_schedule.lua
--
-- TEST 1: the mechanism alone, in plain lua5.4, no Hammerspoon. Loads macro.lua
-- against a stub `hs` and checks the schedule, which is what the three settings
-- act on. Run: lua5.4 tests/test_schedule.lua

local Stub = {}
Stub.__index  = function() return setmetatable({}, Stub) end
Stub.__call   = function() return setmetatable({}, Stub) end
Stub.__concat = function(a, b) return (type(a)=="string" and a or "") .. (type(b)=="string" and b or "") end
local function stub() return setmetatable({}, Stub) end
hs = stub()
hs.keycodes = { map = { r = 15, p = 35 } }
hs.eventtap = { event = { types = {
    keyDown=10, keyUp=11, leftMouseDown=1, leftMouseUp=2, rightMouseDown=3, rightMouseUp=4,
    otherMouseDown=25, otherMouseUp=26, mouseMoved=5, leftMouseDragged=6, rightMouseDragged=7,
    otherMouseDragged=27, scrollWheel=22 }, properties = {} } }
hs.json = { read = function() error("none") end, write = function() return true end }
hs.fs = { mkdir = function() end, attributes = function() return nil end }

local HERE = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local M = dofile(HERE .. "../macro.lua")

local fails = 0
local function eq(a, b, what)
    if math.abs(a - b) > 1e-6 then fails = fails + 1; print("FAIL " .. what .. ": " .. a .. " ~= " .. b)
    else print("ok   " .. what) end
end

local rec = {
    { t = 0.0, kind = "mouseMoved",    x = 1, y = 1 },
    { t = 1.0, kind = "leftMouseDown", x = 10, y = 10 },
    { t = 1.1, kind = "leftMouseUp",   x = 10, y = 10 },
    { t = 2.0, kind = "mouseMoved",    x = 20, y = 20 },
    { t = 3.0, kind = "keyDown", code = 0 },
    { t = 3.1, kind = "keyUp",   code = 0 },
    { t = 5.0, kind = "leftMouseDown", x = 30, y = 30 },
    { t = 5.1, kind = "leftMouseUp",   x = 30, y = 30 },
    { t = 6.0, kind = "keyDown", code = 1 },
}

-- as recorded
local p = M.schedule(rec, { speed = 1, ignoreTravel = false, clickDelay = 0 })
eq(#p, 9, "all events kept")
eq(p[7].at, 5.0, "second click at its own time")

-- speed
p = M.schedule(rec, { speed = 2, ignoreTravel = false, clickDelay = 0 })
eq(p[7].at, 2.5, "speed 2 halves the time")
eq(p[9].at, 3.0, "last event at speed 2")

-- ignore travel
p = M.schedule(rec, { speed = 1, ignoreTravel = true, clickDelay = 0 })
eq(#p, 7, "mouseMoved dropped")
eq(p[1].at, 1.0, "first kept event is the click")
local dragged = M.schedule({ { t = 0, kind = "leftMouseDragged", x = 1, y = 1 } }, { ignoreTravel = true })
eq(#dragged, 1, "drags are kept")

-- rhythm: clicks 0.5 s apart
p = M.schedule(rec, { speed = 1, ignoreTravel = false, clickDelay = 0.5 })
eq(p[2].at, 1.0, "first click keeps its own time")
eq(p[7].at, 1.5, "second click exactly 0.5 s later")
eq(p[3].at, 1.0 + (0.1 / 4.0) * 0.5, "mouse up fitted into the gap in proportion")
eq(p[5].at, 1.0 + (2.0 / 4.0) * 0.5, "key between clicks fitted in proportion")
eq(p[8].at, 1.5 + 0.1, "after the last click: own timing")
eq(p[9].at, 1.5 + 1.0, "tail keeps its distance")
for i = 2, #p do
    if p[i].at < p[i-1].at - 1e-9 then fails = fails + 1; print("FAIL order broken at " .. i) end
end
print("ok   order kept under rhythm")

-- rhythm and speed together
p = M.schedule(rec, { speed = 2, ignoreTravel = true, clickDelay = 1 })
eq(p[1].at, 0.5, "before the first click at speed")
eq(p[5].at, 1.5, "second click one second after the first")
eq(p[7].at, 1.5 + 0.5, "tail at speed 2")

-- three clicks, same rhythm
local three = {
    { t = 0, kind = "leftMouseDown" }, { t = 0.1, kind = "leftMouseUp" },
    { t = 4, kind = "leftMouseDown" }, { t = 4.1, kind = "leftMouseUp" },
    { t = 4.5, kind = "leftMouseDown" }, { t = 4.6, kind = "leftMouseUp" },
}
p = M.schedule(three, { clickDelay = 0.25 })
eq(p[3].at, 0.25, "click 2 at 0.25")
eq(p[5].at, 0.5, "click 3 at 0.5: one rhythm")

-- no clicks at all: plain speed
p = M.schedule({ { t = 0, kind = "keyDown", code = 0 }, { t = 2, kind = "keyUp", code = 0 } }, { speed = 4, clickDelay = 1 })
eq(p[2].at, 0.5, "no clicks: speed alone")

-- empty
eq(#M.schedule({}, {}), 0, "empty recording")
eq(#M.schedule(nil, {}), 0, "nil recording")

if fails > 0 then print(fails .. " FAILED"); os.exit(1) end
print("ALL PASSED")
