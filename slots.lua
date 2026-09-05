-- slots.lua
--
-- THE TEN SLOTS, pure Lua, no Hammerspoon. Marko's request, 5.9.2026: "option
-- one to zero loads a macro, control one to zero runs it, and I can assign any
-- macro to any slot and rearrange them in the web interface."
--
-- A slot is one of the ten digit keys, in keyboard order 1 2 3 4 5 6 7 8 9 0.
-- The slots table maps a slot ("1" .. "0") to a macro name. A macro sits in at
-- most one slot; putting it in a second one takes it out of the first. Every
-- function here is pure and takes the table it changes, so the whole model is
-- tested in plain lua5.4 (tests/test_slots.lua) with nothing else loaded.

local S = {}

S.ORDER = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" }

local INDEX = {}
for i, k in ipairs(S.ORDER) do INDEX[k] = i end

-- true when `slot` is one of the ten
function S.valid(slot)
    return INDEX[tostring(slot)] ~= nil
end

-- A table read from disk, made safe: only the ten known slots, only string
-- names, no name twice (the first slot in keyboard order keeps it).
function S.normalise(t)
    local out, seen = {}, {}
    if type(t) ~= "table" then return out end
    for _, k in ipairs(S.ORDER) do
        local v = t[k]
        if type(v) == "string" and v ~= "" and not seen[v] then
            out[k] = v
            seen[v] = true
        end
    end
    return out
end

-- The slot a macro sits in, or nil.
function S.slotOf(slots, name)
    for _, k in ipairs(S.ORDER) do
        if slots[k] == name then return k end
    end
    return nil
end

-- Put `name` into `slot`. Whatever was in that slot is dropped; whatever slot
-- `name` sat in before is emptied. Returns true, or false and a reason.
function S.assign(slots, slot, name)
    slot = tostring(slot)
    if not S.valid(slot) then return false, "no slot " .. slot end
    if type(name) ~= "string" or name == "" then return false, "no name" end
    local before = S.slotOf(slots, name)
    if before then slots[before] = nil end
    slots[slot] = name
    return true
end

function S.clear(slots, slot)
    slot = tostring(slot)
    if not S.valid(slot) then return false, "no slot " .. slot end
    slots[slot] = nil
    return true
end

-- Take the macro out of every slot (a deleted macro).
function S.remove(slots, name)
    local k = S.slotOf(slots, name)
    if k then slots[k] = nil end
    return k
end

-- A macro renamed on disk keeps its slot.
function S.rename(slots, old, new)
    local k = S.slotOf(slots, old)
    if k then slots[k] = new end
    return k
end

-- MOVE, the reorder. The macro in slot `from` goes to position `to` and the
-- slots between shift by one to make room, exactly like dragging a row in a
-- list: nothing is lost, only the order changes. An empty `from` moves an
-- empty row, which is a legal way to open a gap.
function S.move(slots, from, to)
    from, to = tostring(from), tostring(to)
    if not S.valid(from) then return false, "no slot " .. from end
    if not S.valid(to)   then return false, "no slot " .. to end
    if from == to then return true end
    local list = {}
    for i, k in ipairs(S.ORDER) do list[i] = slots[k] or false end
    local a, b = INDEX[from], INDEX[to]
    local moving = table.remove(list, a)
    table.insert(list, b, moving)
    for i, k in ipairs(S.ORDER) do slots[k] = list[i] or nil end
    return true
end

-- SWAP two slots outright, for the up and down arrows.
function S.swap(slots, a, b)
    a, b = tostring(a), tostring(b)
    if not S.valid(a) or not S.valid(b) then return false, "no such slot" end
    slots[a], slots[b] = slots[b], slots[a]
    return true
end

-- The slot above or below, in keyboard order, or nil at the ends.
function S.neighbour(slot, dir)
    local i = INDEX[tostring(slot)]
    if not i then return nil end
    return S.ORDER[i + dir]
end

-- The first empty slot, or nil when all ten are taken.
function S.firstFree(slots)
    for _, k in ipairs(S.ORDER) do
        if not slots[k] then return k end
    end
    return nil
end

-- A NEW MACRO LANDS IN THE FIRST FREE SLOT BY ITSELF, so it can be played from
-- the keyboard the moment it is saved, with nothing to set up. Returns the
-- slot, or nil when the macro already has one or none is free.
function S.autoPlace(slots, name)
    if S.slotOf(slots, name) then return nil end
    local k = S.firstFree(slots)
    if k then slots[k] = name end
    return k
end

-- The ten rows in keyboard order, for a page or a menu: {slot=, name=}.
-- `exists` (optional) says which names are still on disk, so a slot that
-- points at a macro renamed or removed outside the interface can say so
-- instead of pretending.
function S.rows(slots, exists)
    local out = {}
    for i, k in ipairs(S.ORDER) do
        local name = slots[k]
        out[i] = { slot = k, name = name,
                   missing = (name ~= nil and exists ~= nil and not exists[name]) or false }
    end
    return out
end

return S
