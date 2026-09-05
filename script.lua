-- script.lua
--
-- MANTRA SCRIPT: AutoHotkey v2 syntax on the Mac, pure Lua, no Hammerspoon.
-- Marko's request, 5.9.2026: "a script editor so the user can edit the macros
-- himself. Copy the syntax from AutoHotkey, so the user also learns how to
-- code with AutoHotkey. If statements, loop statements, and all the other
-- features." And: "load screenshots of the buttons, so the app can click by
-- optical recognition of the patterns on my screen."
--
-- WHAT THIS FILE IS. A lexer, a parser to a small tree, and an interpreter
-- that walks the tree. It knows nothing about the screen: every click, key,
-- sleep and image search goes through a HOST table the caller gives it, so
-- the whole language is tested in plain lua5.4 with a fake host
-- (tests/test_script.lua) and Hammerspoon only supplies the real one.
--
-- THE INTERPRETER RUNS INSIDE A COROUTINE. Sleep does not block: the host's
-- sleep yields, the driver in macro.lua resumes it on a timer, and the stop
-- key simply drops the coroutine. Every few hundred statements the
-- interpreter yields on its own, so a tight loop with no Sleep can still be
-- stopped and never freezes Hammerspoon.
--
-- ALSO HERE: fromEvents, which turns a recording into a script (the recorder
-- writes scripts now, not event lists), and parseSend, which reads AutoHotkey
-- Send strings: ^c, !{Tab}, +{Enter}, #v, {Ctrl down}, {WheelDown 3}.
--
-- The language is documented in docs/SCRIPT.md, which the editor serves.

local S = {}

------------------------------------------------------------------ errors

local function fail(line, msg)
    error({ line = line, msg = msg }, 0)
end

------------------------------------------------------------------ lexer

local KEYWORDS = { ["if"] = true, ["else"] = true, ["while"] = true, ["loop"] = true,
                   ["for"] = true, ["in"] = true, ["break"] = true, ["continue"] = true,
                   ["return"] = true, ["and"] = true, ["or"] = true, ["not"] = true,
                   ["true"] = true, ["false"] = true, ["global"] = true, ["local"] = true,
                   ["static"] = true, ["until"] = true }

local OPS = { ":=", "+=", "-=", "*=", "/=", ".=", "//=", "++", "--", "**", "//", "==",
              "!=", "<>", "<=", ">=", "&&", "||", "::", "<", ">", "=", "+", "-", "*",
              "/", ".", ",", "(", ")", "[", "]", "{", "}", "!", "?", ":", "&", "%" }
table.sort(OPS, function(a, b) return #a > #b end)

local ESC = { n = "\n", t = "\t", r = "\r", ["`"] = "`", ['"'] = '"', ["'"] = "'", b = "\b", s = " " }

function S.lex(text)
    local toks, i, line, n = {}, 1, 1, #text
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    n = #text
    local function push(t, v, extra)
        local tk = { type = t, value = v, line = line }
        if extra then for k, x in pairs(extra) do tk[k] = x end end
        toks[#toks + 1] = tk
    end
    local atLineStart = true
    while i <= n do
        local c = text:sub(i, i)
        if atLineStart and c ~= "\n" then
            local lineText = text:match("^[^\n]*", i)
            if lineText:match("^[^%s\"';]+::") then
                fail(line, "hotkeys belong to the slots on the settings page, not inside a macro")
            end
        end
        if c == "\n" then
            push("nl"); line = line + 1; i = i + 1; atLineStart = true
        elseif c == " " or c == "\t" then
            i = i + 1
        elseif c == ";" and (atLineStart or text:sub(i - 1, i - 1):match("[ \t]")) then
            local j = text:find("\n", i, true) or (n + 1)
            i = j
        elseif atLineStart and text:sub(i, i + 1) == "/*" then
            local j = text:find("*/", i, true)
            if not j then fail(line, "a /* comment that never closes") end
            for _ in text:sub(i, j):gmatch("\n") do line = line + 1 end
            i = j + 2
        elseif c == '"' or c == "'" then
            local q, j, buf = c, i + 1, {}
            while true do
                local d = text:sub(j, j)
                if d == "" then fail(line, "a string that never closes") end
                if d == "\n" then fail(line, "a string that never closes") end
                if d == "`" then
                    local e = text:sub(j + 1, j + 1)
                    buf[#buf + 1] = ESC[e] or e
                    j = j + 2
                elseif d == q then
                    if text:sub(j + 1, j + 1) == q then buf[#buf + 1] = q; j = j + 2   -- "" is one "
                    else j = j + 1; break end
                else
                    buf[#buf + 1] = d; j = j + 1
                end
            end
            push("str", table.concat(buf))
            i = j; atLineStart = false
        elseif c:match("%d") or (c == "." and text:sub(i + 1, i + 1):match("%d")) then
            local s = text:match("^0[xX]%x+", i) or text:match("^%d*%.?%d+[eE][-+]?%d+", i) or text:match("^%d*%.?%d+", i) or text:match("^%d+", i)
            push("num", tonumber(s))
            i = i + #s; atLineStart = false
        elseif c:match("[%a_#@$]") then
            local s = text:match("^[%a_#@$][%w_]*", i)
            if s:sub(1, 1) == "#" then
                push("directive", s)
            else
                local lower = s:lower()
                if KEYWORDS[lower] then push("kw", lower, { raw = s }) else push("id", s) end
            end
            i = i + #s; atLineStart = false
        else
            local hit
            for _, op in ipairs(OPS) do
                if text:sub(i, i + #op - 1) == op then hit = op; break end
            end
            if not hit then fail(line, "unexpected character '" .. c .. "'") end
            local before = text:sub(i - 1, i - 1):match("[ \t]") ~= nil or i == 1
            local after  = text:sub(i + #hit, i + #hit):match("[ \t\n]") ~= nil or i + #hit > n
            push("op", hit, { spaced = before and after })
            i = i + #hit; atLineStart = false
        end
    end
    push("nl"); push("eof")
    return toks
end

------------------------------------------------------------------ parser

local ASSIGN_OPS = { [":="] = true, ["+="] = true, ["-="] = true, ["*="] = true, ["/="] = true, [".="] = true, ["//="] = true }

-- commands that take their arguments without brackets: every builtin may be
-- written `Name arg, arg` on its own line, the AutoHotkey way.
function S.parse(text)
    local okl, toks = pcall(S.lex, text)
    if not okl then
        if type(toks) == "table" and toks.msg then return nil, toks end
        return nil, { line = 0, msg = tostring(toks) }
    end
    local p = 1
    local function peek(k) return toks[p + (k or 0)] end
    local function nextTok() local t = toks[p]; p = p + 1; return t end
    local function isOp(t, v) return t and t.type == "op" and t.value == v end
    local function isKw(t, v) return t and t.type == "kw" and t.value == v end
    local function skipNl() while peek().type == "nl" do p = p + 1 end end
    local function expectOp(v)
        local t = nextTok()
        if not isOp(t, v) then fail(t.line, "expected '" .. v .. "'" .. (t.value and (" near '" .. tostring(t.value) .. "'") or "")) end
        return t
    end
    local function endOfStatement()
        local t = peek()
        if t.type == "nl" or t.type == "eof" then return end
        if isOp(t, "}") then return end
        fail(t.line, "unexpected '" .. tostring(t.value) .. "'")
    end

    local parseExpr, parseStatement, parseBlockOrStatement

    local function parseArgs(closer)
        -- comma separated expressions; &name is a reference
        -- inside brackets newlines are nothing; in command style the line is the statement
        local args = {}
        local function nl() if closer then skipNl() end end
        nl()
        if closer and isOp(peek(), closer) then return args end
        while true do
            nl()
            local t = peek()
            if isOp(t, "&") and peek(1).type == "id" then
                nextTok(); local id = nextTok()
                args[#args + 1] = { type = "ref", name = id.value, line = id.line }
            elseif isOp(t, ",") then
                args[#args + 1] = { type = "empty", line = t.line }      -- a left-out argument
            else
                args[#args + 1] = parseExpr()
            end
            nl()
            if isOp(peek(), ",") then nextTok()
            else break end
        end
        return args
    end

    local function parsePrimary()
        local t = nextTok()
        if t.type == "num" then return { type = "num", value = t.value, line = t.line } end
        if t.type == "str" then return { type = "str", value = t.value, line = t.line } end
        if t.type == "kw" and (t.value == "true" or t.value == "false") then
            return { type = "num", value = t.value == "true" and 1 or 0, line = t.line }
        end
        if t.type == "kw" and t.value == "not" then
            return { type = "un", op = "!", e = parseExpr(4), line = t.line }
        end
        if t.type == "id" then
            if isOp(peek(), "(") then
                nextTok()
                local args = parseArgs(")")
                skipNl(); expectOp(")")
                return { type = "call", name = t.value, args = args, line = t.line }
            end
            return { type = "var", name = t.value, line = t.line }
        end
        if isOp(t, "(") then
            skipNl()
            local e = parseExpr()
            skipNl(); expectOp(")")
            return e
        end
        if isOp(t, "[") then
            local items = parseArgs("]")
            skipNl(); expectOp("]")
            return { type = "array", items = items, line = t.line }
        end
        if isOp(t, "{") then
            -- an object literal {a: 1, b: 2} becomes a Map
            local pairs_ = {}
            skipNl()
            while not isOp(peek(), "}") do
                local k = nextTok()
                if k.type ~= "id" and k.type ~= "str" and k.type ~= "kw" then fail(k.line, "expected a name in {}") end
                expectOp(":")
                pairs_[#pairs_ + 1] = { key = k.raw or k.value, value = parseExpr() }
                skipNl()
                if isOp(peek(), ",") then nextTok(); skipNl() end
            end
            expectOp("}")
            return { type = "object", pairs = pairs_, line = t.line }
        end
        if isOp(t, "-") then return { type = "un", op = "-", e = parseExpr(12), line = t.line } end
        if isOp(t, "+") then return parseExpr(12) end
        if isOp(t, "!") then return { type = "un", op = "!", e = parseExpr(12), line = t.line } end
        if isOp(t, "&") and peek().type == "id" then
            local id = nextTok()
            return { type = "ref", name = id.value, line = id.line }
        end
        if isOp(t, "++") or isOp(t, "--") then
            local id = nextTok()
            if id.type ~= "id" then fail(t.line, "expected a variable after " .. t.value) end
            return { type = "preinc", name = id.value, op = t.value, line = t.line }
        end
        if t.type == "eof" or t.type == "nl" then
            local k = p - 2
            while k > 0 and toks[k].type == "nl" do k = k - 1 end
            local prev = toks[k]
            fail(prev and prev.line or t.line, "the line ends too soon; something is missing after the last operator")
        end
        fail(t.line, "unexpected '" .. tostring(t.value) .. "'")
    end

    local function parsePostfix()
        local e = parsePrimary()
        while true do
            local t = peek()
            if isOp(t, "[") then
                nextTok(); skipNl()
                local idx = parseExpr()
                skipNl(); expectOp("]")
                e = { type = "index", obj = e, idx = idx, line = t.line }
            elseif isOp(t, ".") and not t.spaced and peek(1).type == "id" then
                nextTok(); local name = nextTok()
                if isOp(peek(), "(") then
                    nextTok()
                    local args = parseArgs(")")
                    skipNl(); expectOp(")")
                    e = { type = "mcall", obj = e, name = name.value, args = args, line = t.line }
                else
                    e = { type = "member", obj = e, name = name.value, line = t.line }
                end
            elseif (isOp(t, "++") or isOp(t, "--")) and e.type == "var" then
                nextTok()
                e = { type = "postinc", name = e.name, op = t.value, line = t.line }
            else
                return e
            end
        end
    end

    -- precedence climbing. Levels: 1 ?: · 2 || or · 3 && and · 4 ! not · 5 comparison ·
    -- 6 concat · 7 + - · 8 * / // · 9 ** · 12 unary
    local BIN = {
        ["||"] = 2, ["or"] = 2, ["&&"] = 3, ["and"] = 3,
        ["="] = 5, ["=="] = 5, ["!="] = 5, ["<>"] = 5, ["<"] = 5, [">"] = 5, ["<="] = 5, [">="] = 5,
        ["."] = 6, ["+"] = 7, ["-"] = 7, ["*"] = 8, ["/"] = 8, ["//"] = 8, ["**"] = 9,
    }
    local function binOp(t)
        if t.type == "op" and BIN[t.value] then
            if t.value == "." and not t.spaced then return nil end   -- a.b is a member, handled above
            return t.value
        end
        if t.type == "kw" and (t.value == "and" or t.value == "or") then return t.value end
        return nil
    end

    -- juxtaposition: `"a" b` is a concat in AutoHotkey. Two values with nothing
    -- between them, on one line, join.
    local function juxtaposes(t)
        return t.type == "str" or t.type == "num" or t.type == "id"
    end

    parseExpr = function(minPrec)
        minPrec = minPrec or 1
        local left = parsePostfix()
        while true do
            local t = peek()
            local op = binOp(t)
            if op then
                local prec = BIN[op]
                if prec < minPrec then break end
                nextTok(); skipNl()
                local rightAssoc = (op == "**")
                local right = parseExpr(rightAssoc and prec or prec + 1)
                if op == "and" then op = "&&" elseif op == "or" then op = "||" end
                left = { type = "bin", op = op, l = left, r = right, line = t.line }
            elseif isOp(t, "?") and minPrec <= 1 then
                nextTok(); skipNl()
                local a = parseExpr(1)
                skipNl(); expectOp(":"); skipNl()
                local b = parseExpr(1)
                left = { type = "tern", c = left, a = a, b = b, line = t.line }
            elseif juxtaposes(t) and minPrec <= 6 and not (t.type == "id" and (isOp(peek(1), ":=") or ASSIGN_OPS[peek(1).value or ""])) then
                -- `x y` joins, unless y starts an assignment (which cannot be here anyway)
                local right = parseExpr(7)
                left = { type = "bin", op = ".", l = left, r = right, line = t.line }
            else
                break
            end
        end
        return left
    end

    local function parseBlock()
        local open = expectOp("{")
        local body = {}
        while true do
            skipNl()
            local t = peek()
            if isOp(t, "}") then nextTok(); break end
            if t.type == "eof" then fail(open.line, "a { that never closes") end
            body[#body + 1] = parseStatement()
        end
        return { type = "block", body = body, line = open.line }
    end

    parseBlockOrStatement = function()
        skipNl()
        if isOp(peek(), "{") then return parseBlock() end
        local st = parseStatement()
        return { type = "block", body = { st }, line = st.line }
    end

    -- is this `Name(a, b) {` a function definition?
    local function looksLikeFuncDef()
        if peek().type ~= "id" or not isOp(peek(1), "(") then return false end
        local k = 2
        while true do
            local t = peek(k)
            if t.type == "eof" or t.type == "nl" then return false end
            if isOp(t, ")") then break end
            if not (t.type == "id" or isOp(t, ",") or isOp(t, "&") or isOp(t, ":=") or t.type == "num" or t.type == "str") then return false end
            k = k + 1
        end
        k = k + 1
        while peek(k).type == "nl" do k = k + 1 end
        return isOp(peek(k), "{")
    end

    parseStatement = function()
        skipNl()
        local t = peek()
        if t.type == "directive" then
            -- #Requires, #SingleInstance and friends are accepted and ignored
            while peek().type ~= "nl" and peek().type ~= "eof" do nextTok() end
            return { type = "nop", line = t.line }
        end
        if isOp(t, "{") then return parseBlock() end
        if t.type == "kw" then
            local kw = t.value
            if kw == "if" then
                nextTok()
                local cond = parseExpr()
                local thenb = parseBlockOrStatement()
                local save = p
                skipNl()
                local elseb = nil
                if isKw(peek(), "else") then
                    nextTok()
                    skipNl()
                    if isKw(peek(), "if") then
                        local st = parseStatement()
                        elseb = { type = "block", body = { st }, line = st.line }
                    else
                        elseb = parseBlockOrStatement()
                    end
                else
                    p = save
                end
                return { type = "if", cond = cond, thenb = thenb, elseb = elseb, line = t.line }
            elseif kw == "while" then
                nextTok()
                local cond = parseExpr()
                local body = parseBlockOrStatement()
                return { type = "while", cond = cond, body = body, line = t.line }
            elseif kw == "loop" then
                nextTok()
                local count = nil
                local nt = peek()
                if nt.type == "id" and (nt.value:lower() == "parse" or nt.value:lower() == "files" or nt.value:lower() == "read" or nt.value:lower() == "reg") then
                    fail(t.line, "Loop " .. nt.value .. " is not available here; use Loop n, While, or For")
                end
                if not (nt.type == "nl" or isOp(nt, "{")) then count = parseExpr() end
                local body = parseBlockOrStatement()
                local until_ = nil
                local save = p
                skipNl()
                if isKw(peek(), "until") then nextTok(); until_ = parseExpr() else p = save end
                return { type = "loop", count = count, body = body, until_ = until_, line = t.line }
            elseif kw == "for" then
                nextTok()
                local k = nextTok()
                if k.type ~= "id" then fail(t.line, "expected a variable after For") end
                local v = nil
                if isOp(peek(), ",") then nextTok(); v = nextTok(); if v.type ~= "id" then fail(t.line, "expected a second variable") end end
                if not isKw(nextTok(), "in") then fail(t.line, "expected 'in'") end
                local iter = parseExpr()
                local body = parseBlockOrStatement()
                return { type = "for", k = k.value, v = v and v.value, iter = iter, body = body, line = t.line }
            elseif kw == "break" or kw == "continue" then
                nextTok(); endOfStatement()
                return { type = kw, line = t.line }
            elseif kw == "return" then
                nextTok()
                local e = nil
                if not (peek().type == "nl" or peek().type == "eof" or isOp(peek(), "}")) then e = parseExpr() end
                endOfStatement()
                return { type = "return", expr = e, line = t.line }
            elseif kw == "global" or kw == "local" or kw == "static" then
                nextTok()
                local names, inits = {}, {}
                while peek().type == "id" do
                    local id = nextTok()
                    names[#names + 1] = id.value
                    if isOp(peek(), ":=") then nextTok(); inits[id.value] = parseExpr() end
                    if isOp(peek(), ",") then nextTok() else break end
                end
                endOfStatement()
                return { type = "decl", scope = kw, names = names, inits = inits, line = t.line }
            elseif kw == "else" then
                fail(t.line, "'else' without an 'if'")
            elseif kw == "until" then
                fail(t.line, "'until' without a 'Loop'")
            end
        end
        if t.type == "id" then
            if looksLikeFuncDef() then
                nextTok(); expectOp("(")
                local params = {}
                skipNl()
                while not isOp(peek(), ")") do
                    local byref = false
                    if isOp(peek(), "&") then nextTok(); byref = true end
                    local id = nextTok()
                    if id.type ~= "id" then fail(id.line, "expected a parameter name") end
                    local default = nil
                    if isOp(peek(), ":=") then nextTok(); default = parseExpr() end
                    params[#params + 1] = { name = id.value, byref = byref, default = default }
                    if isOp(peek(), ",") then nextTok() end
                    skipNl()
                end
                expectOp(")")
                skipNl()
                local body = parseBlock()
                return { type = "func", name = t.value, params = params, body = body, line = t.line }
            end
            local n1 = peek(1)
            if n1.type == "op" and ASSIGN_OPS[n1.value] then
                nextTok(); nextTok()
                skipNl()
                local e = parseExpr()
                endOfStatement()
                return { type = "assign", target = { type = "var", name = t.value }, op = n1.value, expr = e, line = t.line }
            end
            if isOp(n1, "::") then fail(t.line, "hotkeys belong to the slots on the settings page, not inside a macro") end
            if isOp(n1, "(") or isOp(n1, "[") or (isOp(n1, ".") and not n1.spaced) or isOp(n1, "++") or isOp(n1, "--") then
                local e = parsePostfix()
                local n2 = peek()
                if n2.type == "op" and ASSIGN_OPS[n2.value] and (e.type == "index" or e.type == "member") then
                    nextTok(); skipNl()
                    local rhs = parseExpr()
                    endOfStatement()
                    return { type = "assign", target = e, op = n2.value, expr = rhs, line = t.line }
                end
                -- `Name(args)` may still be followed by more command-style arguments? no: a call is a call
                endOfStatement()
                return { type = "expr", expr = e, line = t.line }
            end
            -- command style: Name arg, arg, ...
            nextTok()
            local args = {}
            if not (peek().type == "nl" or peek().type == "eof" or isOp(peek(), "}")) then
                args = parseArgs(nil)
            end
            endOfStatement()
            return { type = "expr", expr = { type = "call", name = t.value, args = args, line = t.line }, line = t.line }
        end
        if isOp(t, "++") or isOp(t, "--") then
            local e = parsePrimary()
            endOfStatement()
            return { type = "expr", expr = e, line = t.line }
        end
        fail(t.line, "unexpected " .. (t.type == "eof" and "end of script" or ("'" .. tostring(t.value) .. "'")))
    end

    local ok, res = pcall(function()
        local body = {}
        while true do
            skipNl()
            if peek().type == "eof" then break end
            body[#body + 1] = parseStatement()
        end
        return { type = "block", body = body, line = 1 }
    end)
    if ok then return res end
    if type(res) == "table" and res.msg then return nil, res end
    return nil, { line = 0, msg = tostring(res) }
end

------------------------------------------------------------------ Send strings

-- AutoHotkey key names to the names Hammerspoon knows.
local AHK_KEYS = {
    enter = "return", ["return"] = "return", esc = "escape", escape = "escape",
    bs = "delete", backspace = "delete", del = "forwarddelete", delete = "forwarddelete",
    tab = "tab", space = "space", up = "up", down = "down", left = "left", right = "right",
    home = "home", ["end"] = "end", pgup = "pageup", pgdn = "pagedown", ins = "help", insert = "help",
    capslock = "capslock", ctrl = "ctrl", control = "ctrl", alt = "alt", shift = "shift",
    lwin = "cmd", rwin = "cmd", win = "cmd", cmd = "cmd", command = "cmd", lctrl = "ctrl",
    rctrl = "ctrl", lalt = "alt", ralt = "alt", lshift = "shift", rshift = "shift",
    option = "alt", numpadenter = "padenter", appskey = "cmd",
}
for i = 1, 20 do AHK_KEYS["f" .. i] = "f" .. i end
local MOD_PREFIX = { ["^"] = "ctrl", ["!"] = "alt", ["+"] = "shift", ["#"] = "cmd" }
local MODNAMES = { ctrl = true, alt = true, shift = true, cmd = true }
S.AHK_KEYS = AHK_KEYS

-- A character on the US keyboard that is a plain key, and whether shift is
-- held to get it. Anything else is typed as text.
local SHIFTED = { ["!"] = "1", ["@"] = "2", ["#"] = "3", ["$"] = "4", ["%"] = "5", ["^"] = "6",
                  ["&"] = "7", ["*"] = "8", ["("] = "9", [")"] = "0", ["_"] = "-", ["+"] = "=",
                  ["{"] = "[", ["}"] = "]", ["|"] = "\\", [":"] = ";", ['"'] = "'", ["<"] = ",",
                  [">"] = ".", ["?"] = "/", ["~"] = "`" }
local PLAIN = {}
for c in ("abcdefghijklmnopqrstuvwxyz0123456789-=[]\\;',./`"):gmatch(".") do PLAIN[c] = c end
PLAIN[" "] = "space"; PLAIN["\n"] = "return"; PLAIN["\t"] = "tab"

function S.charKey(c)
    if PLAIN[c] then return PLAIN[c], false end
    local lower = c:lower()
    if c:match("^%u$") and PLAIN[lower] then return lower, true end
    if SHIFTED[c] then return SHIFTED[c], true end
    return nil
end

-- Send "text" -> a list of actions:
--   { kind = "key",  mods = {...}, key = "name", times = n }
--   { kind = "text", text = "..." }
--   { kind = "down"/"up", key = "name" }          a modifier or key held
--   { kind = "wheel", dir = "down"/"up"/"left"/"right", times = n }
--   { kind = "click", x =, y =, button = "left"/"right"/"middle", times = n }
function S.parseSend(str, raw)
    local out = {}
    local pending = {}
    local held = {}
    local i, n = 1, #str
    local function addMods()
        local mods = {}
        for m in pairs(held) do mods[#mods + 1] = m end
        for _, m in ipairs(pending) do
            local dup = false
            for _, x in ipairs(mods) do if x == m then dup = true end end
            if not dup then mods[#mods + 1] = m end
        end
        table.sort(mods)
        pending = {}
        return mods
    end
    local function key(name, times)
        out[#out + 1] = { kind = "key", mods = addMods(), key = name, times = times or 1 }
    end
    local function text(c)
        local last = out[#out]
        if #pending == 0 and next(held) == nil then
            if last and last.kind == "text" then last.text = last.text .. c
            else out[#out + 1] = { kind = "text", text = c } end
        else
            local k, shift = S.charKey(c)
            if k then
                if shift then pending[#pending + 1] = "shift" end
                key(k, 1)
            else
                pending = {}
                out[#out + 1] = { kind = "text", text = c }
            end
        end
    end
    while i <= n do
        local c = str:sub(i, i)
        if raw then
            text(c); i = i + 1
        elseif MOD_PREFIX[c] then
            pending[#pending + 1] = MOD_PREFIX[c]; i = i + 1
        elseif c == "{" then
            local j = str:find("}", i + 1, true)
            if j == i + 1 then j = str:find("}", i + 2, true) end     -- {}} is a literal }
            if not j then fail(0, "a { in Send that never closes") end
            local inner = str:sub(i + 1, j - 1)
            i = j + 1
            local name, arg = inner:match("^(%S+)%s+(.+)$")
            name = name or inner
            local lname = name:lower()
            if #name == 1 and not arg then
                text(name)                                        -- {!} {^} {{} {}} literals
            elseif lname == "raw" or lname == "text" then
                raw = true
            elseif lname == "click" then
                local x, y = (arg or ""):match("(%-?%d+)%s+(%-?%d+)")
                local button = (arg or ""):lower():match("right") and "right" or ((arg or ""):lower():match("middle") and "middle" or "left")
                local times = tonumber((arg or ""):match("%s(%d+)%s*$")) or 1
                if not x and (arg or ""):match("^%s*%d+") then times = tonumber((arg or ""):match("^%s*(%d+)")) end
                out[#out + 1] = { kind = "click", x = tonumber(x), y = tonumber(y), button = button, times = times, mods = addMods() }
            elseif lname:match("^wheel") then
                out[#out + 1] = { kind = "wheel", dir = lname:sub(6), times = tonumber(arg) or 1, mods = addMods() }
            else
                local hsname = AHK_KEYS[lname] or (#name == 1 and select(1, S.charKey(name))) or lname
                local larg = arg and arg:lower()
                if larg == "down" or larg == "up" then
                    if MODNAMES[hsname] then
                        if larg == "down" then held[hsname] = true else held[hsname] = nil end
                    end
                    out[#out + 1] = { kind = larg, key = hsname, mods = addMods() }
                else
                    local times = tonumber(arg) or 1
                    if #name == 1 and not AHK_KEYS[lname] then
                        local k, shift = S.charKey(name)
                        if shift then pending[#pending + 1] = "shift" end
                        key(k or name, times)
                    else
                        key(hsname, times)
                    end
                end
            end
        else
            if #pending > 0 then
                local k, shift = S.charKey(c)
                if k then
                    if shift then pending[#pending + 1] = "shift" end
                    key(k, 1)
                else
                    pending = {}
                    text(c)
                end
            else
                text(c)
            end
            i = i + 1
        end
    end
    return out
end

------------------------------------------------------------------ the interpreter

local Break, Continue, Return = {}, {}, {}

local function isArray(v) return type(v) == "table" and v.__arr end
local function isMap(v) return type(v) == "table" and v.__map end
local function isRef(v) return type(v) == "table" and v.__ref end

function S.newArray(items)
    return { __arr = true, items = items or {}, n = items and #items or 0 }
end
function S.newMap() return { __map = true, data = {}, keys = {} } end

local function fmtNum(v)
    if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
    local s = string.format("%.6f", v):gsub("0+$", ""):gsub("%.$", "")
    return s
end

local function toStr(v)
    if v == nil then return "" end
    if type(v) == "number" then return fmtNum(v) end
    if type(v) == "boolean" then return v and "1" or "0" end
    if isArray(v) then
        local parts = {}
        for i = 1, v.n do parts[i] = toStr(v.items[i]) end
        return "[" .. table.concat(parts, ", ") .. "]"
    end
    if isMap(v) then return "Map(" .. #v.keys .. ")" end
    return tostring(v)
end
S.toStr = toStr

local function toNum(v, line, what)
    if type(v) == "number" then return v end
    if type(v) == "boolean" then return v and 1 or 0 end
    if type(v) == "string" then
        local n = tonumber(v) or tonumber((v:gsub("^%s+", ""):gsub("%s+$", "")))
        if n then return n end
        if v == "" then return 0 end
    end
    if v == nil then return 0 end
    fail(line, (what or "this") .. " needs a number, not \"" .. toStr(v) .. "\"")
end

local function truthy(v)
    if v == nil or v == false or v == 0 or v == "" or v == "0" then return false end
    return true
end
S.truthy = truthy

local function isNumeric(v)
    return type(v) == "number" or (type(v) == "string" and tonumber(v) ~= nil)
end

local function compare(op, a, b, line)
    if isNumeric(a) and isNumeric(b) then
        local x, y = tonumber(a), tonumber(b)
        if op == "=" or op == "==" then return x == y end
        if op == "!=" or op == "<>" then return x ~= y end
        if op == "<" then return x < y end
        if op == ">" then return x > y end
        if op == "<=" then return x <= y end
        if op == ">=" then return x >= y end
    end
    local x, y = toStr(a), toStr(b)
    if op == "=" then return x:lower() == y:lower() end
    if op == "==" then return x == y end
    if op == "!=" or op == "<>" then return x:lower() ~= y:lower() end
    if op == "<" then return x < y end
    if op == ">" then return x > y end
    if op == "<=" then return x <= y end
    if op == ">=" then return x >= y end
    fail(line, "unknown comparison " .. op)
end

-- BUILT-IN FUNCTIONS that need no host: strings and numbers.
local PURE = {}
PURE.strlen = function(a) return #toStr(a[1]) end
PURE.substr = function(a, line)
    local s, start, len = toStr(a[1]), toNum(a[2], line, "SubStr start"), a[3]
    if start < 0 then start = #s + start + 1 elseif start == 0 then start = 1 end
    if len == nil then return s:sub(start) end
    len = toNum(len, line)
    if len < 0 then return s:sub(start, #s + len) end
    return s:sub(start, start + len - 1)
end
PURE.instr = function(a)
    local h, n = toStr(a[1]), toStr(a[2])
    local cs = truthy(a[3])
    local start = a[4] and tonumber(a[4]) or 1
    if not cs then h, n = h:lower(), n:lower() end
    local i = h:find(n, start, true)
    return i or 0
end
PURE.strreplace = function(a)
    local s, from, to = toStr(a[1]), toStr(a[2]), toStr(a[3])
    if from == "" then return s end
    local out, i, count = {}, 1, 0
    while true do
        local j = s:find(from, i, true)
        if not j then out[#out + 1] = s:sub(i); break end
        out[#out + 1] = s:sub(i, j - 1); out[#out + 1] = to
        i = j + #from; count = count + 1
    end
    return table.concat(out)
end
PURE.strupper = function(a) return toStr(a[1]):upper() end
PURE.strlower = function(a) return toStr(a[1]):lower() end
PURE.trim = function(a) return (toStr(a[1]):gsub("^%s+", ""):gsub("%s+$", "")) end
PURE.ltrim = function(a) return (toStr(a[1]):gsub("^%s+", "")) end
PURE.rtrim = function(a) return (toStr(a[1]):gsub("%s+$", "")) end
PURE.strsplit = function(a)
    local s, sep = toStr(a[1]), a[2] and toStr(a[2]) or ""
    local items = {}
    if sep == "" then for c in s:gmatch(".") do items[#items + 1] = c end
    else
        local i = 1
        while true do
            local j = s:find(sep, i, true)
            if not j then items[#items + 1] = s:sub(i); break end
            items[#items + 1] = s:sub(i, j - 1); i = j + #sep
        end
    end
    return S.newArray(items)
end
PURE.format = function(a, line)
    local fmt = toStr(a[1])
    local idx = 1
    return (fmt:gsub("{(%d*)(:?[^}]*)}", function(num, spec)
        local i = tonumber(num) or idx
        idx = i + 1
        local v = a[i + 1]
        if spec ~= "" and spec:sub(1, 1) == ":" then
            local ok, s = pcall(string.format, "%" .. spec:sub(2), isNumeric(v) and tonumber(v) or toStr(v))
            if ok then return s end
        end
        return toStr(v)
    end))
end
PURE.abs = function(a, line) return math.abs(toNum(a[1], line)) end
PURE.round = function(a, line)
    local x, n = toNum(a[1], line), a[2] and toNum(a[2], line) or 0
    local m = 10 ^ n
    return math.floor(x * m + 0.5) / m
end
PURE.floor = function(a, line) return math.floor(toNum(a[1], line)) end
PURE.ceil = function(a, line) return math.ceil(toNum(a[1], line)) end
PURE.integer = function(a, line) return math.floor(toNum(a[1], line)) end
PURE.number = function(a, line) return toNum(a[1], line) end
PURE.string = function(a) return toStr(a[1]) end
PURE.mod = function(a, line) return math.fmod(toNum(a[1], line), toNum(a[2], line)) end
PURE.min = function(a, line) local m = toNum(a[1], line); for i = 2, #a do m = math.min(m, toNum(a[i], line)) end return m end
PURE.max = function(a, line) local m = toNum(a[1], line); for i = 2, #a do m = math.max(m, toNum(a[i], line)) end return m end
PURE.sqrt = function(a, line) return math.sqrt(toNum(a[1], line)) end
PURE.random = function(a, line)
    local lo, hi = a[1] and toNum(a[1], line) or 0, a[2] and toNum(a[2], line) or 1
    if lo == math.floor(lo) and hi == math.floor(hi) and a[1] and a[2] then return math.random(lo, hi) end
    return lo + math.random() * (hi - lo)
end
PURE.isnumber = function(a) return isNumeric(a[1]) and 1 or 0 end
PURE.isinteger = function(a) return (isNumeric(a[1]) and tonumber(a[1]) == math.floor(tonumber(a[1]))) and 1 or 0 end
PURE.type = function(a)
    local v = a[1]
    if type(v) == "number" then return v == math.floor(v) and "Integer" or "Float" end
    if isArray(v) then return "Array" end
    if isMap(v) then return "Map" end
    return "String"
end
PURE.chr = function(a, line) return utf8.char(math.floor(toNum(a[1], line))) end
PURE.ord = function(a) local s = toStr(a[1]); return s == "" and 0 or utf8.codepoint(s, 1) end
PURE.array = function(a) return S.newArray({ table.unpack(a) }) end
PURE.map = function(a)
    local m = S.newMap()
    for i = 1, #a - 1, 2 do
        local k = toStr(a[i])
        if m.data[k] == nil then m.keys[#m.keys + 1] = k end
        m.data[k] = a[i + 1]
    end
    return m
end
S.PURE = PURE

-- HOST COMMANDS: what the interpreter asks the host for. Each is called with
-- (host, args, line, interp) and may set refs. The host gives real ones in
-- Hammerspoon and fake ones in the test.
local function need(host, name, line)
    local f = host[name]
    if not f then fail(line, name .. " is not available here") end
    return f
end

local function setRef(r, v, line)
    if not isRef(r) then fail(line, "expected &variable") end
    r.set(v)
end

local function optNum(v, line, default) if v == nil or v == "" then return default end return toNum(v, line) end

local function clickOptions(args, line)
    -- Click x, y  ·  Click x, y, "Right"  ·  Click "100 200 Right 2"  ·  Click "Right"
    local words = {}
    for _, v in ipairs(args) do
        if type(v) == "string" then for w in v:gmatch("%S+") do words[#words + 1] = w end
        elseif v ~= nil then words[#words + 1] = toStr(v) end
    end
    local o = { button = "left", times = 1, updown = nil }
    local nums = {}
    for _, w in ipairs(words) do
        local lw = w:lower()
        if lw == "right" or lw == "r" then o.button = "right"
        elseif lw == "middle" or lw == "m" then o.button = "middle"
        elseif lw == "left" or lw == "l" then o.button = "left"
        elseif lw == "down" or lw == "d" then o.updown = "down"
        elseif lw == "up" or lw == "u" then o.updown = "up"
        elseif lw == "rel" or lw == "relative" then o.relative = true
        elseif tonumber(w) then nums[#nums + 1] = tonumber(w)
        else fail(line, "Click does not understand '" .. w .. "'") end
    end
    if #nums >= 2 then o.x, o.y = nums[1], nums[2]; o.times = nums[3] or 1
    elseif #nums == 1 then o.times = nums[1] end
    return o
end

local HOSTFN = {}
HOSTFN.sleep = function(host, a, line) need(host, "sleep", line)(toNum(a[1], line, "Sleep") / 1000) end
HOSTFN.mousemove = function(host, a, line) need(host, "mouseMove", line)(toNum(a[1], line, "MouseMove x"), toNum(a[2], line, "MouseMove y")) end
HOSTFN.click = function(host, a, line, I)
    local o = clickOptions(a, line)
    if o.updown then need(host, "buttonDownUp", line)(o.button, o.updown, o.x, o.y, I.heldMods())
    else need(host, "click", line)(o.button, o.x, o.y, o.times, I.heldMods()) end
end
HOSTFN.mouseclick = function(host, a, line, I)
    local button = (a[1] and toStr(a[1]):lower() or "left")
    if button == "r" then button = "right" elseif button == "m" then button = "middle" elseif button == "l" or button == "" then button = "left" end
    local x, y = optNum(a[2], line, nil), optNum(a[3], line, nil)
    local times = optNum(a[4], line, 1)
    local updown = a[6] and toStr(a[6]):lower() or nil
    if updown == "d" then updown = "down" elseif updown == "u" then updown = "up" end
    if updown and updown ~= "" then need(host, "buttonDownUp", line)(button, updown, x, y, I.heldMods())
    else need(host, "click", line)(button, x, y, times, I.heldMods()) end
end
HOSTFN.mouseclickdrag = function(host, a, line, I)
    local button = (a[1] and toStr(a[1]):lower() or "left")
    if button == "r" then button = "right" elseif button == "m" then button = "middle" elseif button == "l" or button == "" then button = "left" end
    need(host, "drag", line)(button, toNum(a[2], line), toNum(a[3], line), toNum(a[4], line), toNum(a[5], line), I.heldMods())
end
HOSTFN.mousegetpos = function(host, a, line)
    local x, y = need(host, "mousePos", line)()
    if a[1] then setRef(a[1], x, line) end
    if a[2] then setRef(a[2], y, line) end
end
local function doSend(host, str, line, I, raw)
    local actions = S.parseSend(str, raw)
    for _, act in ipairs(actions) do
        if act.kind == "key" then
            local mods = I.mergeMods(act.mods)
            for _ = 1, act.times do need(host, "key", line)(mods, act.key) end
        elseif act.kind == "text" then
            local held = I.heldMods()
            if #held > 0 then
                for c in act.text:gmatch(utf8.charpattern) do
                    local k, shift = S.charKey(c)
                    local mods = I.mergeMods(shift and { "shift" } or {})
                    if k then need(host, "key", line)(mods, k) else need(host, "type", line)(c) end
                end
            else
                need(host, "type", line)(act.text)
            end
        elseif act.kind == "down" or act.kind == "up" then
            if MODNAMES[act.key] then
                I.held[act.key] = (act.kind == "down") or nil
            else
                need(host, "keyDownUp", line)(act.key, act.kind == "down", I.heldMods())
            end
        elseif act.kind == "wheel" then
            need(host, "wheel", line)(act.dir, act.times, I.mergeMods(act.mods))
        elseif act.kind == "click" then
            need(host, "click", line)(act.button, act.x, act.y, act.times, I.mergeMods(act.mods))
        end
    end
end
HOSTFN.send = function(host, a, line, I) doSend(host, toStr(a[1]), line, I, false) end
HOSTFN.sendinput = HOSTFN.send
HOSTFN.sendevent = HOSTFN.send
HOSTFN.sendplay = HOSTFN.send
HOSTFN.sendtext = function(host, a, line, I) doSend(host, toStr(a[1]), line, I, true) end
HOSTFN.imagesearch = function(host, a, line)
    -- ImageSearch &x, &y, x1, y1, x2, y2, "file.png"  -> 1 found, 0 not
    local file = toStr(a[7])
    local x1, y1, x2, y2 = optNum(a[3], line, 0), optNum(a[4], line, 0), optNum(a[5], line, 0), optNum(a[6], line, 0)
    local r = need(host, "imageSearch", line)(file, x1, y1, x2, y2)
    if r then
        if a[1] then setRef(a[1], r.x, line) end
        if a[2] then setRef(a[2], r.y, line) end
        return 1
    end
    return 0
end
HOSTFN.imageexist = function(host, a, line)
    return need(host, "imageSearch", line)(toStr(a[1]), 0, 0, 0, 0) and 1 or 0
end
HOSTFN.findimage = function(host, a, line)
    -- FindImage("file.png") -> [centreX, centreY] or 0
    local r = need(host, "imageSearch", line)(toStr(a[1]), 0, 0, 0, 0)
    if not r then return 0 end
    return S.newArray({ r.x + math.floor(r.w / 2), r.y + math.floor(r.h / 2) })
end
HOSTFN.waitimage = function(host, a, line)
    -- WaitImage "file.png", seconds  -> 1 when it appeared, 0 on time out
    local file, secs = toStr(a[1]), optNum(a[2], line, 10)
    local deadline = need(host, "now", line)() + secs
    while true do
        local r = need(host, "imageSearch", line)(file, 0, 0, 0, 0)
        if r then return 1 end
        if need(host, "now", line)() >= deadline then return 0 end
        need(host, "sleep", line)(0.4)
    end
end
HOSTFN.clickimage = function(host, a, line, I)
    -- ClickImage "file.png" [, seconds to wait] [, "Right"]  -> 1 clicked, 0 not found
    local file, secs = toStr(a[1]), optNum(a[2], line, 0)
    local button = a[3] and toStr(a[3]):lower() or "left"
    local deadline = need(host, "now", line)() + secs
    while true do
        local r = need(host, "imageSearch", line)(file, 0, 0, 0, 0)
        if r then
            need(host, "click", line)(button, r.x + math.floor(r.w / 2), r.y + math.floor(r.h / 2), 1, I.heldMods())
            return 1
        end
        if need(host, "now", line)() >= deadline then return 0 end
        need(host, "sleep", line)(0.4)
    end
end
HOSTFN.pixelgetcolor = function(host, a, line) return need(host, "pixel", line)(toNum(a[1], line), toNum(a[2], line)) end
HOSTFN.msgbox = function(host, a, line) need(host, "say", line)(toStr(a[1]), true) end
HOSTFN.tooltip = function(host, a, line) need(host, "say", line)(toStr(a[1]), false) end
HOSTFN.run = function(host, a, line) need(host, "run", line)(toStr(a[1])) end
HOSTFN.winactivate = function(host, a, line) return need(host, "activate", line)(toStr(a[1])) and 1 or 0 end
HOSTFN.winexist = function(host, a, line) return need(host, "winExists", line)(toStr(a[1])) and 1 or 0 end
HOSTFN.winwaitactive = function(host, a, line)
    local title, secs = toStr(a[1]), optNum(a[3], line, 10)
    local deadline = need(host, "now", line)() + secs
    while true do
        if need(host, "activate", line)(title) then return 1 end
        if need(host, "now", line)() >= deadline then return 0 end
        need(host, "sleep", line)(0.3)
    end
end
HOSTFN.exitapp = function() error(Return) end
HOSTFN.exit = HOSTFN.exitapp
HOSTFN.fileexist = function(host, a, line) return need(host, "fileExist", line)(toStr(a[1])) and 1 or 0 end
HOSTFN.fileread = function(host, a, line) return need(host, "fileRead", line)(toStr(a[1])) or "" end
HOSTFN.fileappend = function(host, a, line) need(host, "fileAppend", line)(toStr(a[1]), toStr(a[2])) end
HOSTFN.setdefaultmousespeed = function() end
HOSTFN.setmousedelay = function() end
HOSTFN.setkeydelay = function() end
HOSTFN.coordmode = function() end
HOSTFN.sendmode = function() end
HOSTFN.setworkingdir = function() end
HOSTFN.settitlematchmode = function() end
HOSTFN.blockinput = function() end
HOSTFN.keywait = function(host, a, line) need(host, "sleep", line)(0.05) end
S.HOSTFN = HOSTFN

-- THE COMMAND LIST, for the editor's suggestions and the documentation.
S.COMMANDS = {
    { name = "Click",          sig = 'Click x, y [, "Right" | "Middle", count]', doc = "Move the mouse to x, y and click there. Click alone clicks where the mouse is." },
    { name = "MouseMove",      sig = "MouseMove x, y",                          doc = "Move the mouse to x, y." },
    { name = "MouseClick",     sig = 'MouseClick "Left", x, y [, count]',       doc = "Click a button at x, y." },
    { name = "MouseClickDrag", sig = 'MouseClickDrag "Left", x1, y1, x2, y2',  doc = "Press at x1, y1, drag to x2, y2, release." },
    { name = "MouseGetPos",    sig = "MouseGetPos &x, &y",                      doc = "Put the mouse position into x and y." },
    { name = "Send",           sig = 'Send "text or ^c or {Enter}"',            doc = "Type text and keys. ^ Ctrl, ! Option, + Shift, # Command; {Enter} {Tab} {Esc} {F5} {Up}; {Ctrl down} holds." },
    { name = "SendText",       sig = 'SendText "text"',                         doc = "Type the text exactly, with no special meaning for ^ ! + # { }." },
    { name = "Sleep",          sig = "Sleep milliseconds",                      doc = "Wait. Sleep 500 is half a second." },
    { name = "ImageSearch",    sig = 'ImageSearch &x, &y, 0, 0, 0, 0, "button.png"', doc = "Look for the picture on the screen. Returns 1 and sets x, y to its top left corner, or 0." },
    { name = "ClickImage",     sig = 'ClickImage "button.png" [, seconds to wait]', doc = "Find the picture on the screen and click its centre. Waits up to the seconds given. Returns 1 or 0." },
    { name = "WaitImage",      sig = 'WaitImage "button.png", seconds',         doc = "Wait until the picture is on the screen. Returns 1, or 0 when the time runs out." },
    { name = "FindImage",      sig = 'FindImage("button.png")',                 doc = "The centre of the picture as [x, y], or 0 when it is not on screen." },
    { name = "ImageExist",     sig = 'ImageExist("button.png")',                doc = "1 when the picture is on the screen now, else 0." },
    { name = "PixelGetColor",  sig = "PixelGetColor(x, y)",                     doc = 'The colour at x, y as "0xRRGGBB".' },
    { name = "WinActivate",    sig = 'WinActivate "Google Chrome"',             doc = "Bring the app with that name to the front." },
    { name = "WinExist",       sig = 'WinExist("Google Chrome")',               doc = "1 when an app or window with that name is open." },
    { name = "WinWaitActive",  sig = 'WinWaitActive "Google Chrome", , seconds', doc = "Bring the app forward and wait for it." },
    { name = "Run",            sig = 'Run "https://example.com" or Run "Safari"', doc = "Open an address, a file or an app." },
    { name = "MsgBox",         sig = 'MsgBox "text"',                           doc = "Show a line bottom right of the screen, for a moment." },
    { name = "ToolTip",        sig = 'ToolTip "text"',                          doc = "Show a line bottom right of the screen." },
    { name = "ExitApp",        sig = "ExitApp",                                 doc = "Stop the macro here." },
    { name = "Loop",           sig = "Loop 5 {  }",                             doc = "Repeat the block 5 times. A_Index counts from 1. Loop alone repeats until Break." },
    { name = "While",          sig = "While x < 10 {  }",                       doc = "Repeat while the condition holds." },
    { name = "For",            sig = "For i, v in [1, 2, 3] {  }",              doc = "Walk an array or a Map." },
    { name = "If",             sig = "If x = 1 {  } Else {  }",                 doc = "Do the block when the condition holds." },
    { name = "Break",          sig = "Break",                                   doc = "Leave the loop." },
    { name = "Continue",       sig = "Continue",                                doc = "Next turn of the loop." },
    { name = "Return",         sig = "Return value",                            doc = "Leave the function with a value." },
    { name = "Global",         sig = "Global name",                             doc = "Inside a function: write to the script-wide variable." },
    { name = "StrLen",         sig = "StrLen(text)",                            doc = "How many characters." },
    { name = "SubStr",         sig = "SubStr(text, start, length)",             doc = "Part of the text. Start counts from 1; negative counts from the end." },
    { name = "InStr",          sig = "InStr(haystack, needle)",                 doc = "Where needle is in haystack, or 0." },
    { name = "StrReplace",     sig = "StrReplace(text, from, to)",              doc = "Replace every from with to." },
    { name = "StrSplit",       sig = 'StrSplit(text, ",")',                     doc = "Cut the text into an array." },
    { name = "StrUpper",       sig = "StrUpper(text)",                          doc = "UPPER CASE." },
    { name = "StrLower",       sig = "StrLower(text)",                          doc = "lower case." },
    { name = "Trim",           sig = "Trim(text)",                              doc = "Without the spaces at both ends." },
    { name = "Format",         sig = 'Format("{1} and {2}", a, b)',             doc = "Fill the braces with the values." },
    { name = "Round",          sig = "Round(number, decimals)",                 doc = "Round the number." },
    { name = "Floor",          sig = "Floor(number)",                           doc = "Round down." },
    { name = "Ceil",           sig = "Ceil(number)",                            doc = "Round up." },
    { name = "Abs",            sig = "Abs(number)",                             doc = "Without the sign." },
    { name = "Mod",            sig = "Mod(a, b)",                               doc = "The remainder of a / b." },
    { name = "Min",            sig = "Min(a, b, ...)",                          doc = "The smallest." },
    { name = "Max",            sig = "Max(a, b, ...)",                          doc = "The largest." },
    { name = "Random",         sig = "Random(min, max)",                        doc = "A random number between the two." },
    { name = "Sqrt",           sig = "Sqrt(number)",                            doc = "Square root." },
    { name = "IsNumber",       sig = "IsNumber(value)",                         doc = "1 when the value is a number." },
    { name = "Type",           sig = "Type(value)",                             doc = '"Integer", "Float", "String", "Array" or "Map".' },
    { name = "Chr",            sig = "Chr(65)",                                 doc = "The character with that code." },
    { name = "Ord",            sig = 'Ord("A")',                                doc = "The code of the first character." },
    { name = "Array",          sig = "Array(1, 2, 3) or [1, 2, 3]",             doc = "A list. arr.Length, arr.Push(v), arr.Pop(), arr[1]." },
    { name = "Map",            sig = 'Map("key", value)',                       doc = 'A dictionary. m["key"], m.Has("key"), m.Count, m.Delete("key").' },
    { name = "FileExist",      sig = 'FileExist("/path/file")',                 doc = "1 when the file is there." },
    { name = "FileRead",       sig = 'FileRead("/path/file")',                  doc = "The whole file as text." },
    { name = "FileAppend",     sig = 'FileAppend "text", "/path/file"',         doc = "Add text to the end of a file." },
}
S.VARIABLES = {
    { name = "A_Index",        doc = "The turn of the current loop, from 1." },
    { name = "A_ScreenWidth",  doc = "Width of the main screen in points." },
    { name = "A_ScreenHeight", doc = "Height of the main screen in points." },
    { name = "A_Clipboard",    doc = "The clipboard. Read it or assign to it." },
    { name = "A_TickCount",    doc = "Milliseconds since the macro started." },
    { name = "A_Now",          doc = "The time as YYYYMMDDHH24MISS." },
    { name = "A_MouseX",       doc = "Where the mouse is, x." },
    { name = "A_MouseY",       doc = "Where the mouse is, y." },
    { name = "A_Speed",        doc = "The speed setting of the player." },
}
S.KEYNAMES = { "Enter", "Tab", "Esc", "Space", "BS", "Del", "Up", "Down", "Left", "Right", "Home", "End",
               "PgUp", "PgDn", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12",
               "Ctrl down", "Ctrl up", "Alt down", "Alt up", "Shift down", "Shift up", "Cmd down", "Cmd up",
               "WheelDown 3", "WheelUp 3", "Click 100 200", "Text" }

-- RUN a parsed script against a host. Returns true, or false and "line N: msg".
-- Made to be called inside a coroutine: host.sleep may yield.
function S.run(prog, host, opts)
    opts = opts or {}
    local I = {}
    local globals = {}
    local funcs = {}
    local steps = 0
    I.held = {}
    I.globals = globals

    local function heldMods()
        local out = {}
        for m in pairs(I.held) do out[#out + 1] = m end
        table.sort(out)
        return out
    end
    I.heldMods = heldMods
    function I.mergeMods(mods)
        local set = {}
        for m in pairs(I.held) do set[m] = true end
        for _, m in ipairs(mods or {}) do set[m] = true end
        local out = {}
        for m in pairs(set) do out[#out + 1] = m end
        table.sort(out)
        return out
    end

    local startAt = host.now and host.now() or os.time()

    local function builtinVar(name, line)
        local l = name:lower()
        if l == "a_screenwidth" then local w = host.screen and host.screen() or 0; return w end
        if l == "a_screenheight" then local _, h = (host.screen and host.screen() or 0), 0; if host.screen then _, h = host.screen() end return h end
        if l == "a_clipboard" then return host.clipboard and host.clipboard() or "" end
        if l == "a_tickcount" then return math.floor(((host.now and host.now() or os.time()) - startAt) * 1000) end
        if l == "a_now" then return os.date("%Y%m%d%H%M%S") end
        if l == "a_mousex" then local x = host.mousePos and host.mousePos() or 0; return x end
        if l == "a_mousey" then local _, y = 0, 0; if host.mousePos then _, y = host.mousePos() end return y end
        if l == "a_speed" then return opts.speed or 1 end
        if l == "a_space" then return " " end
        if l == "a_tab" then return "\t" end
        return nil
    end

    local function tick()
        steps = steps + 1
        if steps % 400 == 0 and host.sleep then host.sleep(0) end
    end

    local evalExpr, execBlock

    local function newScope(parent, isFunc)
        return { vars = {}, parent = parent, isFunc = isFunc, globalsDeclared = {}, loopIndex = parent and parent.loopIndex or 0 }
    end

    local function lookup(scope, name)
        local l = name:lower()
        local s = scope
        while s do
            if s.vars[l] ~= nil then return s.vars[l], s end
            if s.isFunc then break end
            s = s.parent
        end
        if globals[l] ~= nil then return globals[l], nil end
        return nil, nil
    end

    local function assign(scope, name, value)
        local l = name:lower()
        if l == "a_clipboard" then
            if host.setClipboard then host.setClipboard(toStr(value)) end
            return
        end
        -- find the function scope we are in
        local s, fscope = scope, nil
        while s do
            if s.isFunc then fscope = s; break end
            s = s.parent
        end
        if fscope == nil then globals[l] = value; return end
        if fscope.globalsDeclared[l] then globals[l] = value; return end
        -- an existing local in this function (any block) is updated in place
        s = scope
        while s do
            if s.vars[l] ~= nil then s.vars[l] = value; return end
            if s.isFunc then break end
            s = s.parent
        end
        fscope.vars[l] = value
    end

    local function makeRef(scope, name)
        return { __ref = true, name = name,
                 get = function() local v = lookup(scope, name); return v end,
                 set = function(v) assign(scope, name, v) end }
    end

    local function callFunction(name, args, line, scope)
        local l = name:lower()
        local f = funcs[l]
        if f then
            local fs = newScope(nil, true)
            fs.loopIndex = 0
            for i, prm in ipairs(f.params) do
                local v = args[i]
                if prm.byref then
                    if not isRef(v) then fail(line, name .. ": parameter " .. prm.name .. " needs &variable") end
                    fs.vars[prm.name:lower()] = v      -- a ref stays a ref; reads and writes go through it
                else
                    if isRef(v) then v = v.get() end
                    if v == nil and prm.default then v = evalExpr(prm.default, fs) end
                    if v == nil then v = "" end
                    fs.vars[prm.name:lower()] = v
                end
            end
            local ok, err = pcall(execBlock, f.body, fs)
            if ok then return "" end
            if err == Return then return fs.returnValue == nil and "" or fs.returnValue end
            error(err, 0)
        end
        local values = {}
        for i, a in ipairs(args) do
            if isRef(a) then values[i] = a else values[i] = a end
        end
        if PURE[l] then
            local plain = {}
            for i = 1, #values do plain[i] = isRef(values[i]) and values[i].get() or values[i] end
            plain.n = #values
            return PURE[l](plain, line)
        end
        if HOSTFN[l] then
            local plain = {}
            for i = 1, #values do
                if isRef(values[i]) then plain[i] = values[i] else plain[i] = values[i] end
            end
            local r = HOSTFN[l](host, plain, line, I)
            if r == nil then return "" end
            return r
        end
        fail(line, "no command or function called " .. name)
    end

    local function evalArgs(args, scope)
        local out = {}
        for i, a in ipairs(args) do
            if a.type == "ref" then out[i] = makeRef(scope, a.name)
            elseif a.type == "empty" then out[i] = nil
            else out[i] = evalExpr(a, scope) end
        end
        return out
    end

    local function memberOf(obj, name, line)
        local l = name:lower()
        if isArray(obj) then
            if l == "length" then return obj.n end
            fail(line, "arrays have no ." .. name)
        end
        if isMap(obj) then
            if l == "count" then return #obj.keys end
            fail(line, "maps have no ." .. name)
        end
        if type(obj) == "string" then
            if l == "length" then return #obj end
        end
        fail(line, "no ." .. name .. " on " .. toStr(obj))
    end

    local function methodOf(obj, name, args, line)
        local l = name:lower()
        if isArray(obj) then
            if l == "push" then for _, v in ipairs(args) do obj.n = obj.n + 1; obj.items[obj.n] = v end return obj.n end
            if l == "pop" then local v = obj.items[obj.n]; obj.items[obj.n] = nil; obj.n = math.max(0, obj.n - 1); return v == nil and "" or v end
            if l == "has" then local i = toNum(args[1], line); return (i >= 1 and i <= obj.n) and 1 or 0 end
            if l == "insertat" then
                local i = toNum(args[1], line)
                table.insert(obj.items, i, args[2]); obj.n = obj.n + 1; return ""
            end
            if l == "removeat" then
                local i = toNum(args[1], line)
                local v = table.remove(obj.items, i); obj.n = obj.n - 1; return v == nil and "" or v
            end
            if l == "clone" then local c = {} for i = 1, obj.n do c[i] = obj.items[i] end return S.newArray(c) end
            fail(line, "arrays have no ." .. name .. "()")
        end
        if isMap(obj) then
            if l == "has" then return obj.data[toStr(args[1])] ~= nil and 1 or 0 end
            if l == "delete" then
                local k = toStr(args[1]); local v = obj.data[k]; obj.data[k] = nil
                for i, kk in ipairs(obj.keys) do if kk == k then table.remove(obj.keys, i) break end end
                return v == nil and "" or v
            end
            if l == "get" then local v = obj.data[toStr(args[1])]; if v == nil then return args[2] == nil and "" or args[2] end return v end
            if l == "set" then
                for i = 1, #args - 1, 2 do
                    local k = toStr(args[i])
                    if obj.data[k] == nil then obj.keys[#obj.keys + 1] = k end
                    obj.data[k] = args[i + 1]
                end
                return obj
            end
            if l == "clear" then obj.data = {}; obj.keys = {}; return "" end
            fail(line, "maps have no ." .. name .. "()")
        end
        fail(line, "no ." .. name .. "() on " .. toStr(obj))
    end

    local function indexGet(obj, idx, line)
        if isArray(obj) then
            local i = toNum(idx, line, "the index")
            if i < 0 then i = obj.n + i + 1 end
            if i < 1 or i > obj.n then fail(line, "index " .. toStr(idx) .. " is outside the array (it has " .. obj.n .. ")") end
            local v = obj.items[i]; return v == nil and "" or v
        end
        if isMap(obj) then
            local v = obj.data[toStr(idx)]
            if v == nil then fail(line, 'the map has no key "' .. toStr(idx) .. '"') end
            return v
        end
        if type(obj) == "string" then
            local i = toNum(idx, line)
            return obj:sub(i, i)
        end
        fail(line, "cannot index " .. toStr(obj))
    end

    local function indexSet(obj, idx, value, line)
        if isArray(obj) then
            local i = toNum(idx, line, "the index")
            if i < 0 then i = obj.n + i + 1 end
            if i < 1 or i > obj.n + 1 then fail(line, "index " .. toStr(idx) .. " is outside the array") end
            obj.items[i] = value
            if i > obj.n then obj.n = i end
            return
        end
        if isMap(obj) then
            local k = toStr(idx)
            if obj.data[k] == nil then obj.keys[#obj.keys + 1] = k end
            obj.data[k] = value
            return
        end
        fail(line, "cannot assign into " .. toStr(obj))
    end

    local function arith(op, a, b, line)
        local x, y = toNum(a, line, "'" .. op .. "'"), toNum(b, line, "'" .. op .. "'")
        if op == "+" then return x + y end
        if op == "-" then return x - y end
        if op == "*" then return x * y end
        if op == "/" then if y == 0 then fail(line, "division by zero") end return x / y end
        if op == "//" then if y == 0 then fail(line, "division by zero") end return math.floor(x / y) end
        if op == "**" then return x ^ y end
        fail(line, "unknown operator " .. op)
    end

    evalExpr = function(e, scope)
        tick()
        local t = e.type
        if t == "num" then return e.value end
        if t == "str" then return e.value end
        if t == "var" then
            local v = lookup(scope, e.name)
            if isRef(v) then return v.get() end
            if v ~= nil then return v end
            local b = builtinVar(e.name, e.line)
            if b ~= nil then return b end
            if e.name:lower() == "a_index" then return scope.loopIndex end
            if funcs[e.name:lower()] or HOSTFN[e.name:lower()] then
                -- a bare name that is a command: call it with no arguments
                return callFunction(e.name, {}, e.line, scope)
            end
            return ""      -- an unset variable is empty, the AutoHotkey way
        end
        if t == "ref" then return makeRef(scope, e.name) end
        if t == "bin" then
            local op = e.op
            if op == "&&" then return (truthy(evalExpr(e.l, scope)) and truthy(evalExpr(e.r, scope))) and 1 or 0 end
            if op == "||" then return (truthy(evalExpr(e.l, scope)) or truthy(evalExpr(e.r, scope))) and 1 or 0 end
            local a, b = evalExpr(e.l, scope), evalExpr(e.r, scope)
            if op == "." then return toStr(a) .. toStr(b) end
            if op == "=" or op == "==" or op == "!=" or op == "<>" or op == "<" or op == ">" or op == "<=" or op == ">=" then
                return compare(op, a, b, e.line) and 1 or 0
            end
            return arith(op, a, b, e.line)
        end
        if t == "un" then
            local v = evalExpr(e.e, scope)
            if e.op == "-" then return -toNum(v, e.line, "'-'") end
            if e.op == "!" then return truthy(v) and 0 or 1 end
        end
        if t == "tern" then
            if truthy(evalExpr(e.c, scope)) then return evalExpr(e.a, scope) end
            return evalExpr(e.b, scope)
        end
        if t == "call" then
            local args = evalArgs(e.args, scope)
            return callFunction(e.name, args, e.line, scope)
        end
        if t == "index" then return indexGet(evalExpr(e.obj, scope), evalExpr(e.idx, scope), e.line) end
        if t == "member" then return memberOf(evalExpr(e.obj, scope), e.name, e.line) end
        if t == "mcall" then
            local obj = evalExpr(e.obj, scope)
            local args = evalArgs(e.args, scope)
            return methodOf(obj, e.name, args, e.line)
        end
        if t == "array" then
            local items = {}
            for i, it in ipairs(e.items) do items[i] = evalExpr(it, scope) end
            return S.newArray(items)
        end
        if t == "object" then
            local m = S.newMap()
            for _, pr in ipairs(e.pairs) do
                m.keys[#m.keys + 1] = pr.key
                m.data[pr.key] = evalExpr(pr.value, scope)
            end
            return m
        end
        if t == "postinc" or t == "preinc" then
            local cur = toNum(lookup(scope, e.name) or 0, e.line, e.name)
            local new = e.op == "++" and cur + 1 or cur - 1
            assign(scope, e.name, new)
            return t == "postinc" and cur or new
        end
        fail(e.line, "cannot evaluate " .. tostring(t))
    end

    local function execStatement(st, scope)
        tick()
        local t = st.type
        if t == "nop" then return end
        if t == "block" then return execBlock(st, newScope(scope, false)) end
        if t == "expr" then evalExpr(st.expr, scope); return end
        if t == "assign" then
            local value = evalExpr(st.expr, scope)
            local target = st.target
            if st.op ~= ":=" then
                local cur
                if target.type == "var" then cur = lookup(scope, target.name); if isRef(cur) then cur = cur.get() end
                else cur = evalExpr(target, scope) end
                if cur == nil then cur = "" end
                if st.op == ".=" then value = toStr(cur) .. toStr(value)
                else value = arith(st.op:sub(1, #st.op - 1), cur, value, st.line) end
            end
            if target.type == "var" then
                local cur = lookup(scope, target.name)
                if isRef(cur) then cur.set(value) else assign(scope, target.name, value) end
            elseif target.type == "index" then
                indexSet(evalExpr(target.obj, scope), evalExpr(target.idx, scope), value, st.line)
            elseif target.type == "member" then
                local obj = evalExpr(target.obj, scope)
                if isMap(obj) then indexSet(obj, target.name, value, st.line)
                else fail(st.line, "cannot assign ." .. target.name) end
            end
            return
        end
        if t == "decl" then
            local fs = scope
            while fs and not fs.isFunc do fs = fs.parent end
            for _, name in ipairs(st.names) do
                local l = name:lower()
                if st.scope == "global" and fs then fs.globalsDeclared[l] = true end
                if st.inits[name] then
                    local v = evalExpr(st.inits[name], scope)
                    if st.scope == "global" then globals[l] = v else scope.vars[l] = v end
                elseif st.scope ~= "global" and scope.vars[l] == nil then
                    scope.vars[l] = ""
                end
            end
            return
        end
        if t == "if" then
            if truthy(evalExpr(st.cond, scope)) then return execBlock(st.thenb, newScope(scope, false)) end
            if st.elseb then return execBlock(st.elseb, newScope(scope, false)) end
            return
        end
        if t == "while" then
            local i = 0
            while truthy(evalExpr(st.cond, scope)) do
                i = i + 1
                local inner = newScope(scope, false); inner.loopIndex = i
                local ok, err = pcall(execBlock, st.body, inner)
                if not ok then
                    if err == Break then break end
                    if err ~= Continue then error(err, 0) end
                end
            end
            return
        end
        if t == "loop" then
            local count = st.count and toNum(evalExpr(st.count, scope), st.line, "Loop") or nil
            local i = 0
            while count == nil or i < count do
                i = i + 1
                local inner = newScope(scope, false); inner.loopIndex = i
                local ok, err = pcall(execBlock, st.body, inner)
                if not ok then
                    if err == Break then break end
                    if err ~= Continue then error(err, 0) end
                end
                if st.until_ and truthy(evalExpr(st.until_, inner)) then break end
            end
            return
        end
        if t == "for" then
            local coll = evalExpr(st.iter, scope)
            local pairsList = {}
            if isArray(coll) then
                for i = 1, coll.n do pairsList[#pairsList + 1] = { i, coll.items[i] } end
            elseif isMap(coll) then
                for _, k in ipairs(coll.keys) do pairsList[#pairsList + 1] = { k, coll.data[k] } end
            elseif type(coll) == "string" then
                local i = 0
                for c in coll:gmatch(utf8.charpattern) do i = i + 1; pairsList[#pairsList + 1] = { i, c } end
            else
                fail(st.line, "For needs an array, a map or a string")
            end
            for i, pr in ipairs(pairsList) do
                local inner = newScope(scope, false); inner.loopIndex = i
                if st.v then
                    inner.vars[st.k:lower()] = pr[1]; inner.vars[st.v:lower()] = pr[2]
                else
                    inner.vars[st.k:lower()] = pr[2] ~= nil and (isArray(coll) and pr[2] or pr[1]) or ""
                    if isArray(coll) then inner.vars[st.k:lower()] = pr[2] end
                end
                -- For k in map gives keys; For v in array gives values
                if not st.v and isMap(coll) then inner.vars[st.k:lower()] = pr[1] end
                local ok, err = pcall(execBlock, st.body, inner)
                if not ok then
                    if err == Break then break end
                    if err ~= Continue then error(err, 0) end
                end
            end
            return
        end
        if t == "break" then error(Break, 0) end
        if t == "continue" then error(Continue, 0) end
        if t == "return" then
            local fs = scope
            while fs and not fs.isFunc do fs = fs.parent end
            local v = st.expr and evalExpr(st.expr, scope) or ""
            if fs then fs.returnValue = v end
            error(Return, 0)
        end
        if t == "func" then
            funcs[st.name:lower()] = st
            return
        end
        fail(st.line, "cannot run " .. tostring(t))
    end

    execBlock = function(block, scope)
        for _, st in ipairs(block.body) do execStatement(st, scope) end
    end

    -- functions are known before the first line runs, wherever they are written
    for _, st in ipairs(prog.body) do
        if st.type == "func" then funcs[st.name:lower()] = st end
    end

    local top = newScope(nil, false)
    local ok, err = pcall(execBlock, prog, top)
    I.held = {}
    if ok or err == Return then return true end
    if err == Break or err == Continue then return false, "Break or Continue outside a loop" end
    if type(err) == "table" and err.msg then return false, "line " .. tostring(err.line) .. ": " .. err.msg, err.line end
    return false, tostring(err)
end

------------------------------------------------------------------ a recording as a script

-- Hammerspoon key names to AutoHotkey names for Send.
local HS_TO_AHK = { ["return"] = "Enter", escape = "Esc", delete = "BS", forwarddelete = "Del",
                    tab = "Tab", space = "Space", up = "Up", down = "Down", left = "Left", right = "Right",
                    home = "Home", ["end"] = "End", pageup = "PgUp", pagedown = "PgDn", help = "Ins",
                    padenter = "NumpadEnter", capslock = "CapsLock" }
for i = 1, 20 do HS_TO_AHK["f" .. i] = "F" .. i end
local SEND_SPECIAL = { ["^"] = true, ["!"] = true, ["+"] = true, ["#"] = true, ["{"] = true, ["}"] = true }
local SHIFT_CHAR = {}
for c, k in pairs(SHIFTED) do SHIFT_CHAR[k] = c end

local function sendEscape(text)
    -- inside Send, the five special characters go in braces; the string quote and backtick are escaped
    return (text:gsub("[%^!+#{}]", function(c) return "{" .. c .. "}" end):gsub("`", "``"):gsub('"', '`"'))
end
local function strEscape(text)
    return (text:gsub("`", "``"):gsub('"', '`"'):gsub("\n", "`n"):gsub("\t", "`t"))
end

local function modPrefix(mods)
    local s = ""
    local has = {}
    for _, m in ipairs(mods or {}) do has[m] = true end
    if has.ctrl then s = s .. "^" end
    if has.alt then s = s .. "!" end
    if has.shift then s = s .. "+" end
    if has.cmd then s = s .. "#" end
    return s, has
end

-- events (as the recorder writes them) -> script text. keyNames maps a key
-- code to its Hammerspoon name.
function S.fromEvents(events, keyNames, header)
    keyNames = keyNames or {}
    local lines = {}
    if header then for _, h in ipairs(header) do lines[#lines + 1] = "; " .. h end end
    local lastT = 0
    local textRun = nil          -- { chars = {} }: text pieces and {raw="{Enter}"} keys
    local function flushText()
        if textRun and #textRun.chars > 0 then
            local out = {}
            for _, piece in ipairs(textRun.chars) do
                if type(piece) == "table" then out[#out + 1] = piece.raw else out[#out + 1] = sendEscape(piece) end
            end
            lines[#lines + 1] = 'Send "' .. table.concat(out) .. '"'
        end
        textRun = nil
    end
    local JOINS = { ["return"] = "{Enter}", tab = "{Tab}", delete = "{BS}", forwarddelete = "{Del}" }
    local function gap(t)
        local ms = math.floor((t - lastT) * 1000 + 0.5)
        if ms >= 20 then
            ms = math.floor(ms / 10 + 0.5) * 10
            lines[#lines + 1] = "Sleep " .. ms
        end
        lastT = t
    end
    local n = #events
    local i = 1
    local pending = {}          -- up events already used
    while i <= n do
        local ev = events[i]
        local kind = ev.kind
        if pending[i] then
            i = i + 1
        elseif kind == "mouseMoved" then
            i = i + 1
        elseif kind == "keyUp" then
            i = i + 1
        elseif kind == "keyDown" then
            local name = keyNames[ev.code] or ("vk" .. tostring(ev.code))
            local prefix, has = modPrefix(ev.mods)
            local special = HS_TO_AHK[name]
            local plainChar = (#name == 1) and name or (name == "space" and " " or nil)
            local onlyShift = prefix == "" or prefix == "+"
            local joiner = (prefix == "") and JOINS[name] or nil
            if (plainChar and onlyShift) or joiner then
                -- text: letters with shift are capitals, shifted symbols their symbol;
                -- Enter, Tab and the deletes ride along inside the same Send
                local c
                if joiner then c = { raw = joiner }
                else
                    c = plainChar
                    if has.shift then
                        if c:match("%l") then c = c:upper() elseif SHIFT_CHAR[c] then c = SHIFT_CHAR[c] end
                    end
                end
                if textRun and (ev.t - lastT) < 1.5 then
                    textRun.chars[#textRun.chars + 1] = c
                    lastT = ev.t
                else
                    flushText()
                    gap(ev.t)
                    textRun = { chars = { c } }
                end
            else
                flushText()
                gap(ev.t)
                local keyText
                if special then keyText = "{" .. special .. "}"
                elseif #name == 1 then
                    keyText = name
                    if has.shift and name:match("%l") then keyText = name:upper(); prefix = prefix:gsub("%+", "") end
                    if SEND_SPECIAL[keyText] then keyText = "{" .. keyText .. "}" end
                else keyText = "{" .. name .. "}" end
                lines[#lines + 1] = 'Send "' .. prefix .. keyText .. '"'
            end
            i = i + 1
        elseif kind == "leftMouseDown" or kind == "rightMouseDown" or kind == "otherMouseDown" then
            flushText()
            gap(ev.t)
            local upKind = kind:gsub("Down", "Up")
            local dragKind = kind:gsub("Down", "Dragged")
            local j, dragged, upEv = i + 1, false, nil
            while j <= n do
                local e2 = events[j]
                if e2.kind == upKind then upEv = e2; break end
                if e2.kind == dragKind then dragged = true end
                j = j + 1
            end
            local button = kind == "leftMouseDown" and "Left" or (kind == "rightMouseDown" and "Right" or (ev.button == 2 and "Middle" or "Right"))
            local prefix, has = modPrefix(ev.mods)
            local holds = {}
            for _, m in ipairs({ "ctrl", "alt", "shift", "cmd" }) do if has[m] then holds[#holds + 1] = m end end
            local AHKMOD = { ctrl = "Ctrl", alt = "Alt", shift = "Shift", cmd = "Cmd" }
            for _, m in ipairs(holds) do lines[#lines + 1] = 'Send "{' .. AHKMOD[m] .. ' down}"' end
            local x, y = math.floor(ev.x + 0.5), math.floor(ev.y + 0.5)
            if upEv and dragged and (math.abs(upEv.x - ev.x) > 3 or math.abs(upEv.y - ev.y) > 3) then
                lines[#lines + 1] = string.format('MouseClickDrag "%s", %d, %d, %d, %d', button, x, y, math.floor(upEv.x + 0.5), math.floor(upEv.y + 0.5))
                if upEv then pending[j] = true; lastT = upEv.t end
            else
                -- double and triple clicks: the next down within 0.4 s at the same spot
                local count = 1
                local k = (upEv and j or i) + 1
                local lastUp = upEv
                while k <= n do
                    local e3 = events[k]
                    if e3.kind == kind and (e3.t - (lastUp and lastUp.t or ev.t)) < 0.4 and math.abs(e3.x - ev.x) <= 3 and math.abs(e3.y - ev.y) <= 3 then
                        count = count + 1
                        pending[k] = true
                        local m = k + 1
                        while m <= n and events[m].kind ~= upKind do
                            if events[m].kind == "mouseMoved" or events[m].kind == dragKind then pending[m] = true end
                            m = m + 1
                        end
                        if m <= n then pending[m] = true; lastUp = events[m]; k = m + 1 else break end
                    elseif e3.kind == "mouseMoved" then
                        k = k + 1
                    else
                        break
                    end
                end
                if upEv then pending[j] = true end
                if button == "Left" then
                    lines[#lines + 1] = count > 1 and string.format("Click %d, %d, %d", x, y, count) or string.format("Click %d, %d", x, y)
                else
                    lines[#lines + 1] = count > 1 and string.format('Click %d, %d, "%s", %d', x, y, button, count) or string.format('Click %d, %d, "%s"', x, y, button)
                end
                lastT = lastUp and lastUp.t or ev.t
            end
            for idx = #holds, 1, -1 do lines[#lines + 1] = 'Send "{' .. AHKMOD[holds[idx]] .. ' up}"' end
            i = i + 1
        elseif kind == "scrollWheel" then
            flushText()
            gap(ev.t)
            local dy, dx = ev.dy or 0, ev.dx or 0
            local j = i + 1
            while j <= n and events[j].kind == "scrollWheel" and (events[j].t - events[j - 1].t) < 0.3 do
                dy = dy + (events[j].dy or 0); dx = dx + (events[j].dx or 0)
                pending[j] = true; lastT = events[j].t
                j = j + 1
            end
            lines[#lines + 1] = string.format("MouseMove %d, %d", math.floor(ev.x + 0.5), math.floor(ev.y + 0.5))
            if math.abs(dy) >= math.abs(dx) and dy ~= 0 then
                local notches = math.max(1, math.floor(math.abs(dy) / 30 + 0.5))
                lines[#lines + 1] = string.format('Send "{Wheel%s %d}"', dy > 0 and "Up" or "Down", notches)
            elseif dx ~= 0 then
                local notches = math.max(1, math.floor(math.abs(dx) / 30 + 0.5))
                lines[#lines + 1] = string.format('Send "{Wheel%s %d}"', dx > 0 and "Left" or "Right", notches)
            end
            i = i + 1
        else
            i = i + 1       -- dragged, up: consumed above
        end
    end
    flushText()
    return table.concat(lines, "\n") .. "\n"
end

S.strEscape = strEscape
return S
