-- Mist (SFSpeech hybrid, powered by Bloom)
--
-- Mist.app runs in --streamer mode (always-on SFSpeech recognition,
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
local DOUBLE_TAP_WINDOW  = 0.55
local REVISION_DEBOUNCE_SEC = 0.20
local END_GRACE_SEC      = 3.50
local IDLE_POLL_INTERVAL = 0.05
local ACTIVE_POLL_INTERVAL = 0.02
local AUTO_PERIOD_ENABLED = true
local AUTO_PERIOD_MIN_WORDS = 7
local CHIMES_ENABLED     = true
local CHIME_VOLUME       = 0.32
local CHIME_SOUNDS       = {
    start = "Pop",
    stop = "Bottle",
    lock = "Purr",
    cancel = "Submarine",
}

local state             = "idle"
local rcmdDown          = false
local pressedAt         = 0
local typingStartedAt   = 0
local typingStateChangedAt = hs.timer.secondsSinceEpoch()
local pendingStopTimer  = nil
local pendingRevisionTimer = nil
local pendingRevision   = nil
local pendingEndTimer    = nil
local finishPendingEnd   = nil

-- SFSpeech streamer state
local STREAM_PATH       = os.getenv("HOME") .. "/.bloom-dictate/dictate-stream.jsonl"
local streamPoller      = nil
local activePoller      = nil
local streamFilePos     = 0
local lastPollErrorAt   = 0
local lastPartial       = ""       -- most recent partial we've SEEN from SFSpeech
local isTyping          = false    -- true while hotkey is held / locked
local baselinePartial   = ""       -- partial text at the moment recording started
local typedText         = ""       -- chars we've actually keystroked this session
local sessionTypedAny   = false    -- have we typed any non-space char this session?
local segmentClosed     = false    -- final event seen; next partial is a fresh utterance
local targetApp         = nil      -- app that owned focus when dictation began
local priorSessionEndedWithContent = false   -- previous dictation ended with non-space content; new session should prepend a space
local bridgeSpaceAtSessionStart = false
local startMistAnimation = function() end
local stopMistAnimation = function() end
local mistTextPing = function() end
local mistCorrectionPing = function() end

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
    mistTextPing()
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

    local okValue, value = pcall(function()
        return elem:attributeValue("AXValue")
    end)
    if not okValue then return false end
    if type(value) ~= "string" or #value == 0 then return false end

    local okRange, range = pcall(function()
        return elem:attributeValue("AXSelectedTextRange")
    end)
    if not okRange then range = nil end
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

-- Mist glossary: instant local find-replace pass that fires on release.
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
    { "bloom dictate", "Mist" },
    { "mist dictate", "Mist" },
    { "hot key",    "hotkey" },
    { "hockey key", "hotkey" },
    { "right command", "Right Command" },
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
    local didSpark = false
    if bsCount > 0 then
        mistCorrectionPing()
        didSpark = true
        backspace(bsCount)
    end
    local toType = corrected:sub(divergeAt + 1)
    if #toType > 0 then
        if not didSpark then mistCorrectionPing() end
        postUnicode(toType)
    end
end

local function capitalizeLeadingLetter(text)
    local prefix, letter, rest = (text or ""):match("^(%s*)(%a)(.*)$")
    if letter then
        return prefix .. letter:upper() .. rest
    end
    return text
end

local function typeFreshPartial(partial)
    local currentSegment = (baselinePartial or "") .. (typedText or "")
    local lastWord = currentSegment:match("([%a']+)%s*$")
    local endsIncomplete = lastWord and ({
        ["and"] = true, ["or"] = true, ["but"] = true, ["the"] = true,
        ["to"] = true, ["of"] = true, ["in"] = true, ["with"] = true,
    })[lastWord:lower()]
    if AUTO_PERIOD_ENABLED
       and #currentSegment >= 24
       and not currentSegment:gsub("%s+$", ""):match("[%.%!%?][\"'%)%]]*$")
       and not endsIncomplete then
        local _, words = currentSegment:gsub("%S+", "")
        if words >= AUTO_PERIOD_MIN_WORDS then
            postUnicode(".")
            typedText = typedText .. "."
            currentSegment = currentSegment .. "."
        end
    end

    if sessionTypedAny and #currentSegment > 0 and not currentSegment:match("%s$") and partial:match("^%w") then
        smartType(" ")
    end
    if currentSegment:gsub("%s+$", ""):match("[%.%!%?][\"'%)%]]*$") then
        partial = capitalizeLeadingLetter(partial)
    end
    smartType(partial)
    baselinePartial = partial
    typedText = ""
end

-- Auto-launch Mist.app --streamer if it's not running. BloomDictate.app is
-- supported as a compatibility fallback for early local builds.
local function ensureStreamerRunning()
    local out, ok = hs.execute("pgrep -f '(Mist|BloomDictate).*--streamer' >/dev/null && echo yes || echo no")
    if (out or ""):find("yes") then return end
    local appPath = os.getenv("HOME") .. "/Applications/Mist.app"
    local f = io.open(appPath .. "/Contents/Info.plist", "r")
    if f then
        f:close()
    else
        appPath = os.getenv("HOME") .. "/Applications/BloomDictate.app"
    end
    hs.task.new("/usr/bin/open", nil,
        { appPath, "--args", "--streamer" }
    ):start()
end

-- Menubar indicator: flips between 🎙 (recording) and 🌱 (idle) so the
-- current state is visible at a glance.
local bdMenubar = hs.menubar.new()
local function bdSetMenubar(recording)
    if not bdMenubar then return end
    local ok, inMenu = pcall(function() return bdMenubar:isInMenuBar() end)
    if ok and not inMenu then
        pcall(function() bdMenubar:returnToMenuBar() end)
    end
    if recording then
        bdMenubar:setTitle("🎙")
        bdMenubar:setTooltip("Mist · recording")
    else
        bdMenubar:setTitle("🌱")
        bdMenubar:setTooltip("Mist · hold Right-⌘ or double-tap to lock")
    end
end
bdSetMenubar(false)

local function syncMenubar()
    bdSetMenubar(isTyping == true)
end

local function playChime(kind)
    if not CHIMES_ENABLED then return end
    local soundName = CHIME_SOUNDS[kind]
    if not soundName then return end
    local sound = hs.sound.getByName(soundName)
    if sound then
        pcall(function() sound:volume(CHIME_VOLUME) end)
        sound:play()
    end
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

-- Text-field mist sparkles: quick, click-through bursts anchored to the
-- focused caret when text lands or gets corrected.
local MIST_ANIMATION_ENABLED = true
local MIST_W = 142
local MIST_H = 64
local MIST_COLOR = { red = 93/255, green = 214/255, blue = 255/255 }
local MIST_LILAC = { red = 174/255, green = 143/255, blue = 255/255 }
local MIST_MINT = { red = 116/255, green = 255/255, blue = 214/255 }
local MIST_WHITE = { red = 1, green = 1, blue = 1 }
local MIST_SPARKLES = {
    { x = 30, y = 33, dx = -13, dy = -13, size = 5.8, delay = 0.00, alpha = 0.80 },
    { x = 44, y = 24, dx = -5,  dy = -18, size = 4.2, delay = 0.03, alpha = 0.72 },
    { x = 54, y = 38, dx = 5,   dy = -16, size = 7.0, delay = 0.01, alpha = 0.68 },
    { x = 69, y = 28, dx = 16,  dy = -13, size = 4.8, delay = 0.06, alpha = 0.76 },
    { x = 81, y = 41, dx = 23,  dy = -9,  size = 6.2, delay = 0.08, alpha = 0.62 },
    { x = 91, y = 25, dx = 28,  dy = -18, size = 3.8, delay = 0.12, alpha = 0.66 },
    { x = 35, y = 43, dx = -16, dy = 3,   size = 3.6, delay = 0.10, alpha = 0.56 },
    { x = 62, y = 20, dx = 3,   dy = -24, size = 3.2, delay = 0.14, alpha = 0.62 },
    { x = 74, y = 34, dx = 12,  dy = 3,   size = 3.5, delay = 0.16, alpha = 0.50 },
    { x = 101, y = 35, dx = 25, dy = -2,  size = 3.0, delay = 0.18, alpha = 0.46 },
}
local mistCanvas = nil
local mistTimer = nil
local mistBirth = 0
local mistMode = "text"
local mistSeeds = {}
local mistAnchorFrame = nil

local function rectFromAX(value)
    if type(value) ~= "table" then return nil end
    local x = value.x or value.X or value[1]
    local y = value.y or value.Y or value[2]
    local w = value.w or value.width or value.W or value[3]
    local h = value.h or value.height or value.H or value[4]
    if type(x) == "number" and type(y) == "number" then
        local ww = tonumber(w) or 2
        local hh = tonumber(h) or 18
        if hh <= 0 then return nil end
        if ww <= 0 then ww = 2 end
        return { x = x, y = y, w = ww, h = hh }
    end
    return nil
end

local function focusedAXElement()
    if hs.axuielement then
        local apps = {}
        if targetApp then apps[#apps + 1] = targetApp end
        local front = hs.application.frontmostApplication()
        if front and front ~= targetApp then apps[#apps + 1] = front end

        for _, app in ipairs(apps) do
            local okApp, appElem = pcall(function()
                return hs.axuielement.applicationElement(app)
            end)
            if okApp and appElem then
                local okFocused, focused = pcall(function()
                    return appElem:attributeValue("AXFocusedUIElement")
                end)
                if okFocused and focused then return focused end
            end
        end

        local okSystem, system = pcall(hs.axuielement.systemWideElement)
        if okSystem and system then
            local okFocused, focused = pcall(function()
                return system:attributeValue("AXFocusedUIElement")
            end)
            if okFocused and focused then return focused end
        end
    end

    local okElem, elem = pcall(hs.uielement.focusedElement)
    if okElem and elem then return elem end
    return nil
end

local function focusedCaretFrame()
    local elem = focusedAXElement()
    if not elem then return nil end
    if type(elem.attributeValue) ~= "function" then return nil end

    local okRange, range = pcall(function()
        return elem:attributeValue("AXSelectedTextRange")
    end)
    if okRange and type(range) == "table" then
        local location = range.location or range.loc
        if type(location) == "number" then
            local okBounds, bounds = pcall(function()
                return elem:parameterizedAttributeValue("AXBoundsForRange", {
                    location = location,
                    length = math.max(1, tonumber(range.length or range.len) or 1),
                })
            end)
            local rect = okBounds and rectFromAX(bounds) or nil
            if rect then return rect end
        end
    end

    local okFrame, frame = pcall(function()
        return elem:attributeValue("AXFrame")
    end)
    local rect = okFrame and rectFromAX(frame) or nil
    if rect and rect.w >= 8 and rect.h >= 8 then
        return {
            x = rect.x + math.min(math.max(rect.w - 36, 18), math.max(18, rect.w - 18)),
            y = rect.y + math.min(math.max(rect.h - 26, 10), math.max(10, rect.h - 10)),
            w = 2,
            h = math.min(rect.h, 24),
        }
    end
    return nil
end

local function captureMistAnchor()
    local caret = focusedCaretFrame()
    if caret then
        mistAnchorFrame = caret
        return true
    end
    return mistAnchorFrame ~= nil
end

local function positionMistCanvas()
    if not mistCanvas then return false end
    local screen = hs.screen.mainScreen()
    if not screen then return false end
    local sf = screen:frame()
    local caret = focusedCaretFrame()
    if caret then
        mistAnchorFrame = caret
    else
        caret = mistAnchorFrame
    end
    if not caret then return false end

    local x = caret.x - 32
    local y = caret.y + (caret.h / 2) - (MIST_H / 2)
    x = math.max(sf.x + 8, math.min(x, sf.x + sf.w - MIST_W - 8))
    y = math.max(sf.y + 8, math.min(y, sf.y + sf.h - MIST_H - 8))
    mistCanvas:frame({ x = x, y = y, w = MIST_W, h = MIST_H })
    return true
end

local function mistColorWithAlpha(color, alpha)
    return { red = color.red, green = color.green, blue = color.blue, alpha = alpha }
end

local function mistSparkleColor(mode, index)
    local textPalette = { MIST_COLOR, MIST_MINT, MIST_WHITE, MIST_LILAC }
    local correctionPalette = { MIST_LILAC, MIST_WHITE, MIST_MINT, MIST_COLOR }
    local palette = (mode == "correction") and correctionPalette or textPalette
    return palette[((index - 1) % #palette) + 1]
end

local function ensureMistCanvas()
    if mistCanvas then return end
    mistCanvas = hs.canvas.new({ x = 0, y = 0, w = MIST_W, h = MIST_H })
    mistCanvas:level(hs.canvas.windowLevels.overlay)
    mistCanvas:behavior({ "canJoinAllSpaces", "stationary" })
    pcall(function() mistCanvas:clickActivating(false) end)
    local elements = {}
    for _ = 1, #MIST_SPARKLES do
        elements[#elements + 1] = {
            type = "circle",
            action = "fill",
            frame = { x = 0, y = 0, w = 1, h = 1 },
            fillColor = { red = 1, green = 1, blue = 1, alpha = 0 },
        }
    end
    mistCanvas:appendElements(elements)
    positionMistCanvas()
end

local function stopMistBurst()
    if mistTimer then
        mistTimer:stop()
        mistTimer = nil
    end
    if mistCanvas then mistCanvas:hide() end
    mistSeeds = {}
end

local function buildMistSeeds(mode)
    mistSeeds = {}
    local correctionBoost = (mode == "correction") and 1.25 or 1.0
    for i, pattern in ipairs(MIST_SPARKLES) do
        mistSeeds[i] = {
            x = pattern.x,
            y = pattern.y,
            dx = pattern.dx * correctionBoost,
            dy = pattern.dy * correctionBoost,
            size = pattern.size * correctionBoost,
            delay = pattern.delay,
            alpha = math.min(0.9, pattern.alpha * correctionBoost),
            color = mistSparkleColor(mode, i),
        }
    end
end

local function renderMistFrame()
    if not mistCanvas then return end
    if not positionMistCanvas() then
        stopMistBurst()
        return
    end
    local elapsed = hs.timer.secondsSinceEpoch() - mistBirth
    local duration = (mistMode == "correction") and 0.72 or 0.58

    for i, seed in ipairs(mistSeeds) do
        local localT = (elapsed - seed.delay) / math.max(0.01, duration - seed.delay)
        if localT <= 0 then
            mistCanvas[i].frame = { x = seed.x, y = seed.y, w = 1, h = 1 }
            mistCanvas[i].fillColor = mistColorWithAlpha(seed.color, 0)
        else
            localT = math.min(1, localT)
            local ease = 1 - ((1 - localT) ^ 3)
            local pop = math.sin(localT * math.pi)
            local size = seed.size * (0.55 + (pop * 0.95))
            local x = seed.x + (seed.dx * ease) - (size / 2)
            local y = seed.y + (seed.dy * ease) - (size / 2)
            local alpha = seed.alpha * (1 - localT) * (0.35 + (pop * 0.65))
            mistCanvas[i].frame = { x = x, y = y, w = size, h = size }
            mistCanvas[i].fillColor = mistColorWithAlpha(seed.color, alpha)
        end
    end

    if elapsed >= duration then
        stopMistBurst()
    end
end

local function sparkleMist(mode)
    if not MIST_ANIMATION_ENABLED then return end
    if not captureMistAnchor() then
        bdHandleLog("mist sparkle skipped: no text-field anchor")
        return
    end
    ensureMistCanvas()
    if not mistCanvas then return end
    mistMode = mode or "text"
    mistBirth = hs.timer.secondsSinceEpoch()
    buildMistSeeds(mistMode)
    if not positionMistCanvas() then return end
    mistCanvas:show()
    if mistTimer then mistTimer:stop() end
    mistTimer = hs.timer.doEvery(0.025, renderMistFrame)
    renderMistFrame()
end

startMistAnimation = function(reason)
    if reason == "preview" then sparkleMist("text") end
end

stopMistAnimation = function()
    stopMistBurst()
end

mistTextPing = function()
    if not isTyping or not MIST_ANIMATION_ENABLED then return end
    sparkleMist("text")
end

mistCorrectionPing = function()
    if not MIST_ANIMATION_ENABLED then return end
    sparkleMist("correction")
end

local function currentSegmentText()
    return (baselinePartial or "") .. (typedText or "")
end

local function countWords(text)
    local _, count = (text or ""):gsub("%S+", "")
    return count
end

local function endsWithTerminalPunctuation(text)
    local trimmed = (text or ""):gsub("%s+$", "")
    return trimmed:match("[%.%!%?][\"'%)%]]*$") ~= nil
end

local INCOMPLETE_FINAL_WORDS = {
    ["a"] = true, ["an"] = true, ["and"] = true, ["as"] = true,
    ["at"] = true, ["but"] = true, ["for"] = true, ["from"] = true,
    ["if"] = true, ["in"] = true, ["into"] = true, ["of"] = true,
    ["on"] = true, ["or"] = true, ["so"] = true, ["that"] = true,
    ["the"] = true, ["then"] = true, ["to"] = true, ["with"] = true,
}

local function likelyIncompleteEnding(text)
    local word = (text or ""):match("([%a']+)[%s%)]*$")
    return word ~= nil and INCOMPLETE_FINAL_WORDS[word:lower()] == true
end

local function maybeAppendTerminalPeriod(reason)
    if not AUTO_PERIOD_ENABLED then return false end
    local text = currentSegmentText()
    if #text < 24 or countWords(text) < AUTO_PERIOD_MIN_WORDS then return false end
    if endsWithTerminalPunctuation(text) or likelyIncompleteEnding(text) then return false end

    postUnicode(".")
    typedText = typedText .. "."
    bdHandleLog("auto period reason=" .. tostring(reason) .. " segment.len=" .. tostring(#text))
    return true
end

local function markSegmentState(eventType, reason)
    if eventType == "final" then
        maybeAppendTerminalPeriod(reason)
        segmentClosed = true
    else
        segmentClosed = false
    end
end

local function restoreDroppedLeadWord(rendered, partial)
    local lead, rest = (rendered or ""):match("^(%S+)%s+(.+)$")
    if not lead or #lead > 3 or not partial or #partial < 8 then
        return partial, false
    end

    local compareLen = math.min(#partial, #rest)
    if compareLen >= 8 and rest:sub(1, compareLen):lower() == partial:sub(1, compareLen):lower() then
        local restoredTail = rest:sub(1, 1) .. partial:sub(2)
        return lead .. " " .. restoredTail, true
    end
    return partial, false
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
        if data.mode == "full" and baselinePartial ~= data.baselineAtSchedule then
            bdHandleLog("  -> path: full revision skipped; baseline changed")
            return false
        end
    end

    if data.mode == "full" then
        local renderedSegment = currentSegmentText()
        local targetPartial = data.partial
        if commonPrefixLen(renderedSegment, targetPartial) < 5 then
            local restored, didRestore = restoreDroppedLeadWord(renderedSegment, targetPartial)
            if didRestore then
                targetPartial = restored
                bdHandleLog("  -> path: full revision restored dropped lead word")
            end
        end

        local keep = commonPrefixLen(renderedSegment, targetPartial)
        local deleteCount = #renderedSegment - keep
        local toType = targetPartial:sub(keep + 1)
        bdHandleLog("  -> path: full revision apply, keep=" .. keep .. " delete=" .. deleteCount .. " type.len=" .. #toType)
        if deleteCount > 0 then
            mistCorrectionPing()
            backspace(deleteCount)
        end
        if #toType > 0 then
            smartType(toType)
        end
        baselinePartial = targetPartial
        typedText = ""
        markSegmentState(data.eventType, "full revision")
        return true
    end

    local newPortion = data.newPortion
    local keep = commonPrefixLen(typedText, newPortion)
    local deleteCount = #typedText - keep
    local toType = newPortion:sub(keep + 1)
    bdHandleLog("  -> path: revision apply, keep=" .. keep .. " delete=" .. deleteCount .. " type.len=" .. #toType)
    if deleteCount > 0 then
        mistCorrectionPing()
        backspace(deleteCount)
    end
    if #toType > 0 then
        smartType(toType)
    end
    typedText = newPortion
    markSegmentState(data.eventType, "tail revision")
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
        mode = "tail",
        partial = partial,
        eventType = eventType,
        newPortion = newPortion,
        typedAtSchedule = typedText,
        baselineAtSchedule = baselinePartial,
    }
    pendingRevisionTimer = hs.timer.doAfter(REVISION_DEBOUNCE_SEC, function()
        pendingRevisionTimer = nil
        local data = pendingRevision
        pendingRevision = nil
        applyRevision(data, false)
    end)
    bdHandleLog("  -> path: revision scheduled debounce=" .. tostring(REVISION_DEBOUNCE_SEC))
end

local function scheduleFullRevision(partial, eventType)
    cancelPendingRevision("superseded")
    pendingRevision = {
        mode = "full",
        partial = partial,
        eventType = eventType,
        typedAtSchedule = typedText,
        baselineAtSchedule = baselinePartial,
    }
    pendingRevisionTimer = hs.timer.doAfter(REVISION_DEBOUNCE_SEC, function()
        pendingRevisionTimer = nil
        local data = pendingRevision
        pendingRevision = nil
        applyRevision(data, false)
    end)
    bdHandleLog("  -> path: full revision scheduled debounce=" .. tostring(REVISION_DEBOUNCE_SEC))
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
            markSegmentState(eventType, "empty final")
        end
        return
    end

    if segmentClosed then
        cancelPendingRevision("segment closed")
        bdHandleLog("  -> path: segmentClosed branch, typeFreshPartial")
        segmentClosed = false
        typeFreshPartial(partial)
        markSegmentState(eventType, "fresh final")
        return
    end

    if partial:sub(1, #baselinePartial) ~= baselinePartial then
        local renderedSegment = currentSegmentText()
        local keep = commonPrefixLen(renderedSegment, partial)
        local shortReset = (#renderedSegment > 10)
            and (keep < 5)
            and (#partial < math.max(20, #renderedSegment // 2))

        local _, restoresLeadWord = restoreDroppedLeadWord(renderedSegment, partial)
        if #renderedSegment > 0 and not shortReset and (keep >= 5 or restoresLeadWord) then
            bdHandleLog(string.format(
                "  -> path: full revision candidate, keep=%d rendered.len=%d partial.len=%d",
                keep, #renderedSegment, #partial))
            scheduleFullRevision(partial, eventType)
            if eventType ~= "final" then segmentClosed = false end
            return
        end

        cancelPendingRevision("divergent partial")
        bdHandleLog("  -> path: divergent reset, typeFreshPartial")
        typeFreshPartial(partial)
        markSegmentState(eventType, "divergent reset")
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
            markSegmentState(eventType, "rotation reset")
            return
        end

        bdHandleLog("  -> path: revision candidate, keep=" .. keep .. " delete=" .. deleteCount .. " type.len=" .. #toType)
        scheduleRevision(partial, eventType, newPortion)
    end
    markSegmentState(eventType, "handle final")
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
    local records = 0
    for line, nextIndex in chunk:gmatch("([^\n]*)\n()") do
        consumed = nextIndex - 1
        if line and #line > 0 then
            local ok, evt = pcall(hs.json.decode, line)
            if ok and evt and type(evt.type) == "string" then
                records = records + 1
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
        if isTyping then
            bdHandleLog("stream consumed records=" .. tostring(records) .. " bytes=" .. tostring(consumed) .. " pos=" .. tostring(streamFilePos))
        end
    end
end

local function safePollStreamEvents(source)
    local ok, err = pcall(pollStreamEvents)
    if ok then return true end

    local now = hs.timer.secondsSinceEpoch()
    if now - lastPollErrorAt >= 1.0 then
        lastPollErrorAt = now
        bdHandleLog("stream poll error source=" .. tostring(source) .. " err=" .. tostring(err))
    end
    return false
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
    streamPoller = hs.timer.doEvery(IDLE_POLL_INTERVAL, function()
        safePollStreamEvents("idle")
    end)
    bdHandleLog("stream poller started pos=" .. tostring(streamFilePos))
end

local function activePollerRunning()
    if not activePoller then return false end
    local ok, running = pcall(function() return activePoller:running() end)
    return (not ok) or running == true
end

local function startActivePoller(reason)
    if activePollerRunning() then return end
    if activePoller then activePoller:stop() end
    activePoller = hs.timer.doEvery(ACTIVE_POLL_INTERVAL, function()
        safePollStreamEvents("active")
    end)
    bdHandleLog("active poller started reason=" .. tostring(reason))
    safePollStreamEvents("active-start")
end

local function stopActivePoller(reason)
    if activePoller then
        activePoller:stop()
        activePoller = nil
        bdHandleLog("active poller stopped reason=" .. tostring(reason))
    end
end

local function resetDictateState(reason)
    cancelPending()
    cancelPendingRevision("reset")
    if pendingEndTimer then
        pendingEndTimer:stop()
        pendingEndTimer = nil
    end
    rcmdDown = false
    state = "idle"
    isTyping = false
    baselinePartial = ""
    typedText = ""
    sessionTypedAny = false
    segmentClosed = false
    targetApp = nil
    mistAnchorFrame = nil
    bridgeSpaceAtSessionStart = false
    typingStartedAt = 0
    typingStateChangedAt = hs.timer.secondsSinceEpoch()
    stopMistAnimation()
    stopActivePoller("reset")
    syncMenubar()
    bdHandleLog("state reset reason=" .. tostring(reason))
    return "reset ok: " .. tostring(reason or "manual")
end

local function beginTyping()
    if pendingEndTimer and isTyping then
        pendingEndTimer:stop()
        pendingEndTimer = nil
        bdHandleLog("end grace canceled reason=resume typing")
        pressedAt = hs.timer.secondsSinceEpoch() - HOLD_THRESHOLD - 0.01
        state = "rec_hold"
        typingStateChangedAt = hs.timer.secondsSinceEpoch()
        startMistAnimation("resume")
        startActivePoller("resume")
        syncMenubar()
        return
    end
    if finishPendingEnd then finishPendingEnd("begin typing") end
    ensureStreamerRunning()
    ensurePolling(true)
    cancelPendingRevision("begin typing")
    targetApp = hs.application.frontmostApplication()
    captureMistAnchor()
    bridgeSpaceAtSessionStart = focusedTextNeedsBridgeSpace()
    priorSessionEndedWithContent = false
    baselinePartial = ""
    typedText = ""
    sessionTypedAny = false   -- reset so the first letter gets capitalized
    segmentClosed = false
    isTyping = true
    typingStartedAt = hs.timer.secondsSinceEpoch()
    typingStateChangedAt = typingStartedAt
    bdHandleLog("begin typing pos=" .. tostring(streamFilePos))
    syncMenubar()
    startMistAnimation("begin")
    startActivePoller("begin")
    hs.timer.doAfter(0.02, function()
        safePollStreamEvents("begin-delay")
    end)
end

local function endTyping()
    flushPendingRevision("end typing", true)
    maybeAppendTerminalPeriod("end typing")
    isTyping = false
    stopActivePoller("end typing")
    -- Capture what we typed so the glossary pass can compute a diff
    -- before we clear state.
    local original = currentSegmentText()
    local app = targetApp
    targetApp = app
    typedText = ""
    baselinePartial = ""
    segmentClosed = false
    bridgeSpaceAtSessionStart = false
    typingStartedAt = 0
    typingStateChangedAt = hs.timer.secondsSinceEpoch()

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
        end
    end
    targetApp = nil
    mistAnchorFrame = nil
    syncMenubar()
end

_G.bdDebugState = function()
    local idleRunning = streamPollerRunning()
    local activeRunning = activePollerRunning()
    local now = hs.timer.secondsSinceEpoch()
    local typingAge = typingStartedAt > 0 and (now - typingStartedAt) or 0
    local stateAge = now - typingStateChangedAt
    local title = "nil"
    local inMenu = "nil"
    if bdMenubar then
        local okTitle, gotTitle = pcall(function() return bdMenubar:title() end)
        if okTitle then title = tostring(gotTitle) end
        local okMenu, gotMenu = pcall(function() return bdMenubar:isInMenuBar() end)
        if okMenu then inMenu = tostring(gotMenu) end
    end
    return string.format(
        "state=%s isTyping=%s rcmdDown=%s typingAge=%.1f stateAge=%.1f pendingEnd=%s pos=%s idlePoller=%s activePoller=%s menubarInMenu=%s menubarTitle=%s",
        tostring(state), tostring(isTyping), tostring(rcmdDown), typingAge, stateAge,
        tostring(pendingEndTimer ~= nil), tostring(streamFilePos),
        tostring(idleRunning), tostring(activeRunning), inMenu, title
    )
end

_G.bdForceStreamPoll = function()
    return safePollStreamEvents("manual")
end

_G.bdResetDictate = function(reason)
    return resetDictateState(reason or "manual")
end

_G.bdPreviewMist = function()
    targetApp = hs.application.frontmostApplication()
    mistAnchorFrame = nil
    if not captureMistAnchor() then
        targetApp = nil
        return "no focused text-field anchor for sparkles"
    end
    startMistAnimation("preview")
    hs.timer.doAfter(0.18, mistCorrectionPing)
    hs.timer.doAfter(0.38, function() startMistAnimation("preview") end)
    hs.timer.doAfter(1.2, function()
        stopMistAnimation()
        targetApp = nil
        mistAnchorFrame = nil
    end)
    return "previewing text-field sparkles"
end

_G.bdMistAnchorDebug = function()
    targetApp = hs.application.frontmostApplication()
    local ok = captureMistAnchor()
    local a = mistAnchorFrame
    targetApp = nil
    if not ok or not a then return "no focused text-field anchor" end
    return string.format("anchor x=%.0f y=%.0f w=%.0f h=%.0f", a.x, a.y, a.w, a.h)
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
            typingStateChangedAt = t
            beginTyping()
            playChime("start")
            syncMenubar()
        elseif state == "tap_pending" then
            cancelPending()
            state = "rec_locked"
            typingStateChangedAt = t
            playChime("lock")
            hs.alert.show("🎙 locked · tap Right-⌘ to stop", 1.5)
            syncMenubar()
        elseif state == "rec_locked" then
            state = "idle"
            typingStateChangedAt = t
            scheduleEndTyping("locked stop")
            playChime("stop")
            syncMenubar()
        end
    else
        -- RELEASE
        if state == "rec_hold" then
            local heldFor = t - pressedAt
            if heldFor < HOLD_THRESHOLD then
                state = "tap_pending"
                typingStateChangedAt = t
                pendingStopTimer = hs.timer.doAfter(DOUBLE_TAP_WINDOW, function()
                    if state == "tap_pending" then
                        state = "idle"
                        typingStateChangedAt = hs.timer.secondsSinceEpoch()
                        endTyping()
                        playChime("stop")
                        syncMenubar()
                    end
                    pendingStopTimer = nil
                end)
            else
                state = "idle"
                typingStateChangedAt = t
                scheduleEndTyping("hold release")
                playChime("stop")
                syncMenubar()
            end
        end
    end

    return false
end)
bdTap:start()

hs.hotkey.bind({"ctrl", "alt", "cmd"}, "escape", function()
    resetDictateState("cancel")
    playChime("cancel")
end)

-- Kick off the Mist streamer + the polling loop on Hammerspoon load.
ensureStreamerRunning()
hs.timer.doAfter(1.0, ensurePolling)

-- Health-check the streamer every 5 seconds. The Swift app has occasionally
-- exited unexpectedly during dev iteration; this auto-relaunches it so
-- the user does not have to think about it.
bdHealthTimer = hs.timer.doEvery(5.0, function()
    ensureStreamerRunning()
    ensurePolling(false)
    local now = hs.timer.secondsSinceEpoch()
    if isTyping and state == "rec_hold" and not rcmdDown
       and pendingEndTimer == nil
       and (now - typingStateChangedAt) > (END_GRACE_SEC + 2.0) then
        resetDictateState("stale hold without keydown")
    elseif state == "tap_pending" and pendingStopTimer == nil
       and (now - typingStateChangedAt) > (DOUBLE_TAP_WINDOW + 1.0) then
        resetDictateState("stale tap pending")
    end
    syncMenubar()
end)

-- Quiet load — no startup alert. Menubar 🌱 / 🎙 is the visible state.
