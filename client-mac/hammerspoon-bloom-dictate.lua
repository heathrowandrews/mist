-- Bloom Dictate (SFSpeech hybrid)
--
-- BloomDictate.app runs in --streamer mode (always-on SFSpeech recognition,
-- 100% on-device via Apple's on-device speech engine) and appends partial
-- transcripts to ~/.bloom-dictate/dictate-stream.jsonl. Hammerspoon owns
-- the hotkey + keystroke output:
--
--   HOLD Right-⌘            → start typing partials past the current baseline
--   quick TAP-TAP Right-⌘   → lock; tap again to stop
--   ⌃⌥⌘Escape               → cancel without finalizing
--
-- Right-Command keyCode = 54 (verified 2026-05-12).
-- bdTap is GLOBAL so the eventtap isn't collected by Lua GC.
-- -------------------------------------------------------------------------

local KEY_RIGHT_CMD = 54

local HOLD_THRESHOLD     = 0.25
local DOUBLE_TAP_WINDOW  = 0.35
local REVISION_DEBOUNCE_SEC = 0.20
local END_GRACE_SEC      = 2.25
local CHIMES_ENABLED     = true

local state             = "idle"
local rcmdDown          = false
local pressedAt         = 0
local pendingStopTimer  = nil
local pendingRevisionTimer = nil
local pendingRevision   = nil
local pendingEndTimer    = nil
local finishPendingEnd   = nil

-- SFSpeech streamer state
local STREAM_PATH       = os.getenv("HOME") .. "/.bloom-dictate/dictate-stream.jsonl"
local streamPoller      = nil
local streamFilePos     = 0
local lastPartial       = ""       -- most recent partial we've SEEN from SFSpeech
local isTyping          = false    -- true while hotkey is held / locked
local baselinePartial   = ""       -- partial text at the moment recording started
local typedText         = ""       -- chars we've actually keystroked this session
local sessionTypedAny   = false    -- have we typed any non-space char this session?
local segmentClosed     = false    -- final event seen; next partial is a fresh utterance
local targetApp         = nil      -- app that owned focus when dictation began
local priorSessionEndedWithContent = false   -- previous dictation ended with non-space content; new session should prepend a space
local bridgeSpaceAtSessionStart = false

local function completeRecordSize(path)
    local f = io.open(path, "r")
    if not f then return 0 end
    local size = f:seek("end") or 0
    if size == 0 then
        f:close()
        return 0
    end
    local window = math.min(size, 8192)
    f:seek("set", size - window)
    local tail = f:read("*a") or ""
    f:close()
    if tail:sub(-1) == "\n" then return size end
    local lastNewline = tail:match(".*()\n")
    if lastNewline then return (size - window) + lastNewline end
    return 0
end

-- Type Unicode into the app that owned focus when dictation began. We post
-- explicit keyDown/keyUp events with flags cleared so the physical ⌘ key
-- being held for PTT cannot turn text into shortcuts.
local function postUnicode(text)
    if text == nil or #text == 0 then return end
    local app = targetApp or hs.application.frontmostApplication()
    local chunkSize = 20
    local i = 1
    while i <= #text do
        local chunk = text:sub(i, i + chunkSize - 1)
        local down = hs.eventtap.event.newEvent()
        down:setType(hs.eventtap.event.types.keyDown)
        down:setKeyCode(0)
        down:setFlags({})
        down:setUnicodeString(chunk)
        down:post(app)

        local up = hs.eventtap.event.newEvent()
        up:setType(hs.eventtap.event.types.keyUp)
        up:setKeyCode(0)
        up:setFlags({})
        up:setUnicodeString(chunk)
        up:post(app)

        i = i + chunkSize
        if i <= #text then hs.timer.usleep(3000) end
    end
end

-- Auto-capitalize the first letter we type in a session so dictation starts
-- with a capital like native macOS dictation does. Also bridge between
-- sessions: if the prior dictation ended with non-space content (and the
-- user has now started a new session), prepend a space so words don't
-- jam together — "First thought" + "Second thought" should render as
-- "First thought Second thought", not "First thoughtSecond thought".
local function smartType(text)
    if not sessionTypedAny then
        -- Bridge from prior session.
        if bridgeSpaceAtSessionStart and text:match("^%w") then
            text = " " .. text
            bridgeSpaceAtSessionStart = false
        end
        -- Capitalize the first letter character we find; preserve leading
        -- whitespace and any trailing content.
        local prefix, letter, rest = text:match("^(%s*)(%a)(.*)$")
        if letter then
            text = prefix .. letter:upper() .. rest
            sessionTypedAny = true
        else
            -- Text is entirely whitespace/punctuation; don't flip the flag yet.
        end
    end
    postUnicode(text)
end

local function focusedTextNeedsBridgeSpace()
    if not priorSessionEndedWithContent then return false end

    local ok, elem = pcall(hs.uielement.focusedElement)
    if not ok or not elem then return false end

    local value = elem:attributeValue("AXValue")
    if type(value) ~= "string" or #value == 0 then return false end

    local range = elem:attributeValue("AXSelectedTextRange")
    local location = nil
    if type(range) == "table" then
        location = range.location or range.loc
    end

    if type(location) == "number" then
        if location <= 0 then return false end
        local beforeCursor = value:sub(1, location)
        return #beforeCursor > 0 and not beforeCursor:match("%s$")
    end

    return not value:match("%s$")
end

local function commonPrefixLen(a, b)
    local max = math.min(#a, #b)
    local i = 0
    while i < max and a:sub(i + 1, i + 1) == b:sub(i + 1, i + 1) do
        i = i + 1
    end
    return i
end

-- Case-insensitive ASCII prefix check. SFSpeech sometimes revises a partial
-- only to add capitalization + punctuation ("first thought" → "First
-- thought."). The byte-for-byte growth check fails on that case mismatch
-- and falls to the revision branch, which then backspaces everything we
-- typed. Treating such revisions as growth (with the rendered case kept
-- on screen) avoids the disruptive erase-and-retype.
local function startsWithCI(haystack, needle)
    if #needle == 0 then return true end
    if #haystack < #needle then return false end
    return haystack:sub(1, #needle):lower() == needle:lower()
end

local function backspace(count)
    local app = targetApp or hs.application.frontmostApplication()
    for _ = 1, count do
        local down = hs.eventtap.event.newKeyEvent({}, "delete", true)
        down:setFlags({})
        down:post(app)
        local up = hs.eventtap.event.newKeyEvent({}, "delete", false)
        up:setFlags({})
        up:post(app)
    end
end

-- Bloom glossary: instant local find-replace pass that fires on release.
-- SFSpeech doesn't know project-specific proper nouns ("open claw" instead
-- of "OpenClaw", etc.). After dictation ends, we run the typed text through
-- these patterns, diff against what we typed, and silently backspace +
-- retype only the corrected portion. No network round-trip; ~5ms latency.
--
-- Patterns use Lua's %f[%w] / %f[%W] frontiers as word boundaries so we
-- match whole words only ("term" but not "terminal"). Each entry is
-- {wrong-pattern, correct-replacement, also-match-capitalized}.
local GLOSSARY_REPLACEMENTS = {
    -- Bloom products / tools
    { "open claw",  "OpenClaw" },
    { "open clause","OpenClaw" },
    { "openclaw",   "OpenClaw" },
    { "voice box",  "VoiceBox" },
    { "answer host","AnswerHost" },
    { "bloom dictate", "Bloom Dictate" },
    -- Tech
    { "tail scale", "Tailscale" },
    { "tail wind",  "Tailwind" },
    { "shad cn",    "shadcn" },
    { "shadCN",     "shadcn" },
    -- Devices
    { "plowed",     "Plaud" },
    { "Plod",       "Plaud" },
    -- Workflow
    { "dog voting", "dogfooding" },
    { "dog food",   "dogfood" },
}

local function loadLocalGlossaryReplacements()
    local path = os.getenv("HOME") .. "/.bloom-dictate/hammerspoon-glossary.lua"
    local ok, extra = pcall(dofile, path)
    if not ok or type(extra) ~= "table" then return end
    for _, pair in ipairs(extra) do
        if type(pair) == "table" and type(pair[1]) == "string" and type(pair[2]) == "string" then
            table.insert(GLOSSARY_REPLACEMENTS, pair)
        end
    end
end
loadLocalGlossaryReplacements()

local function applyGlossaryCorrections(text)
    if not text or #text == 0 then return text end
    local result = text
    for _, pair in ipairs(GLOSSARY_REPLACEMENTS) do
        local pattern = "%f[%w]" .. pair[1]:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1") .. "%f[%W]"
        result = result:gsub(pattern, pair[2])
        -- Also handle Capitalized-first-letter variant (sentence starts)
        local capFirst = pair[1]:sub(1,1):upper() .. pair[1]:sub(2)
        if capFirst ~= pair[1] then
            local capPattern = "%f[%w]" .. capFirst:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1") .. "%f[%W]"
            local capReplace = pair[2]:sub(1,1):upper() .. pair[2]:sub(2)
            result = result:gsub(capPattern, capReplace)
        end
    end
    return result
end

-- Apply minimal-disruption correction by finding the first divergent
-- character and backspacing + retyping from there.
local function applyCorrection(original, corrected)
    if original == corrected then return end
    local divergeAt = 0
    local maxLen = math.min(#original, #corrected)
    while divergeAt < maxLen
          and original:byte(divergeAt + 1) == corrected:byte(divergeAt + 1) do
        divergeAt = divergeAt + 1
    end
    local bsCount = #original - divergeAt
    if bsCount > 0 then backspace(bsCount) end
    local toType = corrected:sub(divergeAt + 1)
    if #toType > 0 then postUnicode(toType) end
end

local function typeFreshPartial(partial)
    if sessionTypedAny and not typedText:match("%s$") and partial:match("^%w") then
        smartType(" ")
    end
    smartType(partial)
    baselinePartial = partial
    typedText = ""
end

-- Auto-launch BloomDictate.app --streamer if it's not running
local function ensureStreamerRunning()
    local out, ok = hs.execute("pgrep -f 'BloomDictate.*--streamer' >/dev/null && echo yes || echo no")
    if (out or ""):find("yes") then return end
    hs.task.new("/usr/bin/open", nil,
        { os.getenv("HOME") .. "/Applications/BloomDictate.app", "--args", "--streamer" }
    ):start()
end

-- Menubar indicator: flips between 🎙 (recording) and 🌱 (idle) so the
-- current state is visible at a glance.
local bdMenubar = hs.menubar.new()
local function bdSetMenubar(recording)
    if not bdMenubar then return end
    if recording then
        bdMenubar:setTitle("🎙")
        bdMenubar:setTooltip("Bloom Dictate · recording")
    else
        bdMenubar:setTitle("🌱")
        bdMenubar:setTooltip("Bloom Dictate · hold Right-⌘ or double-tap to lock")
    end
end
bdSetMenubar(false)

local function playChime(kind)
    if not CHIMES_ENABLED then return end
    local names = {
        start = "Tink",
        stop = "Pop",
        lock = "Glass",
        cancel = "Basso",
    }
    local soundName = names[kind]
    if not soundName then return end
    local sound = hs.sound.getByName(soundName)
    if sound then sound:play() end
end

local function cancelPending()
    if pendingStopTimer then
        pendingStopTimer:stop()
        pendingStopTimer = nil
    end
end

-- Read new SFSpeech events since last poll. Each {"type":"partial","text":...}
-- gives the FULL transcript so far for the CURRENT recognition session.
-- SFSpeech rotates sessions periodically (~50s) and on natural utterance
-- boundaries, so the partial text can reset to short or completely diverge.
-- We handle three cases:
--   1. First partial after beginTyping → adopt as baseline (might be the
--      tail of an in-flight pre-press utterance). Don't type.
--   2. Partial extends baseline → type growth past what we've already typed.
--   3. Partial diverges (session rotation / fresh utterance) → type it whole
--      and adopt as new baseline. This is the common case after a press.
local function bdHandleLog(msg)
    local f = io.open(os.getenv("HOME") .. "/.bloom-dictate/hs-bd.log", "a")
    if f then
        f:write(os.date("%H:%M:%S") .. " " .. msg .. "\n")
        f:close()
    end
end

local function applyRevision(data, force)
    if not data then return false end
    if not force then
        if not isTyping then
            bdHandleLog("  -> path: revision skipped; typing stopped")
            return false
        end
        if lastPartial ~= data.partial then
            bdHandleLog("  -> path: revision skipped; newer partial arrived")
            return false
        end
        if typedText ~= data.typedAtSchedule then
            bdHandleLog("  -> path: revision skipped; typed text changed")
            return false
        end
    end

    local newPortion = data.newPortion
    local keep = commonPrefixLen(typedText, newPortion)
    local deleteCount = #typedText - keep
    local toType = newPortion:sub(keep + 1)
    bdHandleLog("  -> path: revision apply, keep=" .. keep .. " delete=" .. deleteCount .. " type.len=" .. #toType)
    if deleteCount > 0 then
        backspace(deleteCount)
    end
    if #toType > 0 then
        smartType(toType)
    end
    typedText = newPortion
    segmentClosed = (data.eventType == "final")
    return true
end

local function flushPendingRevision(reason, force)
    if pendingRevisionTimer then
        pendingRevisionTimer:stop()
        pendingRevisionTimer = nil
    end
    local data = pendingRevision
    pendingRevision = nil
    if data then
        bdHandleLog("revision flush reason=" .. tostring(reason))
        return applyRevision(data, force == true)
    end
    return false
end

local function cancelPendingRevision(reason)
    if pendingRevisionTimer then
        pendingRevisionTimer:stop()
        pendingRevisionTimer = nil
    end
    if pendingRevision then
        bdHandleLog("revision canceled reason=" .. tostring(reason))
    end
    pendingRevision = nil
end

local function scheduleRevision(partial, eventType, newPortion)
    cancelPendingRevision("superseded")
    pendingRevision = {
        partial = partial,
        eventType = eventType,
        newPortion = newPortion,
        typedAtSchedule = typedText,
    }
    pendingRevisionTimer = hs.timer.doAfter(REVISION_DEBOUNCE_SEC, function()
        pendingRevisionTimer = nil
        local data = pendingRevision
        pendingRevision = nil
        applyRevision(data, false)
    end)
    bdHandleLog("  -> path: revision scheduled debounce=" .. tostring(REVISION_DEBOUNCE_SEC))
end

local function handlePartial(partial, eventType)
    lastPartial = partial
    if not isTyping then return end
    bdHandleLog(string.format(
        "handle isTyping=true et=%s partial.len=%d baseline.len=%d typed.len=%d segClosed=%s",
        tostring(eventType), #partial, #baselinePartial, #typedText, tostring(segmentClosed)))
    if #partial == 0 then
        if eventType == "final" then
            flushPendingRevision("empty final", true)
            bdHandleLog("  -> path: empty final, close segment")
            segmentClosed = true
        end
        return
    end

    if segmentClosed then
        cancelPendingRevision("segment closed")
        bdHandleLog("  -> path: segmentClosed branch, typeFreshPartial")
        segmentClosed = false
        typeFreshPartial(partial)
        segmentClosed = (eventType == "final")
        return
    end

    if partial:sub(1, #baselinePartial) ~= baselinePartial then
        cancelPendingRevision("divergent partial")
        bdHandleLog("  -> path: divergent, typeFreshPartial")
        typeFreshPartial(partial)
        segmentClosed = (eventType == "final")
        return
    end

    -- Same session: type any growth past what we've already typed.
    local newPortion = partial:sub(#baselinePartial + 1)
    if startsWithCI(newPortion, typedText) then
        local toType = newPortion:sub(#typedText + 1)
        if #toType > 0 then
            cancelPendingRevision("growth")
            bdHandleLog("  -> path: growth, smartType len=" .. #toType)
            smartType(toType)
            typedText = newPortion
        else
            bdHandleLog("  -> path: growth but no new chars")
        end
    else
        local keep = commonPrefixLen(typedText, newPortion)
        local deleteCount = #typedText - keep
        local toType = newPortion:sub(keep + 1)

        -- Detect SFSpeech recognizer rotation masquerading as a "revision":
        -- post-rotation the new partial is dramatically shorter than what
        -- we typed and shares almost no prefix. task.finish() doesn't
        -- always emit isFinal=true, so segmentClosed never trips. Without
        -- this guard we'd backspace the user's whole thought (delete=60+,
        -- type=2) on every 50s rotation.
        local isRotation = (keep < 5)
            and (deleteCount > 10)
            and (#newPortion < math.max(20, #typedText // 2))
        if isRotation then
            cancelPendingRevision("rotation")
            bdHandleLog(string.format(
                "  -> path: rotation detected (keep=%d delete=%d new.len=%d typed.len=%d), typeFreshPartial",
                keep, deleteCount, #newPortion, #typedText))
            typeFreshPartial(partial)
            segmentClosed = (eventType == "final")
            return
        end

        bdHandleLog("  -> path: revision candidate, keep=" .. keep .. " delete=" .. deleteCount .. " type.len=" .. #toType)
        scheduleRevision(partial, eventType, newPortion)
    end
    segmentClosed = (eventType == "final")
end

local function pollStreamEvents()
    local f = io.open(STREAM_PATH, "r")
    if not f then return end

    local size = f:seek("end") or 0
    if streamFilePos > size then
        bdHandleLog("stream cursor past EOF; resetting to current EOF")
        streamFilePos = size
    elseif streamFilePos < 0 then
        streamFilePos = 0
    end

    f:seek("set", streamFilePos)
    local chunk = f:read("*a") or ""
    f:close()
    if #chunk == 0 then return end

    -- Only advance past newline-terminated records. io.lines() can observe a
    -- half-written JSON object at EOF, fail to decode it, then move the cursor
    -- past it forever. That is deadly for live partials during a hotkey hold.
    local consumed = 0
    for line, nextIndex in chunk:gmatch("([^\n]*)\n()") do
        consumed = nextIndex - 1
        if line and #line > 0 then
            local ok, evt = pcall(hs.json.decode, line)
            if ok and evt and type(evt.type) == "string" then
                if evt.type == "partial" or evt.type == "final" then
                    handlePartial(evt.text or "", evt.type)
                end
            elseif not ok then
                bdHandleLog("stream json decode failed; skipping complete bad line")
            end
        end
    end
    if consumed > 0 then
        streamFilePos = streamFilePos + consumed
    end
end

-- Start the polling timer (idempotent). Polling runs all the time so we
-- always have a fresh lastPartial — the hotkey just flips isTyping.
local function streamPollerRunning()
    if not streamPoller then return false end
    local ok, running = pcall(function() return streamPoller:running() end)
    return (not ok) or running == true
end

local function ensurePolling(resetToEnd)
    if resetToEnd or streamFilePos == 0 then
        streamFilePos = completeRecordSize(STREAM_PATH)
    end
    if streamPollerRunning() then return end
    if streamPoller then streamPoller:stop() end
    streamPoller = hs.timer.doEvery(0.03, pollStreamEvents)
    bdHandleLog("stream poller started pos=" .. tostring(streamFilePos))
end

local function beginTyping()
    if pendingEndTimer and isTyping then
        pendingEndTimer:stop()
        pendingEndTimer = nil
        bdHandleLog("end grace canceled reason=resume typing")
        pressedAt = hs.timer.secondsSinceEpoch() - HOLD_THRESHOLD - 0.01
        state = "rec_hold"
        return
    end
    if finishPendingEnd then finishPendingEnd("begin typing") end
    ensurePolling(true)
    cancelPendingRevision("begin typing")
    bridgeSpaceAtSessionStart = focusedTextNeedsBridgeSpace()
    priorSessionEndedWithContent = false
    baselinePartial = ""
    typedText = ""
    sessionTypedAny = false   -- reset so the first letter gets capitalized
    segmentClosed = false
    targetApp = hs.application.frontmostApplication()
    isTyping = true
    hs.timer.doAfter(0.02, pollStreamEvents)
end

local function endTyping()
    flushPendingRevision("end typing", true)
    isTyping = false
    -- Capture what we typed so the glossary pass can compute a diff
    -- before we clear state.
    local original = typedText
    local app = targetApp
    typedText = ""
    baselinePartial = ""
    segmentClosed = false
    targetApp = nil
    bridgeSpaceAtSessionStart = false

    -- Remember whether this session left non-space content on screen so
    -- the next session can prepend a space when it starts typing.
    if #original > 0 and not original:match("%s$") then
        priorSessionEndedWithContent = true
    end

    if #original >= 3 then
        local corrected = applyGlossaryCorrections(original)
        if corrected ~= original then
            targetApp = app
            bdHandleLog("glossary correction len=" .. #original .. " -> " .. #corrected)
            applyCorrection(original, corrected)
            targetApp = nil
        end
    end
end

finishPendingEnd = function(reason)
    if pendingEndTimer then
        pendingEndTimer:stop()
        pendingEndTimer = nil
        bdHandleLog("end grace flushed reason=" .. tostring(reason))
    end
    if isTyping then endTyping() end
end

local function scheduleEndTyping(reason)
    if pendingEndTimer then pendingEndTimer:stop() end
    bdHandleLog("end grace scheduled reason=" .. tostring(reason) .. " sec=" .. tostring(END_GRACE_SEC))
    pendingEndTimer = hs.timer.doAfter(END_GRACE_SEC, function()
        pendingEndTimer = nil
        bdHandleLog("end grace fired")
        if isTyping then endTyping() end
    end)
end

local function bdLog(msg)
    local f = io.open(os.getenv("HOME") .. "/.bloom-dictate/hs-bd.log", "a")
    if f then
        f:write(os.date("%H:%M:%S") .. " " .. msg .. "\n")
        f:close()
    end
end

-- Only physical Right-⌘ owns dictation. Left-⌘ must remain a normal command
-- key and should not chime or toggle recording.
local function isCmdHotkey(kc) return kc == KEY_RIGHT_CMD end

bdTap = hs.eventtap.new({hs.eventtap.event.types.flagsChanged}, function(event)
    local kc = event:getKeyCode()
    bdLog("flagsChanged kc=" .. tostring(kc))
    if not isCmdHotkey(kc) then return false end

    local flags = event:getFlags()
    local isDown = flags and flags.cmd == true
    if isDown == rcmdDown then
        bdLog("cmd-hotkey duplicate state ignored down=" .. tostring(isDown))
        return false
    end
    rcmdDown = isDown
    local t = hs.timer.secondsSinceEpoch()
    bdLog("right-cmd " .. (rcmdDown and "DOWN" or "UP") .. " state=" .. state)

    if rcmdDown then
        -- PRESS
        if state == "idle" then
            pressedAt = t
            state = "rec_hold"
            beginTyping()
            playChime("start")
            bdSetMenubar(true)
        elseif state == "tap_pending" then
            cancelPending()
            state = "rec_locked"
            playChime("lock")
            hs.alert.show("🎙 locked · tap Right-⌘ to stop", 1.5)
        elseif state == "rec_locked" then
            state = "idle"
            scheduleEndTyping("locked stop")
            playChime("stop")
            bdSetMenubar(false)
        end
    else
        -- RELEASE
        if state == "rec_hold" then
            local heldFor = t - pressedAt
            if heldFor < HOLD_THRESHOLD then
                state = "tap_pending"
                pendingStopTimer = hs.timer.doAfter(DOUBLE_TAP_WINDOW, function()
                    if state == "tap_pending" then
                        state = "idle"
                        endTyping()
                        playChime("stop")
                        bdSetMenubar(false)
                    end
                    pendingStopTimer = nil
                end)
            else
                state = "idle"
                scheduleEndTyping("hold release")
                playChime("stop")
                bdSetMenubar(false)
            end
        end
    end

    return false
end)
bdTap:start()

hs.hotkey.bind({"ctrl", "alt", "cmd"}, "escape", function()
    cancelPending()
    state = "idle"
    finishPendingEnd("cancel")
    playChime("cancel")
    bdSetMenubar(false)
end)

-- Kick off the BloomDictate.app streamer + the polling loop on Hammerspoon load.
ensureStreamerRunning()
hs.timer.doAfter(1.0, ensurePolling)

-- Health-check the streamer every 5 seconds. The Swift app has occasionally
-- exited unexpectedly during dev iteration; this auto-relaunches it so
-- the user does not have to think about it.
bdHealthTimer = hs.timer.doEvery(5.0, function()
    ensureStreamerRunning()
    ensurePolling(false)
end)

-- Quiet load — no startup alert. Menubar 🌱 / 🎙 is the visible state.
