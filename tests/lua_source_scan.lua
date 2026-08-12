-- tests/lua_source_scan.lua
-- A dependency-free LEXICAL scanner for Lua 5.1 source, used by the guards
-- that discover a vocabulary by reading the mod's own sources.
--
-- WHY THIS EXISTS (the defect it replaces).  tests/test_reason_line.lua used
-- to discover the decision-reason vocabulary with a text pattern over the raw
-- file:
--
--     text:gmatch('setDecision%(%s*"[%w_]+"%s*,%s*"([%w_]+)"')
--
-- A raw-text pattern cannot tell CODE from a COMMENT or from the inside of a
-- string literal, and this repo documents its own call shapes in doc comments,
-- so the pattern harvested phantoms.  Measured on the tree at b659c89:
--
--   * AutoPilot_Media.lua:334 is the doc comment
--       "--- and records the moment via setDecision(\"media\", \"stalled\") ..."
--     and it fed the token `stalled` into the guard exactly as the real call
--     at line 352 did.  A mapped label whose ONLY remaining emitter is a
--     comment therefore reads as live: the drift guard's whole job is to
--     report that mapping as dead, and it reported it as emitted instead.
--   * AutoPilot_Telemetry.lua:280 is the DEFINITION
--       "function AutoPilot_Telemetry.setDecision(action, reason, ...)"
--     which any raw-text call scan sees as a call whose reason argument is not
--     a literal -- a false positive, and L-031's point that a guard reporting
--     garbage gets deleted, so a false positive is as fatal as a false one.
--   * AutoPilot_Mood.lua:257 quotes the DYNAMIC shape inside a comment
--       "-- `setDecision(\"read\", boredOrSad and \"boredom\" or \"stress\")`"
--     so a scan that grew a second pattern for the and/or form -- the obvious
--     fix, and the one the backlog item proposed -- would have harvested
--     `boredom` and `stress` from prose describing a shape production
--     deliberately does not use.
--
-- Reading the token stream removes all three by construction rather than by
-- adding one more pattern per shape, which is a race a regex cannot win.
--
-- SCOPE.  This is a LEXER, not a parser: it produces a token stream and finds
-- call sites in it.  It knows nothing about scoping, precedence, or types, and
-- it does not need to -- every question asked of it ("is this argument a single
-- string token?", "is this name preceded by `function`?") is answerable from
-- tokens alone.  Lua 5.1 has no AST library in its standard distribution and
-- this repo takes no dependencies, so a hand lexer is the real-parser option
-- actually available here.
--
-- Loaded with dofile() from a test, exactly like tests/lua_mock_pz.lua.

LuaSourceScan = {}

-- ── Long-bracket helper ──────────────────────────────────────────────────────
-- Lua 5.1 long brackets are `[`, N `=`, `[` and close with `]`, N `=`, `]`.
-- Used for BOTH long strings ([[...]], [==[...]==]) and long comments
-- (--[[...]], --[==[...]==]).
-- @param text string
-- @param i    number  index of the opening `[`
-- @return level number|nil, bodyStart number|nil
local function longBracket(text, i)
    local j = i + 1
    local level = 0
    while text:sub(j, j) == "=" do
        level = level + 1
        j = j + 1
    end
    if text:sub(j, j) == "[" then
        return level, j + 1
    end
    return nil
end

local function countNewlines(s)
    local n = 0
    for _ in s:gmatch("\n") do n = n + 1 end
    return n
end

--- Tokenize Lua 5.1 source.
--
-- Comments (both forms) are DISCARDED, which is the whole point: nothing a
-- comment says can reach a caller.  String literals become single tokens of
-- type "string", so text that merely LOOKS like code inside a string cannot
-- masquerade as code either.
--
-- Token: { type = "name"|"string"|"number"|"op", value = string, line = number }
-- Keywords are typed "name"; callers that care compare the value.
-- A short string's value keeps its escape sequences verbatim (`\"` stays
-- `\"`): every token this repo asks about matches ^[%w_]+$, so decoding would
-- add a failure mode and buy nothing.
-- @param text string
-- @return table  array of tokens
function LuaSourceScan.tokenize(text)
    local toks = {}
    local i, n, line = 1, #text, 1

    local function push(t, v, l)
        toks[#toks + 1] = { type = t, value = v, line = l or line }
    end

    while i <= n do
        local c = text:sub(i, i)

        if c == "\n" then
            line = line + 1
            i = i + 1

        elseif c == " " or c == "\t" or c == "\r" then
            i = i + 1

        elseif text:sub(i, i + 1) == "--" then
            -- Comment: long form first, then to end of line.
            local level, bodyStart
            if text:sub(i + 2, i + 2) == "[" then
                level, bodyStart = longBracket(text, i + 2)
            end
            if level then
                local close = "]" .. string.rep("=", level) .. "]"
                local e = text:find(close, bodyStart, true)
                local body
                if e then
                    body = text:sub(bodyStart, e - 1)
                    i = e + #close
                else
                    body = text:sub(bodyStart)
                    i = n + 1
                end
                line = line + countNewlines(body)
            else
                local e = text:find("\n", i, true)
                i = e or (n + 1)
            end

        elseif c == "[" then
            local level, bodyStart = longBracket(text, i)
            if level then
                local close = "]" .. string.rep("=", level) .. "]"
                local e = text:find(close, bodyStart, true)
                local startLine = line
                local body
                if e then
                    body = text:sub(bodyStart, e - 1)
                    i = e + #close
                else
                    body = text:sub(bodyStart)
                    i = n + 1
                end
                push("string", body, startLine)
                line = line + countNewlines(body)
            else
                push("op", "[")
                i = i + 1
            end

        elseif c == '"' or c == "'" then
            local quote = c
            local j = i + 1
            local buf = {}
            while j <= n do
                local ch = text:sub(j, j)
                if ch == "\\" then
                    buf[#buf + 1] = text:sub(j, j + 1)
                    j = j + 2
                elseif ch == quote or ch == "\n" then
                    break
                else
                    buf[#buf + 1] = ch
                    j = j + 1
                end
            end
            push("string", table.concat(buf))
            i = j + 1

        elseif c:match("[%a_]") then
            local word = text:match("^[%a_][%w_]*", i)
            push("name", word)
            i = i + #word

        elseif c:match("%d") then
            local num = text:match("^[%w%.]+", i) or c
            push("number", num)
            i = i + #num

        else
            local three = text:sub(i, i + 2)
            local two   = text:sub(i, i + 1)
            if three == "..." then
                push("op", three)
                i = i + 3
            elseif two == "==" or two == "~=" or two == "<=" or two == ">="
                or two == ".." then
                push("op", two)
                i = i + 2
            else
                push("op", c)
                i = i + 1
            end
        end
    end

    return toks
end

--- Find calls to a named function in a token stream.
--
-- Matches on the FINAL name component, so `setDecision(...)` and
-- `AutoPilot_Telemetry.setDecision(...)` are both found without the caller
-- hardcoding a receiver.  A DEFINITION (`function T.setDecision(a, b)`) is
-- excluded: it is a parameter list, not an argument list, and counting it as a
-- call is the false-positive half of the raw-text failure.
--
-- @param toks table   from LuaSourceScan.tokenize
-- @param name string   function name to find
-- @return table  array of { line = number, args = { {token,...}, ... } }
function LuaSourceScan.callsIn(toks, name)
    local out = {}

    for idx = 1, #toks do
        local t    = toks[idx]
        local open = toks[idx + 1]
        if t.type == "name" and t.value == name
            and open and open.type == "op" and open.value == "(" then

            -- Walk back over `name (. name)*` to see whether `function` heads it.
            local k = idx
            while k >= 3 and toks[k - 1].type == "op"
                and (toks[k - 1].value == "." or toks[k - 1].value == ":")
                and toks[k - 2].type == "name" do
                k = k - 2
            end
            local head = toks[k - 1]
            local isDefinition = head ~= nil and head.type == "name"
                and head.value == "function"

            if not isDefinition then
                local args, cur, depth = {}, {}, 0
                local j = idx + 1
                while j <= #toks do
                    local tk = toks[j]
                    if tk.type == "op"
                        and (tk.value == "(" or tk.value == "{" or tk.value == "[") then
                        depth = depth + 1
                        if depth > 1 then cur[#cur + 1] = tk end
                    elseif tk.type == "op"
                        and (tk.value == ")" or tk.value == "}" or tk.value == "]") then
                        depth = depth - 1
                        if depth == 0 then
                            args[#args + 1] = cur
                            break
                        end
                        cur[#cur + 1] = tk
                    elseif tk.type == "op" and tk.value == "," and depth == 1 then
                        args[#args + 1] = cur
                        cur = {}
                    else
                        cur[#cur + 1] = tk
                    end
                    j = j + 1
                end
                -- `f()` collects one empty argument; a no-arg call has none.
                if #args == 1 and #args[1] == 0 then args = {} end
                out[#out + 1] = { line = t.line, args = args }
            end
        end
    end

    return out
end

--- The string value of an argument that is EXACTLY one string literal.
-- Anything else -- a variable, an `and`/`or` expression, an index, a
-- concatenation, a call -- returns nil, which is the whole discrimination the
-- completeness guard needs.
-- @param arg table|nil  one entry of a call's `args`
-- @return string|nil
function LuaSourceScan.literalArg(arg)
    if arg and #arg == 1 and arg[1].type == "string" then
        return arg[1].value
    end
    return nil
end

--- A readable rendering of an argument, for failure messages.
-- @param arg table|nil
-- @return string
function LuaSourceScan.argText(arg)
    if not arg or #arg == 0 then return "<missing>" end
    local parts = {}
    for _, t in ipairs(arg) do
        if t.type == "string" then
            parts[#parts + 1] = '"' .. t.value .. '"'
        else
            parts[#parts + 1] = t.value
        end
    end
    return table.concat(parts, " ")
end

--- Find `return false, "<label>"` statements in a token stream.
-- The fail-label half of the reason vocabulary, read the same lexical way so a
-- documented example in a comment cannot widen the vocabulary either.
-- @param toks table
-- @return table  array of { label = string, line = number }
function LuaSourceScan.returnFalseLabelsIn(toks)
    local out = {}
    for i = 1, #toks - 3 do
        if toks[i].type == "name" and toks[i].value == "return"
            and toks[i + 1].type == "name" and toks[i + 1].value == "false"
            and toks[i + 2].type == "op" and toks[i + 2].value == ","
            and toks[i + 3].type == "string" then
            out[#out + 1] = { label = toks[i + 3].value, line = toks[i].line }
        end
    end
    return out
end

return LuaSourceScan
