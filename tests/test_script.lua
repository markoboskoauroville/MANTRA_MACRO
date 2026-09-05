-- tests/test_script.lua
--
-- TEST 3: the script language alone, in plain lua5.4, no Hammerspoon. A fake
-- host writes down every click, key, sleep and image search it is asked for,
-- and the test reads the log. Run: lua5.4 tests/test_script.lua

local HERE = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local S = dofile(HERE .. "../script.lua")

local fails = 0
local function ok(cond, what)
    if cond then print("ok   " .. what) else fails = fails + 1; print("FAIL " .. what) end
end

-- THE FAKE HOST: a log of everything, a clock that Sleep advances, a screen
-- with one picture on it.
local function newHost()
    local H = { log = {}, t = 0, clip = "", images = { ["button.png"] = { x = 100, y = 200, w = 40, h = 20 } }, said = {} }
    local function put(s) H.log[#H.log + 1] = s end
    H.sleep = function(sec) H.t = H.t + sec; if sec > 0 then put("sleep " .. sec) end end
    H.now = function() return H.t end
    H.mouseMove = function(x, y) put("move " .. x .. "," .. y) end
    H.click = function(button, x, y, times, mods)
        put("click " .. button .. (x and (" " .. x .. "," .. y) or "") .. (times > 1 and (" x" .. times) or "") .. (#mods > 0 and (" " .. table.concat(mods, "+")) or ""))
    end
    H.buttonDownUp = function(button, ud, x, y) put(button .. " " .. ud) end
    H.drag = function(button, x1, y1, x2, y2) put("drag " .. x1 .. "," .. y1 .. ">" .. x2 .. "," .. y2) end
    H.mousePos = function() return 7, 9 end
    H.key = function(mods, key) put("key " .. (#mods > 0 and (table.concat(mods, "+") .. "+") or "") .. key) end
    H.keyDownUp = function(key, down) put("key " .. key .. (down and " down" or " up")) end
    H.type = function(text) put("type " .. text) end
    H.wheel = function(dir, times) put("wheel " .. dir .. " " .. times) end
    H.imageSearch = function(file) local r = H.images[file]; if r then put("found " .. file) else put("missed " .. file) end return r end
    H.pixel = function(x, y) return "0x112233" end
    H.say = function(text) H.said[#H.said + 1] = text end
    H.run = function(what) put("run " .. what) end
    H.activate = function(title) put("activate " .. title); return title == "Chrome" end
    H.winExists = function(title) return title == "Chrome" end
    H.clipboard = function() return H.clip end
    H.setClipboard = function(v) H.clip = v end
    H.screen = function() return 1440, 900 end
    H.fileExist = function() return false end
    return H
end

local function run(src, host)
    host = host or newHost()
    local prog, err = S.parse(src)
    if not prog then return false, "parse: line " .. err.line .. ": " .. err.msg, host end
    local okr, msg = S.run(prog, host)
    return okr, msg, host
end
local function logs(host) return table.concat(host.log, " | ") end

-- expressions and variables
local r, m, h = run([[
x := 2 + 3 * 4
y := (2 + 3) * 4
s := "a" . "b"
t := "c" "d"
u := x = 14 ? "yes" : "no"
v := 10 // 3
w := 2 ** 3
n := -x + 1
z := "5" + "6"
MsgBox x " " y " " s " " t " " u " " v " " w " " n " " z
]])
ok(r, "expressions run: " .. tostring(m))
ok(h.said[1] == "14 20 ab cd yes 3 8 -13 11", "arithmetic, concat, ternary, floor division: " .. tostring(h.said[1]))

-- if, else if, else; comparisons; and/or/not
r, m, h = run([[
a := 5
if a > 10 {
    MsgBox "big"
} else if a > 3 {
    MsgBox "middle"
} else {
    MsgBox "small"
}
if (a = 5 and not a = 6)
    MsgBox "one-liner"
if "abc" = "ABC"
    MsgBox "case-insensitive ="
if "abc" == "ABC"
    MsgBox "wrong"
else
    MsgBox "case-sensitive =="
]])
ok(r and h.said[1] == "middle" and h.said[2] == "one-liner" and h.said[3] == "case-insensitive =" and h.said[4] == "case-sensitive ==",
   "if / else if / else, one-liners, string comparison: " .. table.concat(h.said, ","))

-- loops: Loop n with A_Index, While, Break, Continue, Loop until, infinite Loop with Break
r, m, h = run([[
total := 0
Loop 5 {
    if A_Index = 3
        Continue
    total += A_Index
}
i := 0
While i < 10 {
    i++
    if i = 4
        Break
}
k := 0
Loop {
    k += 1
    if k >= 7
        Break
}
j := 0
Loop
    j++
Until j = 3
MsgBox total " " i " " k " " j
]])
ok(r and h.said[1] == "12 4 7 3", "Loop, While, Break, Continue, Until: " .. tostring(m) .. " " .. tostring(h.said[1]))

-- functions, return, by-reference, globals, recursion
r, m, h = run([[
counter := 0
Add(a, b := 10) {
    return a + b
}
Bump(&v) {
    v += 1
}
Count() {
    global counter
    counter += 1
}
Fact(n) {
    if n <= 1
        return 1
    return n * Fact(n - 1)
}
x := 1
Bump(&x)
Bump(&x)
Count()
Count()
MsgBox Add(2, 3) " " Add(5) " " x " " counter " " Fact(5)
]])
ok(r and h.said[1] == "5 15 3 2 120", "functions, defaults, &ref, global, recursion: " .. tostring(m) .. " " .. tostring(h.said[1]))

-- arrays and maps, For
r, m, h = run([[
arr := [10, 20, 30]
arr.Push(40)
sum := 0
For i, v in arr
    sum += v
m := Map("a", 1, "b", 2)
m["c"] := 3
keys := ""
For k, v in m
    keys .= k
last := arr.Pop()
o := {name: "Marko", age: 3}
MsgBox arr.Length " " sum " " keys " " m.Count " " last " " arr[1] " " o["name"] " " m.Has("b") " " m.Has("z")
]])
ok(r and h.said[1] == "3 100 abc 3 40 10 Marko 1 0", "arrays, maps, For, Push/Pop, object literal: " .. tostring(m) .. " " .. tostring(h.said[1]))

-- string functions
r, m, h = run([[
s := "Hello, World"
MsgBox StrLen(s) " " SubStr(s, 1, 5) " " SubStr(s, -5) " " InStr(s, "World") " " StrReplace(s, "l", "L") " " StrUpper("ab") " " Trim("  x  ") " " Format("{1}-{2}", 7, "q") " " Round(3.14159, 2) " " Mod(10, 3) " " Max(1, 9, 4)
parts := StrSplit("a,b,c", ",")
MsgBox parts.Length " " parts[2]
]])
ok(r and h.said[1] == "12 Hello World 8 HeLLo, WorLd AB x 7-q 3.14 1 9", "string and number functions: " .. tostring(m) .. " " .. tostring(h.said[1]))
ok(h.said[2] == "3 b", "StrSplit: " .. tostring(h.said[2]))

-- mouse and keys through the host
r, m, h = run([[
MouseMove 10, 20
Click 30, 40
Click 30, 40, 2
Click 50, 60, "Right"
MouseClick "Left", 70, 80
MouseClickDrag "Left", 1, 2, 3, 4
Sleep 500
Send "hi"
Send "^c"
Send "!{Tab}"
Send "+{Enter}"
Send "#v"
Send "{Enter 2}"
Send "{Ctrl down}a{Ctrl up}"
Send "{WheelDown 3}"
Send "A"
Send "{!}{^}"
SendText "^c"
MouseGetPos &mx, &my
MsgBox mx "," my
]])
ok(r, "mouse and key commands run: " .. tostring(m))
local L = logs(h)
ok(L:find("move 10,20", 1, true) and L:find("click left 30,40 |", 1, true) and L:find("click left 30,40 x2", 1, true) and L:find("click right 50,60", 1, true), "Click forms: " .. L)
ok(L:find("click left 70,80", 1, true) and L:find("drag 1,2>3,4", 1, true), "MouseClick and MouseClickDrag")
ok(L:find("sleep 0.5", 1, true), "Sleep 500 is half a second")
ok(L:find("type hi", 1, true) and L:find("key ctrl+c", 1, true) and L:find("key alt+tab", 1, true) and L:find("key shift+return", 1, true) and L:find("key cmd+v", 1, true), "Send modifiers: ^ ! + #")
ok(L:find("key return | key return", 1, true), "{Enter 2} presses twice")
ok(L:find("key ctrl+a", 1, true), "{Ctrl down}a{Ctrl up} holds ctrl")
ok(L:find("wheel down 3", 1, true), "{WheelDown 3}")
ok(L:find("type A", 1, true), "a capital on its own is typed as text")
ok(L:find("type !^", 1, true), "{!}{^} are literal")
ok(L:find("type ^c", 1, true), "SendText types raw")
ok(h.said[1] == "7,9", "MouseGetPos fills &x, &y: " .. tostring(h.said[1]))

-- image search: found, not found, ClickImage, WaitImage with time out
r, m, h = run([[
if ImageSearch(&fx, &fy, 0, 0, 0, 0, "button.png") {
    Click fx + 20, fy + 10
}
if !ImageSearch(&gx, &gy, 0, 0, 0, 0, "gone.png")
    MsgBox "gone is not there"
hit := ClickImage("button.png")
miss := ClickImage("gone.png", 1)
w := WaitImage("gone.png", 1)
c := FindImage("button.png")
MsgBox hit " " miss " " w " " c[1] "," c[2] " " ImageExist("button.png")
]])
ok(r, "image commands run: " .. tostring(m))
L = logs(h)
ok(L:find("found button.png | click left 120,210", 1, true), "ImageSearch top-left, then Click at an offset: " .. L:sub(1, 80))
ok(h.said[1] == "gone is not there", "a missing picture returns 0")
ok(L:find("click left 120,210 | missed gone.png", 1, true), "ClickImage clicks the centre")
ok(h.said[2] == "1 0 0 120,210 1", "ClickImage/WaitImage/FindImage/ImageExist results: " .. tostring(h.said[2]))
ok(h.t >= 2, "the waits took their time: " .. h.t .. " s")

-- built-in variables, clipboard, windows, run
r, m, h = run([[
A_Clipboard := "copied"
Run "https://example.com"
WinActivate "Chrome"
MsgBox A_ScreenWidth "x" A_ScreenHeight " " A_Clipboard " " WinExist("Chrome") WinExist("Nope") " " A_MouseX
]])
ok(r and h.said[1] == "1440x900 copied 10 7", "A_ variables, clipboard, WinExist: " .. tostring(m) .. " " .. tostring(h.said[1]))
ok(logs(h):find("run https://example.com | activate Chrome", 1, true), "Run and WinActivate reach the host")

-- directives and comments are harmless; hotkeys are refused; errors carry the line
r, m = run([[
#Requires AutoHotkey v2.0
#SingleInstance Force
; a comment
SendMode "Input"
/* block
   comment */
x := 1 ; trailing comment
]])
ok(r, "directives and comments pass: " .. tostring(m))
r, m = run("x := 1\n^r::\n")
ok(not r and m:find("hotkeys belong to the slots", 1, true), "a hotkey label is refused with a reason: " .. tostring(m))
r, m = run("x := 1\ny := x +\n")
ok(not r and m:find("line 2", 1, true), "a parse error names the line: " .. tostring(m))
r, m = run("Sleep 100\nNoSuchThing 1, 2\n")
ok(not r and m:find("line 2", 1, true) and m:find("NoSuchThing", 1, true), "an unknown command names the line: " .. tostring(m))
r, m = run('x := "a" + 1\n')
ok(not r and m:find("needs a number", 1, true), "text in arithmetic is refused: " .. tostring(m))
r, m = run("Loop Parse, x\n{\n}\n")
ok(not r and m:find("Loop Parse", 1, true), "Loop Parse says it is not here")

-- a tight loop with no Sleep still yields to the host now and then
r, m, h = run("Loop 2000 {\n  x := A_Index\n}\n")
ok(r, "2000 turns run")

-- ExitApp stops the script
r, m, h = run('MsgBox "one"\nExitApp\nMsgBox "two"\n')
ok(r and #h.said == 1, "ExitApp stops: " .. #h.said .. " said")

-- FROM EVENTS: a recording becomes a script
local NAMES = { [0] = "a", [1] = "s", [8] = "c", [36] = "return", [48] = "tab", [9] = "v", [49] = "space" }
local rec = {
    { t = 0.00, kind = "mouseMoved", x = 1, y = 1, mods = {} },
    { t = 0.50, kind = "leftMouseDown", x = 100, y = 200, mods = {} },
    { t = 0.58, kind = "leftMouseUp",   x = 100, y = 200, mods = {} },
    { t = 1.00, kind = "keyDown", code = 8, mods = { "cmd" } },
    { t = 1.05, kind = "keyUp",   code = 8, mods = { "cmd" } },
    { t = 1.50, kind = "keyDown", code = 0, mods = {} },
    { t = 1.55, kind = "keyUp",   code = 0, mods = {} },
    { t = 1.60, kind = "keyDown", code = 1, mods = { "shift" } },
    { t = 1.65, kind = "keyUp",   code = 1, mods = { "shift" } },
    { t = 1.70, kind = "keyDown", code = 49, mods = {} },
    { t = 1.75, kind = "keyUp",   code = 49, mods = {} },
    { t = 1.80, kind = "keyDown", code = 36, mods = {} },
    { t = 1.85, kind = "keyUp",   code = 36, mods = {} },
    { t = 2.50, kind = "leftMouseDown", x = 300, y = 300, mods = {} },
    { t = 2.60, kind = "leftMouseDragged", x = 350, y = 320, mods = {} },
    { t = 2.70, kind = "leftMouseUp",   x = 400, y = 340, mods = {} },
    { t = 3.00, kind = "rightMouseDown", x = 50, y = 60, mods = {} },
    { t = 3.05, kind = "rightMouseUp",   x = 50, y = 60, mods = {} },
    { t = 3.50, kind = "leftMouseDown", x = 10, y = 10, mods = {} },
    { t = 3.55, kind = "leftMouseUp",   x = 10, y = 10, mods = {} },
    { t = 3.65, kind = "leftMouseDown", x = 10, y = 10, mods = {} },
    { t = 3.70, kind = "leftMouseUp",   x = 10, y = 10, mods = {} },
    { t = 4.00, kind = "scrollWheel", x = 500, y = 500, dy = -95, dx = 0, mods = {} },
    { t = 4.10, kind = "scrollWheel", x = 500, y = 500, dy = -30, dx = 0, mods = {} },
    { t = 4.50, kind = "leftMouseDown", x = 20, y = 20, mods = { "shift" } },
    { t = 4.55, kind = "leftMouseUp",   x = 20, y = 20, mods = { "shift" } },
}
local text = S.fromEvents(rec, NAMES, { "test macro" })
print(text)
ok(text:find("; test macro\nSleep 500\nClick 100, 200\n", 1, true), "a click with its wait before it")
ok(text:find('Send "#c"', 1, true), "cmd+c becomes Send \"#c\"")
ok(text:find('Send "aS {Enter}"', 1, true), "typed text joins, shift makes a capital, Enter is a key")
ok(text:find('MouseClickDrag "Left", 300, 300, 400, 340', 1, true), "a drag")
ok(text:find('Click 50, 60, "Right"', 1, true), "a right click")
ok(text:find("Click 10, 10, 2", 1, true), "a double click")
ok(text:find('MouseMove 500, 500\nSend "{WheelDown 4}"', 1, true), "two scrolls join into one wheel")
ok(text:find('Send "{Shift down}"\nClick 20, 20\nSend "{Shift up}"', 1, true), "a shift-click holds shift around the click")
-- and the script it made runs
r, m, h = run(text)
ok(r, "the generated script runs: " .. tostring(m))
ok(logs(h):find("click left 100,200 | sleep 0.42 | key cmd+c", 1, true), "and does the same things: " .. logs(h):sub(1, 60))
ok(logs(h):find("click left 20,20 shift", 1, true), "shift-click plays with shift held")

print(fails == 0 and "\nALL OK" or ("\n" .. fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
