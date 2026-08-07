-- tests/test_privacy_guard.lua
-- Telemetry privacy guard: the mod's telemetry must stay LOCAL and must never
-- capture anything that identifies the human at the keyboard.
--
-- THE STANDING OBLIGATION THIS SUITE MECHANIZES
-- ---------------------------------------------
-- The DevSecOps stream has carried a recurring manual check since 2026-07-20:
-- "the telemetry run log never captures anything sensitive and stays local
-- under ~/Zomboid/Lua/".  Every sweep so far re-read the writers by hand and
-- reported "still clean" -- purely numeric game state, no username or SteamID
-- capture anywhere.  A manual glance decays: the telemetry surface has grown
-- three times since that check was written (sessions-log schema 3 XP fields,
-- decision reasons, session history), and nothing failed CI when it did.
-- This suite pins the invariant so the NEXT writer change has one cost:
-- keep the surface clean, or fail loudly here.
--
-- THREE INVARIANTS, EACH SCANNED STATICALLY OVER COMMENT-STRIPPED SOURCE
-- ----------------------------------------------------------------------
--   1. IDENTITY: no production module reads a player-identity surface
--      (getUsername / getSteamID / getOnlineID / getForename / getSurname /
--      getDisplayName).  The one legitimate lookalike is allow-listed WITH a
--      citation and rot-guarded: BodyPartType.getDisplayName in
--      AutoPilot_Medical.lua is a body-part label ("Left Arm") feeding wound
--      telemetry, not a person.
--   2. SANDBOX: no raw io.* file or process access, and no os.getenv /
--      os.execute / os.remove / os.rename.  Production file I/O goes through
--      getFileWriter/getFileReader ONLY -- PZ's sandboxed writers, which can
--      reach nothing outside ~/Zomboid/Lua/.  (Test files use io.* freely;
--      this suite scans 42/ only.  os.time/os.clock/os.date are already
--      prohibited by tests/test_clock_discipline.lua and are not re-checked
--      here.)
--   3. NAMESPACE: every file name that reaches getFileWriter/getFileReader
--      resolves to the auto_pilot* namespace, so the mod can never clobber
--      another mod's file or scatter output beyond its own recognizable set.
--      An argument shape the resolver cannot follow is a FAILURE, never a
--      silent pass.
--
-- Discovery is GLOB-DRIVEN with a zero-match hard failure, like
-- tests/test_engine_symbols.lua and test_clock_discipline.lua.
--
-- Run from the project root with standard Lua 5.1:
--   lua tests/test_privacy_guard.lua

-- ── Minimal test framework ────────────────────────────────────────────────────
local PASS = 0
local FAIL = 0

local function assert_eq(desc, got, expected)
    if got == expected then
        print(("  PASS  %s"):format(desc))
        PASS = PASS + 1
    else
        io.stderr:write(("  FAIL  %s  (got=%s, expected=%s)\n"):format(
            desc, tostring(got), tostring(expected)))
        FAIL = FAIL + 1
    end
end

local function assert_true(desc, val) assert_eq(desc, not not val, true) end

-- ── Discovery (glob-driven, zero-match hard failure) ──────────────────────────
local function productionFiles()
    local files = {}
    -- No stderr redirect: `2>/dev/null` is shell syntax that io.popen's Windows
    -- host (cmd.exe) does not understand, and swallowing the error would be the
    -- wrong trade anyway -- an empty list must fail loudly, not pass quietly.
    local pipe = io.popen("ls -1 42/media/lua/client/*.lua")
    if pipe then
        for line in pipe:lines() do
            line = line:gsub("%s+$", "")
            if line ~= "" then files[#files + 1] = line end
        end
        pipe:close()
    end
    table.sort(files)
    return files
end

local function readFile(path)
    local fh = io.open(path, "r")
    if not fh then return nil end
    local text = fh:read("*a")
    fh:close()
    return text
end

-- Comments are not code (same discipline as test_clock_discipline.lua):
-- several modules NAME these surfaces in prose without calling them.
local function stripComments(text)
    local out = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local cut = line:find("%-%-")
        out[#out + 1] = cut and line:sub(1, cut - 1) or line
    end
    return table.concat(out, "\n")
end

-- ── The deny list ─────────────────────────────────────────────────────────────
-- Every pattern requires the call shape (open paren) except getSteamID, where
-- ANY mention is suspect.  The [^%w_%.] prefix on stdlib patterns rejects
-- lookalike identifiers (photos.getenv, myio.open); scanners prepend "\n" so
-- the prefix can match at the start of the text.
local DENY_PATTERNS = {
    -- Invariant 1: player identity.
    ["getUsername"]    = "getUsername%s*%(",
    ["getSteamID"]     = "getSteamID",
    ["getOnlineID"]    = "getOnlineID%s*%(",
    ["getForename"]    = "getForename%s*%(",
    ["getSurname"]     = "getSurname%s*%(",
    ["getDisplayName"] = "getDisplayName%s*%(",
    -- Invariant 2: environment and process escape hatches.
    ["os.getenv"]  = "[^%w_%.]os%.getenv%s*%(",
    ["os.execute"] = "[^%w_%.]os%.execute%s*%(",
    ["os.remove"]  = "[^%w_%.]os%.remove%s*%(",
    ["os.rename"]  = "[^%w_%.]os%.rename%s*%(",
    -- Invariant 2: raw file I/O bypassing the PZ sandbox.
    ["io.open"]   = "[^%w_%.]io%.open%s*%(",
    ["io.popen"]  = "[^%w_%.]io%.popen%s*%(",
    ["io.lines"]  = "[^%w_%.]io%.lines%s*%(",
    ["io.read"]   = "[^%w_%.]io%.read%s*%(",
    ["io.write"]  = "[^%w_%.]io%.write%s*%(",
    ["io.input"]  = "[^%w_%.]io%.input%s*%(",
    ["io.output"] = "[^%w_%.]io%.output%s*%(",
}

-- ── The allow list ────────────────────────────────────────────────────────────
-- An entry admits ONLY hits that also match its narrower `covers` pattern, in
-- ONE named file, and Test 3 fails the build when the covered call disappears
-- (a stale exemption is a hole waiting for a new call to walk through it).
local ALLOWED = {
    {
        deny   = "getDisplayName",
        file   = "AutoPilot_Medical.lua",
        covers = "BodyPartType%s*%.%s*getDisplayName%s*%(",
        why    = "body-part label for wound handling (e.g. 'Left Arm'); "
            .. "a type enum's display string, not a person",
    },
}

-- Count occurrences of a pattern in comment-stripped code.
local function countMatches(code, pat)
    local n = 0
    for _ in code:gmatch(pat) do n = n + 1 end
    return n
end

-- Returns a map denyName -> { total = n, covered = m } for one file's RAW
-- text.  Comment stripping and the [^%w_%.]-prefix newline happen HERE, so no
-- caller (including the self-controls) can accidentally scan unstripped text.
local function scanDenied(text, base)
    local code = "\n" .. stripComments(text)
    local hits = {}
    for name, pat in pairs(DENY_PATTERNS) do
        local total = countMatches(code, pat)
        if total > 0 then
            local covered = 0
            for _, allow in ipairs(ALLOWED) do
                if allow.deny == name and allow.file == base then
                    covered = covered + countMatches(code, allow.covers)
                end
            end
            hits[name] = { total = total, covered = covered }
        end
    end
    return hits
end

-- ── The namespace resolver (invariant 3) ──────────────────────────────────────
-- For every getFileWriter( / getFileReader( callsite, resolve the first
-- argument to the string literal that ultimately names the file:
--   shape 1  "auto_pilot_run.log"       literal            -> check directly
--   shape 2  _logFile(pnum)             local helper call  -> every `return` in
--                                       the helper must START with an
--                                       auto_pilot* literal
--   shape 3  DEATHS_FILE                local constant     -> its assignment
--                                       literal must start with auto_pilot
-- Anything else is UNRESOLVED and fails: a namespace guard that shrugs at a
-- shape it cannot follow is decoration.
local FILE_PREFIX = "auto_pilot"

local function resolveHelper(code, name)
    -- Grab the helper's body: from its definition to the first line that is
    -- exactly `end` at column 0 (repo style for top-level locals).  Helpers
    -- here are small and contain no nested named functions.
    local defPat = "local%s+function%s+" .. name .. "%s*%("
    local s = code:find(defPat)
    if not s then return nil, "helper '" .. name .. "' not found" end
    local body = code:sub(s)
    local e = body:find("\nend")
    if e then body = body:sub(1, e) end
    local returns, bad = 0, 0
    for lit in body:gmatch('return%s+"([^"]*)"') do
        returns = returns + 1
        if lit:sub(1, #FILE_PREFIX) ~= FILE_PREFIX then bad = bad + 1 end
    end
    if returns == 0 then
        return nil, "helper '" .. name .. "' has no literal-first return"
    end
    if bad > 0 then
        return nil, "helper '" .. name .. "' returns a non-" .. FILE_PREFIX
            .. "* name"
    end
    return true
end

local function resolveConstant(code, name)
    local lit = code:match("local%s+" .. name .. '%s*=%s*"([^"]*)"')
    if not lit then return nil, "constant '" .. name .. "' not resolvable" end
    if lit:sub(1, #FILE_PREFIX) ~= FILE_PREFIX then
        return nil, "constant '" .. name .. "' = '" .. lit .. "' is outside "
            .. FILE_PREFIX .. "*"
    end
    return true
end

-- Returns (count, problems): callsites seen, list of failure strings.
-- Takes RAW text, same discipline as scanDenied.
local function checkFileNamespace(text, base)
    local code = "\n" .. stripComments(text)
    local problems = {}
    local count = 0
    local pos = 1
    while true do
        local s, e = code:find("getFile[WR][a-z]+%s*%(", pos)
        if not s then break end
        count = count + 1
        pos = e + 1
        local rest = code:sub(e + 1, e + 120)
        local lit = rest:match('^%s*"([^"]*)"')
        local call = rest:match("^%s*([%a_][%w_]*)%s*%(")
        local const = rest:match("^%s*([A-Z_][A-Z0-9_]*)%s*[,%)]")
        local ok, err
        if lit then
            ok = lit:sub(1, #FILE_PREFIX) == FILE_PREFIX
            err = ok and nil
                or ('literal "%s" is outside %s*'):format(lit, FILE_PREFIX)
        elseif call then
            ok, err = resolveHelper(code, call)
        elseif const then
            ok, err = resolveConstant(code, const)
        else
            ok, err = nil, "unresolvable first argument: "
                .. rest:sub(1, 30):gsub("%s+", " ")
        end
        if not ok then
            problems[#problems + 1] = base .. " :: " .. (err or "?")
        end
    end
    return count, problems
end

-- ── 1. Discovery and scanner blindness guards ─────────────────────────────────
print("\n-- Test 1: discovery finds the modules and the scanner sees real code")
local files = productionFiles()
do
    -- Zero-match HARD FAILURE: an empty ls is a broken glob or a moved tree,
    -- never a clean result.
    assert_true(("glob discovery found modules (got %d, need >= 20)")
        :format(#files), #files >= 20)

    -- The scanner must be able to SEE the surfaces it guards, or a regression
    -- in the scanner itself would report clean forever.  Two proofs from real
    -- code: the sandboxed writers exist (>= 3 callsites across telemetry,
    -- session history, death log, options), and the one allow-listed call is
    -- actually found where its citation says it is.
    local writerSites = 0
    local allowSeen = 0
    for _, path in ipairs(files) do
        local text = readFile(path)
        if text then
            local n = checkFileNamespace(text, path)
            writerSites = writerSites + n
            local base = path:match("([^/]+)$") or path
            for _, allow in ipairs(ALLOWED) do
                if allow.file == base then
                    allowSeen = allowSeen
                        + countMatches("\n" .. stripComments(text),
                            allow.covers)
                end
            end
        end
    end
    assert_true(("scanner sees the sandboxed writer callsites (got %d, "
        .. "need >= 3)"):format(writerSites), writerSites >= 3)
    assert_true("scanner finds every allow-listed call at its cited home",
        allowSeen >= #ALLOWED)
end

-- ── 2. Forward: no denied surface in any production module ────────────────────
print("\n-- Test 2: no identity read, no io.*, no os escape hatch in 42/")
do
    local violations = {}
    for _, path in ipairs(files) do
        local base = path:match("([^/]+)$") or path
        local text = readFile(path)
        if text then
            local hits = scanDenied(text, base)
            for name, h in pairs(hits) do
                if h.total > h.covered then
                    violations[#violations + 1] = base .. " :: " .. name
                        .. " x" .. (h.total - h.covered)
                end
            end
        end
    end
    table.sort(violations)
    assert_eq("no denied privacy surface in shipped client Lua "
        .. "(add nothing here without an allow-list entry AND a citation)",
        table.concat(violations, ", "), "")
end

-- ── 3. Allow-list rot guard ───────────────────────────────────────────────────
print("\n-- Test 3: every allow-list entry still covers a live call")
do
    local stale = {}
    for _, allow in ipairs(ALLOWED) do
        local found = 0
        for _, path in ipairs(files) do
            local base = path:match("([^/]+)$") or path
            if base == allow.file then
                local raw = readFile(path)
                if raw then
                    found = countMatches("\n" .. stripComments(raw),
                        allow.covers)
                end
            end
        end
        if found == 0 then
            stale[#stale + 1] = allow.file .. " :: " .. allow.deny
        end
    end
    assert_eq("no stale allow-list entries (delete the entry when the call "
        .. "goes away)", table.concat(stale, ", "), "")
end

-- ── 4. Namespace: every resolved file name starts with auto_pilot ─────────────
print("\n-- Test 4: every getFileWriter/getFileReader name resolves to "
    .. FILE_PREFIX .. "*")
do
    local allProblems = {}
    local total = 0
    for _, path in ipairs(files) do
        local base = path:match("([^/]+)$") or path
        local text = readFile(path)
        if text then
            local n, problems = checkFileNamespace(text, base)
            total = total + n
            for _, p in ipairs(problems) do
                allProblems[#allProblems + 1] = p
            end
        end
    end
    table.sort(allProblems)
    assert_eq(("all %d writer/reader callsites resolve into the %s* "
        .. "namespace"):format(total, FILE_PREFIX),
        table.concat(allProblems, ", "), "")
end

-- ── 5. Scanner self-controls (the guard can both fire and stay silent) ────────
print("\n-- Test 5: scanner controls on synthetic input")
do
    -- Identity: fires on the call, silent on a lookalike and on a comment.
    local hits = scanDenied("\nlocal u = player:getUsername()", "X.lua")
    assert_true("getUsername() call is reported",
        hits.getUsername and hits.getUsername.total == 1)
    hits = scanDenied("\nlocal l = getUsernameLabel(x)", "X.lua")
    assert_eq("a lookalike (getUsernameLabel) is not reported",
        hits.getUsername, nil)
    hits = scanDenied("\n-- getUsername() is documented, not called", "X.lua")
    assert_eq("a commented getUsername() is not reported", hits.getUsername,
        nil)

    -- getSteamID needs no call shape: any mention is suspect.
    hits = scanDenied("\nlocal id = player:getSteamID()", "X.lua")
    assert_true("getSteamID is reported", hits.getSteamID ~= nil)

    -- Sandbox: fires on io.open, silent on a lookalike module.
    hits = scanDenied("\nlocal fh = io.open('x.txt', 'w')", "X.lua")
    assert_true("io.open() is reported",
        hits["io.open"] and hits["io.open"].total == 1)
    hits = scanDenied("\nlocal fh = myio.open('x.txt', 'w')", "X.lua")
    assert_eq("a lookalike (myio.open) is not reported", hits["io.open"], nil)
    hits = scanDenied("\nlocal v = os.getenv('HOME')", "X.lua")
    assert_true("os.getenv() is reported",
        hits["os.getenv"] and hits["os.getenv"].total == 1)

    -- Allow-list scoping: the covered shape passes ONLY in its cited file.
    hits = scanDenied("\nBodyPartType.getDisplayName(t)",
        "AutoPilot_Medical.lua")
    assert_true("allow-listed shape is fully covered in its cited file",
        hits.getDisplayName and hits.getDisplayName.covered
        == hits.getDisplayName.total)
    hits = scanDenied("\nBodyPartType.getDisplayName(t)", "AutoPilot_Other.lua")
    assert_true("the same shape in a DIFFERENT file is NOT covered",
        hits.getDisplayName and hits.getDisplayName.covered == 0)
    hits = scanDenied("\nplayer:getDisplayName()", "AutoPilot_Medical.lua")
    assert_true("a player getDisplayName in the cited file is NOT covered",
        hits.getDisplayName
        and hits.getDisplayName.total > hits.getDisplayName.covered)

    -- Namespace resolver: all three shapes plus the unresolvable failure.
    local n, probs = checkFileNamespace(
        '\nlocal w = getFileWriter("auto_pilot_x.log", true, true)', "X.lua")
    assert_true("a good literal resolves clean", n == 1 and #probs == 0)
    n, probs = checkFileNamespace(
        '\nlocal w = getFileWriter("console.txt", true, true)', "X.lua")
    assert_true("a foreign literal is a violation", n == 1 and #probs == 1)
    n, probs = checkFileNamespace(
        '\nlocal function _f(p)\n    return "auto_pilot_y" .. p .. ".log"\n'
        .. 'end\nlocal w = getFileWriter(_f(1), true, true)', "X.lua")
    assert_true("a helper whose returns start with the prefix resolves clean",
        n == 1 and #probs == 0)
    n, probs = checkFileNamespace(
        '\nlocal function _f(p)\n    return "other_" .. p .. ".log"\nend\n'
        .. 'local w = getFileWriter(_f(1), true, true)', "X.lua")
    assert_true("a helper returning a foreign name is a violation",
        n == 1 and #probs == 1)
    n, probs = checkFileNamespace(
        '\nlocal F = 1\nlocal w = getFileWriter(name .. ".log", true, true)',
        "X.lua")
    assert_true("an unresolvable argument shape FAILS rather than passing",
        n == 1 and #probs == 1)
end

-- ── Summary ───────────────────────────────────────────────────────────────────
print(("\n=== Results: %d passed, %d failed ==="):format(PASS, FAIL))
if FAIL > 0 then os.exit(1) end
