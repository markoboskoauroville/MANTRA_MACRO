-- tests/test_slots.lua
--
-- TEST 2: the slot model alone, in plain lua5.4, no Hammerspoon. Assign, clear,
-- move, swap, rename, remove, auto-place, and the ugly cases: a name in two
-- slots read from a hand-edited file, a move onto itself, a slot that is not
-- one of the ten. Run: lua5.4 tests/test_slots.lua

local HERE = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local S = dofile(HERE .. "../slots.lua")

local fails = 0
local function ok(cond, what)
    if cond then print("ok   " .. what) else fails = fails + 1; print("FAIL " .. what) end
end
local function line(slots)
    local out = {}
    for _, k in ipairs(S.ORDER) do out[#out + 1] = slots[k] or "." end
    return table.concat(out, " ")
end

-- assign and clear
local s = {}
ok(S.assign(s, "1", "a"), "assign a to 1")
ok(S.assign(s, "3", "b"), "assign b to 3")
ok(s["1"] == "a" and s["3"] == "b", "both sit where put: " .. line(s))
ok(S.assign(s, "5", "a"), "a moves to 5")
ok(s["1"] == nil and s["5"] == "a", "a is in one slot only: " .. line(s))
ok(S.assign(s, "3", "c"), "c takes slot 3")
ok(S.slotOf(s, "b") == nil, "b was dropped from 3")
ok(S.clear(s, "5"), "clear 5")
ok(s["5"] == nil, "5 is empty")
ok(not S.assign(s, "11", "x"), "slot 11 refused")
ok(not S.assign(s, "0", ""), "empty name refused")
ok(S.assign(s, 0, "z") and s["0"] == "z", "numeric 0 accepted as slot 0")

-- move: reorder like a list
s = {}
S.assign(s, "1", "a"); S.assign(s, "2", "b"); S.assign(s, "3", "c"); S.assign(s, "4", "d")
ok(S.move(s, "4", "1"), "move 4 to 1")
ok(line(s) == "d a b c . . . . . .", "d first, others shifted down: " .. line(s))
ok(S.move(s, "1", "4"), "move 1 to 4")
ok(line(s) == "a b c d . . . . . .", "back in order: " .. line(s))
ok(S.move(s, "2", "0"), "move 2 to the end")
ok(line(s) == "a c d . . . . . . b", "b at slot 0, gap closed: " .. line(s))
ok(S.move(s, "3", "3"), "move onto itself is fine")
ok(line(s) == "a c d . . . . . . b", "and changes nothing")
ok(S.move(s, "5", "1"), "moving an empty row opens a gap")
ok(line(s) == ". a c d . . . . . b", "gap at 1: " .. line(s))
ok(not S.move(s, "x", "1"), "move from a bad slot refused")

-- swap and neighbours
s = {}
S.assign(s, "1", "a"); S.assign(s, "2", "b")
ok(S.swap(s, "1", "2") and s["1"] == "b" and s["2"] == "a", "swap 1 and 2")
ok(S.neighbour("1", -1) == nil, "nothing above 1")
ok(S.neighbour("9", 1) == "0", "below 9 is 0")
ok(S.neighbour("0", 1) == nil, "nothing below 0")

-- rename and remove keep or free the slot
s = {}
S.assign(s, "7", "old name")
ok(S.rename(s, "old name", "new name") == "7" and s["7"] == "new name", "rename keeps slot 7")
ok(S.remove(s, "new name") == "7" and s["7"] == nil, "remove frees slot 7")
ok(S.remove(s, "never there") == nil, "removing an unknown name does nothing")

-- auto-place: first free slot, never twice
s = {}
ok(S.autoPlace(s, "a") == "1", "first macro lands in 1")
ok(S.autoPlace(s, "b") == "2", "second in 2")
ok(S.autoPlace(s, "a") == nil, "a already placed, nothing happens")
S.clear(s, "1")
ok(S.autoPlace(s, "c") == "1", "the freed 1 is used before 3")
for _, k in ipairs(S.ORDER) do s[k] = "m" .. k end
ok(S.autoPlace(s, "zz") == nil and S.firstFree(s) == nil, "all ten taken: nowhere to go")

-- normalise a hand-edited file
local raw = { ["1"] = "a", ["2"] = "a", ["3"] = 5, ["4"] = "", ["9"] = "b", ["11"] = "c", junk = "d" }
local n = S.normalise(raw)
ok(n["1"] == "a" and n["2"] == nil, "a twice: first slot keeps it")
ok(n["3"] == nil and n["4"] == nil, "a number and an empty string are dropped")
ok(n["9"] == "b" and n["11"] == nil and n.junk == nil, "only the ten slots survive")
ok(next(S.normalise(nil)) == nil, "nil in, empty out")

-- rows for a page, with the missing flag
s = {}
S.assign(s, "1", "here"); S.assign(s, "2", "gone")
local rows = S.rows(s, { here = true })
ok(#rows == 10, "always ten rows")
ok(rows[1].name == "here" and rows[1].missing == false, "row 1 is here")
ok(rows[2].name == "gone" and rows[2].missing == true, "row 2 says missing")
ok(rows[3].name == nil and rows[3].missing == false, "an empty row is not missing")

print(fails == 0 and "\nALL OK" or ("\n" .. fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
