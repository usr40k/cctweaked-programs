--[[
  Relay Hub - base station / pocket client for redstone relay control
  =====================================================================
  One file, two roles (auto-detected via the `pocket` global):
    - Base Station (runHost):  owns the authoritative relay list, drives
      redstone output, evaluates automations, and is the source of truth
      that every pocket client syncs from.
    - Pocket Client (runClient): a thin, always-reconnecting remote. It never
      edits its own relay list directly - every change is sent to the base
      as a command, and the base's "sync" reply is what updates the client.

  Networks: each base and its clients share a *named network*. The name is
  hashed to a modem channel, so several independent hubs can coexist
  without hearing each other. Press W to rename/switch networks.

  Press H at any time for the full shortcut list (the footer is kept short
  on purpose so it never runs off small screens).

  Forms (A / E / T / C / W) are mouse-and-keyboard GUIs: click a field or
  Tab/Up/Down to it, Enter/Space/click to edit, toggle or cycle it, and
  click [Save]/[Cancel] or press S/Esc. Each value sits under its label so
  it works on confined screens, and long text scrolls to follow the cursor.
]]

local CONFIG_FILE = "relays.json"             -- Base: relay list + shared settings
local CLIENT_STATE_FILE = "relay_client.json" -- Pocket: this client's uuid + prefs
local isPocket = (pocket ~= nil)

local GPS_STALE_AFTER = 10          -- seconds without a GPS fix before it's "stale"
local BASE_UNREACHABLE_AFTER = 12   -- seconds without a sync before warning
local MARQUEE_INTERVAL = 0.6        -- seconds between sideways-scroll steps

local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)

-- Shared runtime state
local relays = {}
local nextRelayId = 1
local selectedRelayId = nil
local scrollOffset = 0
local monitorScale = 0.5
local SCALES = { 0.5, 1.0, 1.5, 2.0 }
local lastPlayerPos = nil
local lastGPSFixTime = nil
local activePulses = {}      -- [timerId] = { id = relayId, targetState = bool }
local sensorState = {}       -- [relayId] = { lastInput, armedUntil } (not persisted)
local marqueePhase = 0

-- Network identity
local networkName = "default"
local knownNetworks = { "default" }
local currentChannel = nil

-- Display preferences
local uiStyle = "compact"       -- "compact" | "detailed" | "spacious"
local colorScheme = "default"   -- "default" | "dark" | "mono" | "highcontrast"
local overflowMode = "truncate" -- "truncate" | "scroll" | "wrap"
local textSize = 1.0            -- pocket terminal text scale

-- Host-only: settings remembered per client uuid
local baseClientSettings = {}
-- Host-only: paired YouCube theaters  [tid] = { name, secret }
local theaters = {}

-- Client-only: identity + connection tracking
local clientId = nil
local lastSyncTime = nil
local hasEverSynced = false

-- ===========================================================================
-- Color / Theme helpers
-- ===========================================================================

local function setColors(target, fg, bg)
    if target.isColor and target.isColor() then
        if fg then target.setTextColor(fg) end
        if bg then target.setBackgroundColor(bg) end
    end
end

local PALETTES = {
    default = {
        headerBg = colors.blue, headerFg = colors.white,
        bg = colors.black, fg = colors.white,
        selBg = colors.gray, selFg = colors.yellow,
        onBg = colors.green, offBg = colors.red,
        footerBg = colors.lightGray, footerFg = colors.black,
        scrollTrackBg = colors.lightGray, scrollTrackFg = colors.gray,
        scrollThumbBg = colors.cyan, scrollThumbFg = colors.white,
        accentFg = colors.cyan,
        fieldBg = colors.gray, fieldFg = colors.white,
        fieldFocusBg = colors.cyan, fieldFocusFg = colors.black,
    },
    dark = {
        headerBg = colors.gray, headerFg = colors.white,
        bg = colors.black, fg = colors.lightGray,
        selBg = colors.blue, selFg = colors.white,
        onBg = colors.green, offBg = colors.red,
        footerBg = colors.gray, footerFg = colors.white,
        scrollTrackBg = colors.gray, scrollTrackFg = colors.lightGray,
        scrollThumbBg = colors.blue, scrollThumbFg = colors.white,
        accentFg = colors.lightBlue,
        fieldBg = colors.black, fieldFg = colors.lightGray,
        fieldFocusBg = colors.blue, fieldFocusFg = colors.white,
    },
    mono = {
        headerBg = colors.white, headerFg = colors.black,
        bg = colors.black, fg = colors.white,
        selBg = colors.white, selFg = colors.black,
        onBg = colors.white, offBg = colors.gray,
        footerBg = colors.white, footerFg = colors.black,
        scrollTrackBg = colors.gray, scrollTrackFg = colors.lightGray,
        scrollThumbBg = colors.white, scrollThumbFg = colors.black,
        accentFg = colors.lightGray,
        fieldBg = colors.gray, fieldFg = colors.white,
        fieldFocusBg = colors.white, fieldFocusFg = colors.black,
    },
    highcontrast = {
        headerBg = colors.black, headerFg = colors.yellow,
        bg = colors.black, fg = colors.white,
        selBg = colors.yellow, selFg = colors.black,
        onBg = colors.lime, offBg = colors.red,
        footerBg = colors.black, footerFg = colors.yellow,
        scrollTrackBg = colors.black, scrollTrackFg = colors.yellow,
        scrollThumbBg = colors.yellow, scrollThumbFg = colors.black,
        accentFg = colors.yellow,
        fieldBg = colors.black, fieldFg = colors.yellow,
        fieldFocusBg = colors.yellow, fieldFocusFg = colors.black,
    },
}

local function palette()
    return PALETTES[colorScheme] or PALETTES.default
end

-- ===========================================================================
-- ycauth: SHA-256 / signing / pairing helpers.
-- Embedded copy of graphic/youcube-relaycon/src/lib/ycauth.lua - keep them in sync.
-- ===========================================================================
local auth = (function()
--[[ ycauth - hashing, signing and pairing helpers shared by the YouCube
     player and the relaycon hub. Game-grade authentication: it keeps stray or
     foreign devices from controlling a theater, it is not meant to stop a
     determined attacker who can sniff the wireless channel. ]]

local M = {}

-- bit ops: CC:Tweaked ships bit32; fall back to the older `bit` API
local band, bor, bxor, bnot, shr, shl
if bit32 then
    band, bor, bxor, bnot, shr, shl = bit32.band, bit32.bor, bit32.bxor, bit32.bnot, bit32.rshift, bit32.lshift
elseif bit then
    local B = bit
    band, bor, bxor, bnot = B.band, B.bor, B.bxor, B.bnot
    shr = function(a, n) return B.blogic_rshift(a, n) end
    shl = function(a, n) return B.blshift(a, n) end
else
    error("ycauth: no bit library available")
end

local function rotr(x, n)
    return bor(shr(x, n), band(shl(x, 32 - n), 0xffffffff))
end

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
}
local H0 = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }

--- SHA-256 of a string, returned as 64 lowercase hex characters.
function M.sha256(msg)
    local len = #msg
    msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64)
    local bits = len * 8
    msg = msg .. string.char(0, 0, 0, 0,
        band(shr(bits, 24), 255), band(shr(bits, 16), 255), band(shr(bits, 8), 255), band(bits, 255))

    local h = { H0[1], H0[2], H0[3], H0[4], H0[5], H0[6], H0[7], H0[8] }
    local w = {}
    for chunk = 1, #msg, 64 do
        for i = 0, 15 do
            local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
            w[i] = a * 16777216 + b * 65536 + c * 256 + d
        end
        for i = 16, 63 do
            local x, y = w[i - 15], w[i - 2]
            local s0 = bxor(rotr(x, 7), rotr(x, 18), shr(x, 3))
            local s1 = bxor(rotr(y, 17), rotr(y, 19), shr(y, 10))
            w[i] = band(w[i - 16] + s0 + w[i - 7] + s1, 0xffffffff)
        end
        local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
        for i = 0, 63 do
            local S1 = bxor(rotr(e, 6), rotr(e, 11), rotr(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local t1 = band(hh + S1 + ch + K[i + 1] + w[i], 0xffffffff)
            local S0 = bxor(rotr(a, 2), rotr(a, 13), rotr(a, 22))
            local maj = bxor(band(a, b), band(a, c), band(b, c))
            local t2 = band(S0 + maj, 0xffffffff)
            hh, g, f, e = g, f, e, band(d + t1, 0xffffffff)
            d, c, b, a = c, b, a, band(t1 + t2, 0xffffffff)
        end
        h[1] = band(h[1] + a, 0xffffffff); h[2] = band(h[2] + b, 0xffffffff)
        h[3] = band(h[3] + c, 0xffffffff); h[4] = band(h[4] + d, 0xffffffff)
        h[5] = band(h[5] + e, 0xffffffff); h[6] = band(h[6] + f, 0xffffffff)
        h[7] = band(h[7] + g, 0xffffffff); h[8] = band(h[8] + hh, 0xffffffff)
    end
    local out = {}
    for i = 1, 8 do out[i] = string.format("%08x", h[i]) end
    return table.concat(out)
end

--- Milliseconds since epoch (real time, so it agrees between computers).
function M.now()
    if os.epoch then return os.epoch("utc") end
    return os.time() * 1000
end

local seeded = false
local function seed()
    if seeded then return end
    seeded = true
    local id = (os.getComputerID and os.getComputerID()) or 0
    math.randomseed(M.now() + id * 7919 + math.floor((os.clock() or 0) * 1000))
    math.random(); math.random()
end

--- `nbytes` random bytes as hex. Whitened through SHA-256 with clock input.
function M.random_hex(nbytes)
    seed()
    local out = ""
    while #out < nbytes * 2 do
        out = out .. M.sha256(math.random(0, 2147483647) .. ":" .. M.now() .. ":" .. (os.clock() or 0) .. ":" .. #out)
    end
    return out:sub(1, nbytes * 2)
end

--- Random six digit pairing code, e.g. "482913".
function M.new_code()
    seed()
    return string.format("%06d", math.random(0, 999999))
end

--- "482913" -> "482-913" for display.
function M.fmt_code(code)
    return code:sub(1, 3) .. "-" .. code:sub(4)
end

--- Strips spaces/dashes so "482-913" and "482913" are the same code.
function M.clean_code(code)
    return (tostring(code or ""):gsub("[^%d]", ""))
end

--- Stable text form of a table of scalars: sorted "k=v" pairs.
function M.canon(t)
    if type(t) ~= "table" then return tostring(t or "") end
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        local v = t[k]
        if v == nil then v = t[tonumber(k)] end
        if type(v) == "table" then v = M.canon(v) end
        parts[#parts + 1] = k .. "=" .. tostring(v)
    end
    return table.concat(parts, ";")
end

--- Signature over any number of parts, keyed with `secret`.
function M.sign(secret, ...)
    local parts = { ... }
    for i = 1, select("#", ...) do parts[i] = tostring(parts[i] == nil and "" or parts[i]) end
    return M.sha256(tostring(secret) .. "\0" .. table.concat(parts, "\0"))
end

--- Comparison that doesn't bail out at the first differing character.
function M.eq(a, b)
    a, b = tostring(a or ""), tostring(b or "")
    local diff = (#a == #b) and 0 or 1
    for i = 1, math.max(#a, #b) do
        if a:byte(i) ~= b:byte(i) then diff = 1 end
    end
    return diff == 0
end

--- XOR two hex strings (result is as long as the shorter one).
function M.xor_hex(a, b)
    local n = math.min(#a, #b)
    local out = {}
    for i = 1, n do
        out[i] = string.format("%x", bxor(tonumber(a:sub(i, i), 16), tonumber(b:sub(i, i), 16)))
    end
    return table.concat(out)
end

-- Pairing: the code never travels in clear text. The hub proves it knows the
-- code (proof) and the new shared secret is masked with a key derived from it.
function M.pair_proof(tid, nonce, code)
    return M.sha256("pair\0" .. tid .. "\0" .. nonce .. "\0" .. M.clean_code(code))
end

function M.pair_mask(tid, nonce, code)
    return M.sha256("mask\0" .. tid .. "\0" .. nonce .. "\0" .. M.clean_code(code))
end

--- Player's confirmation that it now holds `secret` (checked by the hub).
function M.pair_ack(secret, tid, nonce)
    return M.sha256("ack\0" .. secret .. "\0" .. tid .. "\0" .. nonce)
end

return M

end)()

-- ===========================================================================
-- Identity & Networks
-- ===========================================================================

local function generateUUID()
    math.randomseed((os.epoch and os.epoch("utc") or os.time()) + (os.getComputerID() or 0))
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return (template:gsub("[xy]", function(c)
        local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
        return string.format("%x", v)
    end))
end

-- Deterministic name -> modem channel (1..65000)
local function nameToChannel(name)
    local h = 0
    for i = 1, #name do
        h = (h * 31 + string.byte(name, i)) % 65536
    end
    return (h % 65000) + 1
end

-- (Re)tunes this device's modem to the channel for `name`.
local function tuneToNetwork(name)
    networkName = name
    local known = false
    for _, n in ipairs(knownNetworks) do
        if n == name then known = true; break end
    end
    if not known then table.insert(knownNetworks, name) end

    if modem then
        if currentChannel then pcall(modem.close, currentChannel) end
        currentChannel = nameToChannel(name)
        modem.open(currentChannel)
    end
end

local function send(msg)
    if modem and currentChannel then
        modem.transmit(currentChannel, currentChannel, msg)
    end
end

-- ===========================================================================
-- Persistence
-- ===========================================================================

local function applyRedstone()
    if isPocket then return end
    for _, r in ipairs(relays) do
        if r.relayName and r.side then
            pcall(function()
                local relayPeripheral = peripheral.wrap(r.relayName)
                if relayPeripheral and relayPeripheral.setOutput then
                    relayPeripheral.setOutput(r.side, r.state or false)
                end
            end)
        end
    end
end

local function saveConfig()
    local f = fs.open(CONFIG_FILE, "w")
    f.write(textutils.serializeJSON({
        relays = relays,
        nextId = nextRelayId,
        scale = monitorScale,
        uiStyle = uiStyle,
        colorScheme = colorScheme,
        overflowMode = overflowMode,
        network = networkName,
        knownNetworks = knownNetworks,
        clients = baseClientSettings,
        theaters = theaters,
    }))
    f.close()
end

local function loadConfig()
    if fs.exists(CONFIG_FILE) then
        local f = fs.open(CONFIG_FILE, "r")
        local data = textutils.unserializeJSON(f.readAll()) or {}
        f.close()
        if data.relays then
            relays = data.relays
            monitorScale = data.scale or monitorScale
            uiStyle = data.uiStyle or uiStyle
            colorScheme = data.colorScheme or colorScheme
            overflowMode = data.overflowMode or overflowMode
            networkName = data.network or networkName
            knownNetworks = data.knownNetworks or knownNetworks
            baseClientSettings = data.clients or {}
            theaters = data.theaters or {}
            nextRelayId = data.nextId or 1
        elseif type(data) == "table" then
            relays = data -- legacy bare-array save file
        end
    end

    -- Backfill fields for relays saved by older versions of this script
    local maxId = 0
    for _, r in ipairs(relays) do
        if r.id and r.id > maxId then maxId = r.id end
    end
    for _, r in ipairs(relays) do
        if not r.id then maxId = maxId + 1; r.id = maxId end
        if r.pinned == nil then r.pinned = false end
        r.autoTime = r.autoTime or { enabled = false }
        r.autoRedstone = r.autoRedstone or { enabled = false }
        r.autoSensor = r.autoSensor or { enabled = false }
        r.autoGPS = r.autoGPS or { enabled = false }
    end
    nextRelayId = math.max(nextRelayId, maxId + 1)

    applyRedstone()
end

local function saveClientState()
    local f = fs.open(CLIENT_STATE_FILE, "w")
    f.write(textutils.serializeJSON({
        uuid = clientId,
        uiStyle = uiStyle,
        colorScheme = colorScheme,
        overflowMode = overflowMode,
        textSize = textSize,
        network = networkName,
        knownNetworks = knownNetworks,
        cachedRelays = relays,
    }))
    f.close()
end

local function loadClientState()
    if fs.exists(CLIENT_STATE_FILE) then
        local f = fs.open(CLIENT_STATE_FILE, "r")
        local data = textutils.unserializeJSON(f.readAll()) or {}
        f.close()
        clientId = data.uuid
        uiStyle = data.uiStyle or uiStyle
        colorScheme = data.colorScheme or colorScheme
        overflowMode = data.overflowMode or overflowMode
        textSize = data.textSize or textSize
        networkName = data.network or networkName
        knownNetworks = data.knownNetworks or knownNetworks
        if data.cachedRelays then relays = data.cachedRelays end
    end
    if not clientId then
        clientId = generateUUID()
        saveClientState()
    end
end

local function clientSettingsPayload()
    return { uiStyle = uiStyle, colorScheme = colorScheme, overflowMode = overflowMode, textSize = textSize }
end

local function persistSettings()
    if isPocket then
        saveClientState()
        send({ cmd = "setClientConfig", clientId = clientId, data = clientSettingsPayload() })
    else
        saveConfig()
    end
end

-- ===========================================================================
-- Relay list helpers (id-based so reorder/pin never desyncs selection)
-- ===========================================================================

local function findRelayById(id)
    for _, r in ipairs(relays) do
        if r.id == id then return r end
    end
    return nil
end

local function findRelayIndexById(id)
    for i, r in ipairs(relays) do
        if r.id == id then return i end
    end
    return nil
end

-- Pinned relays float to the top; order is preserved within each group.
local function buildDisplayList()
    local pinned, rest = {}, {}
    for _, r in ipairs(relays) do
        if r.pinned then table.insert(pinned, r) else table.insert(rest, r) end
    end
    local out = {}
    for _, r in ipairs(pinned) do table.insert(out, r) end
    for _, r in ipairs(rest) do table.insert(out, r) end
    return out
end

local function togglePin(id)
    local r = findRelayById(id)
    if r then r.pinned = not r.pinned end
end

-- Swaps with the nearest neighbour that has the same pinned state.
local function moveRelay(id, direction)
    local idx = findRelayIndexById(id)
    if not idx then return end
    local pinned = relays[idx].pinned
    local j = idx + direction
    while relays[j] and relays[j].pinned ~= pinned do
        j = j + direction
    end
    if relays[j] then
        relays[idx], relays[j] = relays[j], relays[idx]
    end
end

local function moveSelection(dir)
    local list = buildDisplayList()
    if #list == 0 then selectedRelayId = nil; return end
    local pos = 1
    for i, r in ipairs(list) do
        if r.id == selectedRelayId then pos = i; break end
    end
    pos = math.max(1, math.min(#list, pos + dir))
    selectedRelayId = list[pos].id
end

local function broadcastSync()
    if not isPocket then
        send({ cmd = "sync", data = relays })
    end
end

-- ===========================================================================
-- Automation Evaluator (host only)
-- ===========================================================================

local function evaluateAutomations()
    if isPocket then return end
    local curTime = os.time()
    local stateChanged = false

    for _, r in ipairs(relays) do
        if not r.paused then
            local autoTargetState = nil
            local hasActiveTrigger = false

            -- 1. Time Trigger
            if r.autoTime and r.autoTime.enabled then
                hasActiveTrigger = true
                local startH = r.autoTime.startHour or 6.0
                local endH = r.autoTime.endHour or 18.0
                if startH < endH then
                    autoTargetState = (curTime >= startH and curTime < endH)
                else
                    autoTargetState = (curTime >= startH or curTime < endH)
                end
            end

            -- 2. Redstone Level Trigger
            if r.autoRedstone and r.autoRedstone.enabled then
                hasActiveTrigger = true
                autoTargetState = redstone.getInput(r.autoRedstone.side or "left")
            end

            -- 3. Motion Sensor Trigger (edge-triggered: a pulse arms the relay
            --    for holdSeconds; a fresh pulse re-arms/extends it)
            if r.autoSensor and r.autoSensor.enabled then
                hasActiveTrigger = true
                local side = r.autoSensor.side or "back"
                local hold = r.autoSensor.holdSeconds or 5
                sensorState[r.id] = sensorState[r.id] or { lastInput = false, armedUntil = nil }
                local st = sensorState[r.id]
                local cur = redstone.getInput(side)
                if cur and not st.lastInput then
                    st.armedUntil = os.clock() + hold
                end
                st.lastInput = cur
                if st.armedUntil and os.clock() < st.armedUntil then
                    autoTargetState = true
                elseif st.armedUntil then
                    autoTargetState = false
                    st.armedUntil = nil
                end
            end

            -- 4. GPS Proximity Trigger
            if r.autoGPS and r.autoGPS.enabled and lastPlayerPos then
                hasActiveTrigger = true
                local dx = lastPlayerPos.x - (r.autoGPS.x or 0)
                local dz = lastPlayerPos.z - (r.autoGPS.z or 0)
                local dist2D = math.sqrt(dx * dx + dz * dz)

                local inRadius = dist2D <= (r.autoGPS.radius or 10)
                local yMax = r.autoGPS.maxYDiff or 1.5
                local inY = true
                if r.autoGPS.targetY ~= nil then
                    inY = math.abs(lastPlayerPos.y - r.autoGPS.targetY) <= yMax
                end
                autoTargetState = (inRadius and inY)
            end

            if hasActiveTrigger and autoTargetState ~= nil then
                if r.override then
                    if (r.lastAutoState ~= nil and r.lastAutoState ~= autoTargetState) or (r.state == autoTargetState) then
                        r.override = false
                    end
                end

                r.lastAutoState = autoTargetState

                if not r.override then
                    if r.state ~= autoTargetState then
                        r.state = autoTargetState
                        stateChanged = true
                    end
                end
            end
        end
    end

    if stateChanged then
        applyRedstone()
        saveConfig()
        broadcastSync()
    end
end

local function cycleMonitorScale()
    local idx = 1
    for i, s in ipairs(SCALES) do
        if math.abs(s - monitorScale) < 0.1 then idx = i; break end
    end
    monitorScale = SCALES[(idx % #SCALES) + 1]
    saveConfig()
end

-- Poll GPS fast near an armed trigger, slowly elsewhere
local function getDynamicGPSInterval(currentX, currentY, currentZ)
    if not currentX or not currentZ then return 2.0 end

    local minDist = math.huge
    for _, r in ipairs(relays) do
        if r.autoGPS and r.autoGPS.enabled and not r.paused then
            local dx = currentX - (r.autoGPS.x or 0)
            local dz = currentZ - (r.autoGPS.z or 0)
            local dist2D = math.sqrt(dx * dx + dz * dz)
            local distToEdge = math.max(0, dist2D - (r.autoGPS.radius or 10))
            if distToEdge < minDist then minDist = distToEdge end
        end
    end

    if minDist == math.huge then return 2.0 end
    if minDist <= 5 then
        return 0.1
    elseif minDist >= 50 then
        return 2.0
    else
        return 0.1 + ((minDist - 5) / (50 - 5)) * (2.0 - 0.1)
    end
end

-- ===========================================================================
-- List rendering
-- ===========================================================================

local function relayBadge(r)
    local trig = ""
    if r.autoTime and r.autoTime.enabled then trig = trig .. "T" end
    if r.autoRedstone and r.autoRedstone.enabled then trig = trig .. "R" end
    if r.autoSensor and r.autoSensor.enabled then trig = trig .. "S" end
    if r.autoGPS and r.autoGPS.enabled then trig = trig .. "G" end
    return trig
end

local function relayDetailLine(r)
    local parts = { string.format("%s:%s", r.relayName or "relay", r.side or "top") }
    if r.autoTime and r.autoTime.enabled then
        table.insert(parts, string.format("Time %.1f-%.1f", r.autoTime.startHour or 0, r.autoTime.endHour or 0))
    end
    if r.autoRedstone and r.autoRedstone.enabled then
        table.insert(parts, string.format("Redstone(%s)", r.autoRedstone.side or "left"))
    end
    if r.autoSensor and r.autoSensor.enabled then
        table.insert(parts, string.format("Sensor(%s,%ss)", r.autoSensor.side or "back", tostring(r.autoSensor.holdSeconds or 5)))
    end
    if r.autoGPS and r.autoGPS.enabled then
        table.insert(parts, string.format("GPS(r=%s)", tostring(r.autoGPS.radius or 10)))
    end
    return table.concat(parts, "  ")
end

-- Bottom toolbar items: { label, action }. "More" always survives narrow screens.
local TOOLBAR_FULL = { { "Add", "add" }, { "Edit", "edit" }, { "Trig", "triggers" }, { "More", "menu" } }
local function buildToolbar(w)
    local items = {}
    for _, it in ipairs(TOOLBAR_FULL) do items[#items + 1] = it end
    local function width()
        local t = 0
        for i, it in ipairs(items) do t = t + #it[1] + 2 + (i > 1 and 1 or 0) end
        return t
    end
    while width() > w and #items > 2 do table.remove(items, #items - 1) end
    return items
end

-- Renders the relay list to `target` (term or a monitor).
-- activeSelectedId: relay id to highlight, or nil to just mirror (no highlight/autoscroll)
-- banner: optional { text=, level= } bar under the header
-- emptyMessage: optional override for the "no relays" text
-- Returns rowMap (screen row -> relay id) and the clamped/autoscrolled offset.
local function drawUI(target, activeSelectedId, offset, banner, emptyMessage, showToolbar)
    local pal = palette()
    local w, h = target.getSize()
    setColors(target, pal.fg, pal.bg)
    target.clear()

    -- Header
    setColors(target, pal.headerFg, pal.headerBg)
    target.setCursorPos(1, 1)
    local titleLeft = isPocket and "HUB (POCKET)" or string.format("HUB (BASE %.1fx)", monitorScale)
    if w < 28 then titleLeft = "HUB" end
    if w >= 46 then titleLeft = titleLeft .. " [" .. networkName .. "]" end

    local gpsTag, gpsFg
    if lastPlayerPos and lastGPSFixTime and (os.clock() - lastGPSFixTime) < GPS_STALE_AFTER then
        gpsTag, gpsFg = "[GPS OK]", pal.headerFg
    elseif lastPlayerPos then
        gpsTag, gpsFg = "[GPS STALE]", colors.yellow
    else
        gpsTag, gpsFg = "[NO GPS]", colors.red
    end

    local padLen = math.max(0, w - #titleLeft - #gpsTag)
    target.write(titleLeft:sub(1, w))
    target.write(string.rep(" ", padLen))
    setColors(target, gpsFg, pal.headerBg)
    target.write(gpsTag:sub(1, math.max(0, w - #titleLeft - padLen)))

    local bannerLines = 0
    if banner then
        bannerLines = 1
        local lvl = banner.level
        local bgc = (lvl == "warn") and colors.red or ((lvl == "ok") and colors.green or colors.yellow)
        local fgc = (lvl == "warn" or lvl == "ok") and colors.white or colors.black
        setColors(target, fgc, bgc)
        target.setCursorPos(1, 2)
        target.write((" " .. banner.text .. string.rep(" ", w)):sub(1, w))
    end

    -- Rows per item depends on style (wrap only matters for compact)
    local rowsPerItem
    if uiStyle == "spacious" then
        rowsPerItem = 3
    elseif uiStyle == "detailed" then
        rowsPerItem = 2
    elseif overflowMode == "wrap" then
        rowsPerItem = 2
    else
        rowsPerItem = 1
    end

    local contentStartY = 2 + bannerLines
    local availableRows = math.max(0, h - contentStartY)
    local viewH = math.max(1, math.floor(availableRows / rowsPerItem))

    local list = buildDisplayList()
    local totalItems = #list

    if activeSelectedId then
        local selPos = nil
        for i, r in ipairs(list) do
            if r.id == activeSelectedId then selPos = i; break end
        end
        if selPos then
            if selPos - 1 < offset then offset = selPos - 1 end
            if selPos > offset + viewH then offset = selPos - viewH end
        end
    end
    offset = math.max(0, math.min(offset, math.max(0, totalItems - viewH)))

    local rowMap = {}

    if totalItems == 0 then
        setColors(target, colors.yellow, pal.bg)
        target.setCursorPos(2, contentStartY + 1)
        target.write((emptyMessage or "No Relays Configured!"):sub(1, math.max(1, w - 2)))
        if not emptyMessage then
            setColors(target, colors.lightGray, pal.bg)
            target.setCursorPos(2, contentStartY + 3)
            target.write("Press [A] to add a relay.")
        end
    else
        for i = 1, viewH do
            local itemPos = i + offset
            if itemPos > totalItems then break end
            local r = list[itemPos]
            local lineY = contentStartY + (i - 1) * rowsPerItem
            if lineY > h - 1 then break end

            local isSelected = (activeSelectedId == r.id)
            local bg = isSelected and pal.selBg or pal.bg
            for rr = 0, rowsPerItem - 1 do
                if lineY + rr <= h - 1 then rowMap[lineY + rr] = r.id end
            end

            local pinMark = r.pinned and "*" or ""
            local badge = relayBadge(r)
            local badgeStr = (badge ~= "") and (" [" .. badge .. "]") or ""
            local nameFg = isSelected and pal.selFg or pal.fg

            local function clearRow(y)
                setColors(target, pal.fg, bg)
                target.setCursorPos(1, y)
                target.write(string.rep(" ", w - 1))
            end

            local function drawStatusAndState(y)
                target.setCursorPos(1, y)
                if r.paused then
                    setColors(target, colors.yellow, bg); target.write("P")
                elseif r.override then
                    setColors(target, colors.orange, bg); target.write("!")
                elseif badge ~= "" then
                    setColors(target, colors.cyan, bg); target.write("A")
                else
                    setColors(target, pal.fg, bg); target.write(" ")
                end
                target.setCursorPos(2, y)
                if r.state then
                    setColors(target, colors.white, pal.onBg); target.write(" ON ")
                else
                    setColors(target, colors.white, pal.offBg); target.write(" OFF ")
                end
            end

            if uiStyle == "spacious" then
                -- Row 1: name on its own line
                clearRow(lineY)
                setColors(target, nameFg, bg)
                target.setCursorPos(2, lineY)
                target.write(string.format("%d.%s%s", itemPos, pinMark, r.name or "Relay"):sub(1, math.max(1, w - 2)))
                -- Row 2: state + badges
                if lineY + 1 <= h - 1 then
                    clearRow(lineY + 1)
                    drawStatusAndState(lineY + 1)
                    if badge ~= "" then
                        setColors(target, pal.fg, bg)
                        target.setCursorPos(8, lineY + 1)
                        target.write(("[" .. badge .. "]"):sub(1, math.max(1, w - 8)))
                    end
                end
                -- Row 3: peripheral + trigger summary
                if lineY + 2 <= h - 1 then
                    clearRow(lineY + 2)
                    setColors(target, colors.lightGray, bg)
                    target.setCursorPos(2, lineY + 2)
                    target.write(relayDetailLine(r):sub(1, math.max(1, w - 2)))
                end
            elseif uiStyle == "detailed" then
                clearRow(lineY)
                drawStatusAndState(lineY)
                setColors(target, nameFg, bg)
                target.setCursorPos(7, lineY)
                target.write(string.format("%d.%s%s%s", itemPos, pinMark, r.name or "Relay", badgeStr):sub(1, math.max(1, w - 8)))
                if lineY + 1 <= h - 1 then
                    clearRow(lineY + 1)
                    setColors(target, colors.lightGray, bg)
                    target.setCursorPos(7, lineY + 1)
                    target.write(relayDetailLine(r):sub(1, math.max(1, w - 8)))
                end
            elseif rowsPerItem == 2 then
                -- Compact + wrap: an overlong label continues on a second line
                clearRow(lineY)
                drawStatusAndState(lineY)
                setColors(target, nameFg, bg)
                local fullLabel = string.format("%d.%s%s%s", itemPos, pinMark, r.name or "Relay", badgeStr)
                local avail = math.max(1, w - 8)
                target.setCursorPos(7, lineY)
                target.write(fullLabel:sub(1, avail))
                if lineY + 1 <= h - 1 then
                    clearRow(lineY + 1)
                    if #fullLabel > avail then
                        setColors(target, nameFg, bg)
                        target.setCursorPos(7, lineY + 1)
                        target.write(fullLabel:sub(avail + 1, avail * 2))
                    end
                end
            else
                -- Plain compact: truncate, or scroll sideways when overlong
                clearRow(lineY)
                drawStatusAndState(lineY)
                setColors(target, nameFg, bg)
                local fullLabel = string.format("%d.%s%s%s", itemPos, pinMark, r.name or "Relay", badgeStr)
                if w > 36 then
                    fullLabel = fullLabel .. string.format(" (%s:%s)", r.relayName or "relay", r.side or "top")
                end
                local avail = math.max(1, w - 8)
                local shown
                if overflowMode == "scroll" and #fullLabel > avail then
                    local maxScroll = #fullLabel - avail
                    local pos = marqueePhase % (maxScroll + 4) -- brief pause at each end
                    local startIdx = math.min(maxScroll, pos) + 1
                    shown = fullLabel:sub(startIdx, startIdx + avail - 1)
                else
                    shown = fullLabel:sub(1, avail)
                end
                target.setCursorPos(7, lineY)
                target.write(shown)
            end
        end
    end

    -- Right scrollbar
    local sidebarX = w
    setColors(target, colors.black, colors.yellow)
    target.setCursorPos(sidebarX, contentStartY); target.write("^")

    local trackTop = contentStartY + 1
    local trackBottom = h - 2
    local trackH = trackBottom - trackTop + 1
    if trackH > 0 then
        setColors(target, pal.scrollTrackFg, pal.scrollTrackBg)
        for y = trackTop, trackBottom do
            target.setCursorPos(sidebarX, y); target.write("|")
        end
        if totalItems > viewH then
            local thumbY = math.floor(trackTop + (offset / math.max(1, totalItems - viewH)) * math.max(0, trackH - 1))
            setColors(target, pal.scrollThumbFg, pal.scrollThumbBg)
            target.setCursorPos(sidebarX, thumbY); target.write("#")
        end
    end

    setColors(target, colors.black, colors.yellow)
    target.setCursorPos(sidebarX, h - 1); target.write("v")

    -- Footer: clickable toolbar on the main terminal, a hint on monitors
    setColors(target, pal.footerFg, pal.footerBg)
    target.setCursorPos(1, h); target.write(string.rep(" ", w)); target.setCursorPos(1, h)
    local hits = {}
    if showToolbar then
        local x = 1
        for i, it in ipairs(buildToolbar(w)) do
            local label = " " .. it[1] .. " "
            if x + #label - 1 > w then break end
            if it[2] == "menu" then
                setColors(target, pal.selFg, pal.selBg)
            else
                setColors(target, pal.headerFg, pal.headerBg)
            end
            target.setCursorPos(x, h)
            target.write(label)
            hits[#hits + 1] = { x1 = x, x2 = x + #label - 1, action = it[2] }
            x = x + #label + 1
        end
    else
        target.write((" Tap a row to toggle"):sub(1, w))
    end

    setColors(target, pal.fg, pal.bg)
    return rowMap, offset, hits, contentStartY
end

-- ===========================================================================
-- Blocking-screen event pump
-- ===========================================================================
-- Forms/dialogs call uiPull() instead of os.pullEvent(). It only returns input
-- events; timers, redstone and modem traffic are handed to `backgroundHandler`
-- (installed by the host/pocket main loop), so automations keep running and no
-- network commands are lost while a form is open.

local backgroundHandler = nil
local UI_EVENTS = {
    key = true, key_up = true, char = true, paste = true,
    mouse_click = true, mouse_scroll = true, mouse_drag = true, mouse_up = true,
    term_resize = true,
}

-- `also` (optional) = set of non-input event names the caller wants returned
-- (after the background handler has seen them) so it can redraw.
local function uiPull(also)
    while true do
        local e = table.pack(os.pullEvent())
        if UI_EVENTS[e[1]] then return table.unpack(e, 1, e.n) end
        if backgroundHandler then backgroundHandler(table.unpack(e, 1, e.n)) end
        if also and also[e[1]] then return table.unpack(e, 1, e.n) end
    end
end

-- ===========================================================================
-- Generic form engine: label above value, row-based scrolling, mouse + keys
-- ===========================================================================

local function cycleChoice(field, state, dir)
    local choices = field.choices
    local cur = state[field.key]
    local idx = 1
    for i, c in ipairs(choices) do
        if c == cur then idx = i; break end
    end
    idx = ((idx - 1 + dir) % #choices) + 1
    state[field.key] = choices[idx]
end

-- Draws just the value box (the label lives on the row above it)
local function drawFormValueRow(target, x, y, w, field, state, focused)
    local pal = palette()
    local raw
    if field.type == "bool" then
        raw = state[field.key] and "[X] Yes" or "[ ] No"
    elseif field.type == "choice" then
        raw = "< " .. tostring(state[field.key]) .. " >"
    else
        raw = tostring(state[field.key] or "")
        -- Not editing: show the tail so the most recent text is visible
        if #raw > w - 1 then raw = "<" .. raw:sub(#raw - (w - 3)) end
    end
    setColors(target, focused and pal.fieldFocusFg or pal.fieldFg, focused and pal.fieldFocusBg or pal.fieldBg)
    target.setCursorPos(x, y)
    local text = " " .. raw
    if #text < w then text = text .. string.rep(" ", w - #text) end
    target.write(text:sub(1, w))
end

-- Single-line text input. Redraws on every keystroke and scrolls sideways so
-- the cursor (always at the end of the text) stays in view.
-- Enter commits. Clicking anywhere outside the box, or Tab/Up/Down, commits and
-- hands that click/key on to the form so focus is never "stuck" in the box.
local function editTextField(target, x, y, w, field, state)
    local pal = palette()
    local original = state[field.key]
    local buf = tostring(original or "")
    local errMsg = nil
    state[field.key] = buf

    -- Returns true if the buffer was accepted (numbers must parse).
    local function accept()
        if field.type == "number" then
            local n = tonumber(buf)
            if n == nil then return false end
            state[field.key] = n
        else
            state[field.key] = buf
        end
        return true
    end

    while true do
        local visibleW = math.max(1, w - 2) -- room for scroll marker + cursor
        local shown, scrolled = buf, false
        if #shown > visibleW then
            shown = shown:sub(#shown - visibleW + 1)
            scrolled = true
        end
        setColors(target, pal.fieldFocusFg, pal.fieldFocusBg)
        target.setCursorPos(x, y)
        local line = (scrolled and "<" or " ") .. shown .. "_"
        if #line < w then line = line .. string.rep(" ", w - #line) end
        target.write(line:sub(1, w))
        setColors(target, colors.red, pal.bg)
        target.setCursorPos(x, y + 1)
        target.write(((errMsg or "") .. string.rep(" ", w)):sub(1, w))

        local ev, p1, p2, p3 = uiPull()
        if ev == "char" or ev == "paste" then
            buf = buf .. p1
            errMsg = nil
        elseif ev == "key" then
            if p1 == keys.backspace then
                buf = buf:sub(1, -2)
                errMsg = nil
            elseif p1 == keys.enter then
                if accept() then return end
                errMsg = "Please enter a valid number"
            elseif p1 == keys.escape then
                state[field.key] = original
                return
            elseif p1 == keys.tab or p1 == keys.up or p1 == keys.down then
                if accept() then
                    os.queueEvent("key", p1)
                else
                    state[field.key] = original
                end
                return
            end
        elseif ev == "mouse_click" then
            local inside = (p3 == y and p2 >= x and p2 < x + w)
            if not inside then
                if not accept() then state[field.key] = original end
                os.queueEvent("mouse_click", p1, p2, p3)
                return
            end
        end
    end
end

local function getVisibleFields(fields, state)
    local out = {}
    for _, f in ipairs(fields) do
        if not f.visible or f.visible(state) then table.insert(out, f) end
    end
    return out
end

-- Sections take 1 row; every other field takes 2 (label row + value row)
local function layoutFormRows(visible)
    local rowStart, rowSpan = {}, {}
    local total = 0
    for i, f in ipairs(visible) do
        rowStart[i] = total
        rowSpan[i] = (f.type == "section") and 1 or 2
        total = total + rowSpan[i]
    end
    return rowStart, rowSpan, total
end

-- Returns true if saved, false if cancelled. Mutates `state` in place.
local function runForm(target, title, fields, state)
    local w, h = target.getSize()
    local fieldsAreaH = math.max(2, h - 4)
    local focusIdx = 1
    local rowOffset = 0

    local function isSelectable(i, visible)
        return visible[i] and visible[i].type ~= "section"
    end

    while true do
        local visible = getVisibleFields(fields, state)
        if #visible == 0 then return false end
        focusIdx = math.max(1, math.min(focusIdx, #visible))
        if not isSelectable(focusIdx, visible) then
            local j = focusIdx
            while j <= #visible and not isSelectable(j, visible) do j = j + 1 end
            if j > #visible then j = 1 end
            focusIdx = j
        end

        -- Keep the focused field fully in view
        local rowStart, rowSpan, totalRows = layoutFormRows(visible)
        local fS = rowStart[focusIdx]
        local fE = fS + rowSpan[focusIdx] - 1
        if fS < rowOffset then rowOffset = fS end
        if fE > rowOffset + fieldsAreaH - 1 then rowOffset = fE - fieldsAreaH + 1 end
        rowOffset = math.max(0, math.min(rowOffset, math.max(0, totalRows - fieldsAreaH)))

        local pal = palette()
        setColors(target, pal.fg, pal.bg)
        target.clear()
        setColors(target, pal.headerFg, pal.headerBg)
        target.setCursorPos(1, 1)
        target.write((" " .. title .. string.rep(" ", w)):sub(1, w))

        local rowOf, yOf = {}, {}
        for i, f in ipairs(visible) do
            local s = rowStart[i]
            local e = s + rowSpan[i] - 1
            if e >= rowOffset and s <= rowOffset + fieldsAreaH - 1 then
                if f.type == "section" then
                    local y = 2 + (s - rowOffset)
                    setColors(target, pal.accentFg, pal.bg)
                    target.setCursorPos(2, y)
                    target.write(f.label:sub(1, w - 2))
                    rowOf[y] = i
                else
                    local labelY = 2 + (s - rowOffset)
                    local valueY = labelY + 1
                    if labelY >= 2 and labelY <= 1 + fieldsAreaH then
                        setColors(target, pal.fg, pal.bg)
                        target.setCursorPos(2, labelY)
                        target.write(f.label:sub(1, w - 2))
                        rowOf[labelY] = i
                    end
                    if valueY >= 2 and valueY <= 1 + fieldsAreaH then
                        drawFormValueRow(target, 4, valueY, w - 4, f, state, (i == focusIdx))
                        rowOf[valueY] = i
                        yOf[i] = valueY
                    end
                end
            end
        end

        local buttonsY = h - 1
        setColors(target, colors.white, colors.green)
        target.setCursorPos(2, buttonsY); target.write("[ Save ]")
        setColors(target, colors.white, colors.red)
        target.setCursorPos(13, buttonsY); target.write("[ Cancel ]")

        setColors(target, pal.footerFg, pal.footerBg)
        target.setCursorPos(1, h); target.write(string.rep(" ", w)); target.setCursorPos(1, h)
        target.write((" [Tab]Next [Enter]Edit [S]ave [Esc]Cancel"):sub(1, w))

        local ev, p1, p2, p3 = uiPull()
        local field = visible[focusIdx]

        if ev == "key" then
            if p1 == keys.tab then
                repeat focusIdx = (focusIdx % #visible) + 1 until isSelectable(focusIdx, visible)
            elseif p1 == keys.up then
                local j = focusIdx
                repeat j = math.max(1, j - 1) until j == 1 or isSelectable(j, visible)
                if isSelectable(j, visible) then focusIdx = j end
            elseif p1 == keys.down then
                local j = focusIdx
                repeat j = math.min(#visible, j + 1) until j == #visible or isSelectable(j, visible)
                if isSelectable(j, visible) then focusIdx = j end
            elseif p1 == keys.left and field and field.type == "choice" then
                cycleChoice(field, state, -1)
            elseif p1 == keys.right and field and field.type == "choice" then
                cycleChoice(field, state, 1)
            elseif (p1 == keys.enter or p1 == keys.space) and field then
                if field.type == "bool" then
                    state[field.key] = not state[field.key]
                elseif field.type == "choice" then
                    cycleChoice(field, state, 1)
                elseif (field.type == "text" or field.type == "number") and yOf[focusIdx] then
                    editTextField(target, 4, yOf[focusIdx], w - 4, field, state)
                end
            elseif p1 == keys.s then
                return true
            elseif p1 == keys.escape then
                return false
            end
        elseif ev == "mouse_click" then
            if p3 == buttonsY then
                if p2 >= 2 and p2 <= 9 then return true end
                if p2 >= 13 and p2 <= 22 then return false end
            else
                local idx = rowOf[p3]
                if idx and visible[idx].type ~= "section" then
                    focusIdx = idx
                    local f = visible[idx]
                    if f.type == "bool" then
                        state[f.key] = not state[f.key]
                    elseif f.type == "choice" then
                        cycleChoice(f, state, (p1 == 2) and -1 or 1)
                    elseif (f.type == "text" or f.type == "number") and yOf[idx] then
                        editTextField(target, 4, yOf[idx], w - 4, f, state)
                    end
                end
            end
        end
    end
end

-- ===========================================================================
-- Concrete forms
-- ===========================================================================

local SIDES = { "top", "bottom", "left", "right", "front", "back" }

-- Returns {name, relayName, side, mode} if saved, nil if cancelled.
local function editRelayForm(defaults)
    local state = {
        name = defaults.name or ("Relay " .. (#relays + 1)),
        relayName = defaults.relayName or "redstone_relay_0",
        side = defaults.side or "top",
        mode = defaults.mode or "toggle",
    }
    local fields = {
        { key = "name", label = "Name:", type = "text" },
        { key = "relayName", label = "Peripheral ID:", type = "text" },
        { key = "side", label = "Output Side:", type = "choice", choices = SIDES },
        { key = "mode", label = "Mode:", type = "choice", choices = { "toggle", "pulse_on", "pulse_off" } },
    }
    if not runForm(term, "RELAY CONFIGURATION", fields, state) then return nil end
    return { name = state.name, relayName = state.relayName, side = state.side, mode = state.mode }
end

-- Returns {autoTime, autoRedstone, autoSensor, autoGPS} if saved, nil if cancelled.
local function editTriggersForm(r)
    local defX, defY, defZ = 0, 64, 0
    if isPocket then
        local gx, gy, gz = gps.locate(1)
        if gx then defX, defY, defZ = math.floor(gx), math.floor(gy), math.floor(gz) end
    elseif lastPlayerPos then
        defX, defY, defZ = math.floor(lastPlayerPos.x), math.floor(lastPlayerPos.y), math.floor(lastPlayerPos.z)
    end

    local state = {
        timeEnabled = (r.autoTime and r.autoTime.enabled) or false,
        startHour = (r.autoTime and r.autoTime.startHour) or 6.0,
        endHour = (r.autoTime and r.autoTime.endHour) or 18.0,

        rsEnabled = (r.autoRedstone and r.autoRedstone.enabled) or false,
        rsSide = (r.autoRedstone and r.autoRedstone.side) or "left",

        sensorEnabled = (r.autoSensor and r.autoSensor.enabled) or false,
        sensorSide = (r.autoSensor and r.autoSensor.side) or "back",
        sensorHoldSec = (r.autoSensor and r.autoSensor.holdSeconds) or 5,

        gpsEnabled = (r.autoGPS and r.autoGPS.enabled) or false,
        gpsX = (r.autoGPS and r.autoGPS.x) or defX,
        gpsUseY = (r.autoGPS and r.autoGPS.targetY ~= nil) or false,
        gpsY = (r.autoGPS and r.autoGPS.targetY) or defY,
        gpsMaxYDiff = (r.autoGPS and r.autoGPS.maxYDiff) or 1.5,
        gpsZ = (r.autoGPS and r.autoGPS.z) or defZ,
        gpsRadius = (r.autoGPS and r.autoGPS.radius) or 10,
    }

    local fields = {
        { key = "_t", type = "section", label = "-- Time Trigger --" },
        { key = "timeEnabled", label = "Enabled:", type = "bool" },
        { key = "startHour", label = "Start Hour (0-23.9):", type = "number", visible = function(s) return s.timeEnabled end },
        { key = "endHour", label = "End Hour (0-23.9):", type = "number", visible = function(s) return s.timeEnabled end },

        { key = "_r", type = "section", label = "-- Redstone Level Trigger --" },
        { key = "rsEnabled", label = "Enabled:", type = "bool" },
        { key = "rsSide", label = "Input Side:", type = "choice", choices = SIDES, visible = function(s) return s.rsEnabled end },

        { key = "_s", type = "section", label = "-- Motion Sensor (sculk etc) --" },
        { key = "sensorEnabled", label = "Enabled:", type = "bool" },
        { key = "sensorSide", label = "Input Side:", type = "choice", choices = SIDES, visible = function(s) return s.sensorEnabled end },
        { key = "sensorHoldSec", label = "Hold Time (sec):", type = "number", visible = function(s) return s.sensorEnabled end },

        { key = "_g", type = "section", label = "-- GPS Proximity Trigger --" },
        { key = "gpsEnabled", label = "Enabled:", type = "bool" },
        { key = "gpsX", label = "Target X:", type = "number", visible = function(s) return s.gpsEnabled end },
        { key = "gpsZ", label = "Target Z:", type = "number", visible = function(s) return s.gpsEnabled end },
        { key = "gpsRadius", label = "Radius (blocks):", type = "number", visible = function(s) return s.gpsEnabled end },
        { key = "gpsUseY", label = "Check Height Too:", type = "bool", visible = function(s) return s.gpsEnabled end },
        { key = "gpsY", label = "Target Y:", type = "number", visible = function(s) return s.gpsEnabled and s.gpsUseY end },
        { key = "gpsMaxYDiff", label = "Max Y Diff:", type = "number", visible = function(s) return s.gpsEnabled and s.gpsUseY end },
    }

    if not runForm(term, "TRIGGERS: " .. (r.name or "Relay"), fields, state) then return nil end

    local triggers = {
        autoTime = { enabled = state.timeEnabled, startHour = tonumber(state.startHour) or 6.0, endHour = tonumber(state.endHour) or 18.0 },
        autoRedstone = { enabled = state.rsEnabled, side = state.rsSide },
        autoSensor = { enabled = state.sensorEnabled, side = state.sensorSide, holdSeconds = tonumber(state.sensorHoldSec) or 5 },
        autoGPS = { enabled = state.gpsEnabled, x = tonumber(state.gpsX) or 0, z = tonumber(state.gpsZ) or 0, radius = tonumber(state.gpsRadius) or 10 },
    }
    if state.gpsUseY then
        triggers.autoGPS.targetY = tonumber(state.gpsY) or 64
        triggers.autoGPS.maxYDiff = tonumber(state.gpsMaxYDiff) or 1.5
    end
    return triggers
end

-- Updates the display-preference globals in place. Returns true if saved.
local function editSettingsForm()
    local state = {
        textSize = tostring(textSize),
        uiStyle = uiStyle,
        overflowMode = overflowMode,
        colorScheme = colorScheme,
        monitorScale = tostring(monitorScale),
    }
    local fields = {
        { key = "textSize", label = "Text Size:", type = "choice", choices = { "0.5", "1.0", "1.5", "2.0" }, visible = function() return isPocket end },
        { key = "uiStyle", label = "List Style:", type = "choice", choices = { "compact", "detailed", "spacious" } },
        { key = "overflowMode", label = "Long Names (compact):", type = "choice", choices = { "truncate", "scroll", "wrap" } },
        { key = "colorScheme", label = "Color Scheme:", type = "choice", choices = { "default", "dark", "mono", "highcontrast" } },
        { key = "monitorScale", label = "Monitor Scale:", type = "choice", choices = { "0.5", "1.0", "1.5", "2.0" }, visible = function() return not isPocket end },
    }
    if not runForm(term, "DISPLAY SETTINGS", fields, state) then return false end

    uiStyle = state.uiStyle
    overflowMode = state.overflowMode
    colorScheme = state.colorScheme
    if isPocket then
        textSize = tonumber(state.textSize) or textSize
        if term.setTextScale then pcall(term.setTextScale, textSize) end
    else
        monitorScale = tonumber(state.monitorScale) or monitorScale
    end
    return true
end

-- Switch to (or create) a named network. Returns true if the network changed.
local function editNetworkForm()
    local choices = {}
    for _, n in ipairs(knownNetworks) do table.insert(choices, n) end
    if #choices == 0 then choices = { networkName } end

    local state = { network = networkName, newNetwork = "" }
    local fields = {
        { key = "network", label = "Active Network:", type = "choice", choices = choices },
        { key = "newNetwork", label = "Or create/join a new one:", type = "text" },
    }
    if not runForm(term, "NETWORK SETTINGS", fields, state) then return false end

    local target = (state.newNetwork ~= "" and state.newNetwork) or state.network
    if not target or target == "" or target == networkName then return false end

    tuneToNetwork(target)
    if isPocket then
        -- Old relay data belonged to the previous network
        relays = {}
        selectedRelayId = nil
        hasEverSynced = false
        lastSyncTime = nil
    end
    return true
end

-- ===========================================================================
-- Shortcuts screen
-- ===========================================================================

local HELP_ITEMS = {
    { "Tap ON/OFF", "Toggle that relay" },
    { "Tap a name", "Select it (for Edit etc.)" },
    { "Bottom bar", "Add / Edit / Trig / More" },
    { "More (M)", "Pause, pin, move, delete," },
    { "", "settings, network, YouCube" },
    { "Up / Down", "Move selection" },
    { "Enter/Space", "Toggle selected relay" },
    { "A", "Add a new relay" },
    { "E", "Edit selected relay" },
    { "T", "Edit its automation triggers" },
    { "P", "Pause / clear manual override" },
    { "D", "Delete selected (asks first)" },
    { "N", "Pin / unpin (pinned go to top)" },
    { ", and .", "Move relay up / down" },
    { "V", "Cycle list style" },
    { "C", "Display settings" },
    { "W", "Network name / switch network" },
    { "S", "Monitor scale (base only)" },
    { "Y", "YouCube remote" },
    { "G", "Theaters / pairing" },
    { "H", "Show this screen" },
    { "Forms", "Tab/arrows move, Enter edits," },
    { "", "click away saves a field," },
    { "", "S saves form, Esc cancels" },
}

local function showHelpScreen(target)
    local w, h = target.getSize()
    local scroll = 0
    local viewH = math.max(1, h - 2)
    local keyW = math.min(13, math.floor(w / 2))

    while true do
        local pal = palette()
        setColors(target, pal.fg, pal.bg)
        target.clear()
        setColors(target, pal.headerFg, pal.headerBg)
        target.setCursorPos(1, 1)
        target.write((" SHORTCUTS  (network: " .. networkName .. ")" .. string.rep(" ", w)):sub(1, w))

        for i = 1, viewH do
            local item = HELP_ITEMS[i + scroll]
            if not item then break end
            setColors(target, pal.accentFg, pal.bg)
            target.setCursorPos(2, i + 1)
            target.write(item[1]:sub(1, keyW))
            setColors(target, pal.fg, pal.bg)
            target.setCursorPos(2 + keyW + 1, i + 1)
            target.write(item[2]:sub(1, math.max(1, w - keyW - 2)))
        end

        setColors(target, pal.footerFg, pal.footerBg)
        target.setCursorPos(1, h); target.write(string.rep(" ", w)); target.setCursorPos(1, h)
        target.write((" [Up/Down] Scroll  [Enter/Esc/H] Close"):sub(1, w))

        local ev, p1 = uiPull()
        if ev == "key" then
            if p1 == keys.up then
                scroll = math.max(0, scroll - 1)
            elseif p1 == keys.down then
                scroll = math.min(math.max(0, #HELP_ITEMS - viewH), scroll + 1)
            elseif p1 == keys.enter or p1 == keys.escape or p1 == keys.h then
                return
            end
        elseif ev == "mouse_scroll" then
            scroll = math.max(0, math.min(math.max(0, #HELP_ITEMS - viewH), scroll + p1))
        elseif ev == "mouse_click" then
            return
        end
    end
end

-- ===========================================================================
-- Host: relay mutation helpers (shared by local keys & network commands)
-- ===========================================================================

local function commit()
    saveConfig()
    applyRedstone()
    broadcastSync()
end

local function hostToggle(id)
    local r = findRelayById(id)
    if not r then return end

    r.override = true

    if r.mode == "toggle" then
        r.state = not r.state
        commit()
    elseif r.mode == "pulse_on" or r.mode == "pulse_off" then
        local activeState = (r.mode == "pulse_on")
        r.state = activeState
        commit()
        local timerID = os.startTimer(0.5)
        activePulses[timerID] = { id = id, targetState = not activeState }
    end
end

local function hostAddRelay(fields)
    local r = {
        id = nextRelayId,
        name = fields.name, relayName = fields.relayName, side = fields.side, mode = fields.mode,
        state = false, paused = false, override = false, pinned = false,
        autoTime = { enabled = false }, autoRedstone = { enabled = false },
        autoSensor = { enabled = false }, autoGPS = { enabled = false },
    }
    nextRelayId = nextRelayId + 1
    table.insert(relays, r)
    commit()
    return r
end

local function hostEditRelay(id, fields)
    local r = findRelayById(id)
    if not r then return end
    r.name, r.relayName, r.side, r.mode = fields.name, fields.relayName, fields.side, fields.mode
    commit()
end

local function hostEditTriggers(id, triggers)
    local r = findRelayById(id)
    if not r then return end
    r.autoTime, r.autoRedstone, r.autoSensor, r.autoGPS =
        triggers.autoTime, triggers.autoRedstone, triggers.autoSensor, triggers.autoGPS
    commit()
end

local function hostSetPaused(id)
    local r = findRelayById(id)
    if not r then return end
    if r.override then
        r.override = false
        r.paused = false
    else
        r.paused = not r.paused
    end
    commit()
end

local function hostSetPinned(id)
    togglePin(id)
    commit()
end

local function hostSetState(idOrName, state, side)
    local r = nil
    -- Try numeric ID first
    if type(idOrName) == "number" then
        r = findRelayById(idOrName)
    end
    -- Fall back to the peripheral name; if the caller gave a side, prefer the
    -- relay entry for that exact side (one peripheral can drive several relays)
    if not r then
        local fallback = nil
        for _, candidate in ipairs(relays) do
            if candidate.relayName == tostring(idOrName) then
                if side and candidate.side == side then r = candidate; break end
                fallback = fallback or candidate
            end
        end
        r = r or fallback
    end
    if not r then return end
    r.override = true
    r.state = state
    commit()
end

local function hostDeleteRelay(id)
    local idx = findRelayIndexById(id)
    if not idx then return end
    table.remove(relays, idx)
    commit()
end

local function hostMoveRelay(id, dir)
    moveRelay(id, dir)
    commit()
end

-- ===========================================================================
-- Shared engine: toasts, relay commands, dialogs, actions
-- ===========================================================================

-- Short-lived status line shown in the banner row (pocket and base)
local toast = nil
local function setToast(text, level)
    toast = { text = text, level = level or "info", untilClock = os.clock() + 3 }
end
local function currentToast()
    if toast and os.clock() < toast.untilClock then return toast end
    toast = nil
    return nil
end

-- One entry point for every relay command. The base applies it directly; a
-- pocket just forwards it and waits for the base's "sync". Network commands
-- arriving at the base go through the very same function.
local function hostExec(msg)
    local c = msg.cmd
    if c == "toggle" and msg.id then hostToggle(msg.id)
    elseif c == "addRelay" and msg.data then return hostAddRelay(msg.data)
    elseif c == "editRelay" and msg.id and msg.data then hostEditRelay(msg.id, msg.data)
    elseif c == "editTriggers" and msg.id and msg.data then hostEditTriggers(msg.id, msg.data)
    elseif c == "setPaused" and msg.id then hostSetPaused(msg.id)
    elseif c == "setPinned" and msg.id then hostSetPinned(msg.id)
    elseif c == "deleteRelay" and msg.id then hostDeleteRelay(msg.id)
    elseif c == "moveRelay" and msg.id and msg.dir then hostMoveRelay(msg.id, msg.dir)
    elseif c == "setState" and msg.id ~= nil and msg.state ~= nil then hostSetState(msg.id, msg.state, msg.side)
    else return nil end
    return true
end

local function sendRelayCmd(msg)
    if isPocket then
        send(msg)
        return true
    end
    return hostExec(msg)
end

-- Pocket-side helpers -------------------------------------------------------

local function applyReceivedClientConfig(data)
    if not data then return end
    if data.uiStyle then uiStyle = data.uiStyle end
    if data.colorScheme then colorScheme = data.colorScheme end
    if data.overflowMode then overflowMode = data.overflowMode end
    if data.textSize then
        textSize = data.textSize
        if term.setTextScale then pcall(term.setTextScale, textSize) end
    end
    saveClientState()
end

local function clientBanner()
    if not hasEverSynced then
        return { text = "Connecting to '" .. networkName .. "'...", level = "warn" }
    end
    if not lastSyncTime or (os.clock() - lastSyncTime) > BASE_UNREACHABLE_AFTER then
        local secs = lastSyncTime and math.floor(os.clock() - lastSyncTime) or 0
        return { text = string.format("BASE UNREACHABLE (last sync %ds ago)", secs), level = "warn" }
    end
    return nil
end

local function clientSayHello()
    send({ cmd = "hello", clientId = clientId, settings = clientSettingsPayload() })
    send({ cmd = "get" })
end

-- ===========================================================================
-- Theaters: YouCube players paired to this hub
-- ===========================================================================
-- The base owns the list of paired theaters (with their shared secrets). Pockets
-- never see a secret: they ask the base, and the base signs every command it
-- forwards. Theaters ignore anything that isn't signed with their secret.

local hubName = ((os.getComputerLabel and os.getComputerLabel()) or ("Hub " .. tostring(os.getComputerID()))):sub(1, 24)
local theaterRt = {}        -- base: [tid] = { online, seen, st }
local discovered = {}       -- base: [tid] = { name, nonce, seen }
local pendingPair = {}      -- base: [tid] = { secret, nonce, started, by, name }
local ycSeenRid, ycSeenOrder = {}, {}
local ycList = { paired = {}, discovered = {} }   -- what the screens show
local selectedTheater = nil
local lastTheaterSig = nil
local ycPingAt = 0
local CLOCK_SKEW = 30000

local function buildTheaterList()
    local paired, disc = {}, {}
    local now = os.clock()
    for tid, t in pairs(theaters) do
        local rt = theaterRt[tid] or {}
        paired[#paired + 1] = { tid = tid, name = tostring(t.name or "Theater"), online = rt.online and true or false, st = rt.st }
    end
    table.sort(paired, function(a, b) return a.name:lower() < b.name:lower() end)
    for tid, d in pairs(discovered) do
        local rt = theaterRt[tid]
        if now - d.seen < 8 and not (theaters[tid] and rt and rt.online) then
            disc[#disc + 1] = { tid = tid, name = tostring(d.name or "Theater") }
        end
    end
    table.sort(disc, function(a, b) return a.name:lower() < b.name:lower() end)
    return { paired = paired, discovered = disc }
end

local function listSignature(list)
    local parts = {}
    for _, t in ipairs(list.paired) do
        local st = t.st or {}
        parts[#parts + 1] = table.concat({ t.tid, t.name, tostring(t.online), tostring(st.title), tostring(st.state),
            tostring(st.paused), tostring(st.volume), tostring(st.captured) }, "|")
    end
    for _, d in ipairs(list.discovered) do parts[#parts + 1] = "D" .. d.tid .. d.name end
    return table.concat(parts, "\n")
end

-- Rebuilds the list and tells pockets when something changed (or always, if forced)
local function refreshTheaters(force)
    if isPocket then return end
    ycList = buildTheaterList()
    local sig = listSignature(ycList)
    if force or sig ~= lastTheaterSig then
        lastTheaterSig = sig
        send({ cmd = "yc_theaters", paired = ycList.paired, discovered = ycList.discovered })
    end
end

-- Signs and sends one command to a paired theater
local function hostYcCommand(tid, action, p)
    local t = theaters[tid]
    if not t then return false end
    p = p or {}
    local ts, rid = auth.now(), auth.random_hex(6)
    send({ cmd = "yc_cmd", tid = tid, ts = ts, rid = rid, action = action, p = p,
        sig = auth.sign(t.secret, tid, ts, rid, action, auth.canon(p)) })
    return true
end

local function rememberRid(rid)
    if ycSeenRid[rid] then return false end
    ycSeenRid[rid] = true
    ycSeenOrder[#ycSeenOrder + 1] = rid
    if #ycSeenOrder > 128 then ycSeenRid[table.remove(ycSeenOrder, 1)] = nil end
    return true
end

local function notifyPair(by, tid, ok, reason, name)
    if ok then
        setToast("Paired " .. tostring(name or "theater"), "ok")
    else
        setToast("Pairing failed: " .. tostring(reason or "unknown"), "warn")
    end
    send({ cmd = "yc_pair_done", tid = tid, ok = ok, reason = reason, name = name, by = by })
end

local function hostPairRequest(tid, code, by)
    local d = discovered[tid]
    if not d or os.clock() - d.seen > 8 then return notifyPair(by, tid, false, "theater not found", d and d.name) end
    local secret = auth.random_hex(16)
    pendingPair[tid] = { secret = secret, nonce = d.nonce, started = os.clock(), by = by, name = d.name }
    send({ cmd = "yc_pair", tid = tid, hub = hubName,
        proof = auth.pair_proof(tid, d.nonce, code),
        enc = auth.xor_hex(secret, auth.pair_mask(tid, d.nonce, code)) })
    setToast("Pairing with " .. tostring(d.name) .. "...", "info")
end

local function hostPairResult(msg)
    local pp = pendingPair[msg.tid]
    if not pp then return end
    pendingPair[msg.tid] = nil
    if msg.ok and type(msg.ack) == "string" and auth.eq(msg.ack, auth.pair_ack(pp.secret, msg.tid, pp.nonce)) then
        theaters[msg.tid] = { name = tostring(msg.name or pp.name or "Theater"):sub(1, 24), secret = pp.secret }
        discovered[msg.tid] = nil
        saveConfig()
        notifyPair(pp.by, msg.tid, true, nil, theaters[msg.tid].name)
        hostYcCommand(msg.tid, "ping")
        refreshTheaters(true)
    else
        notifyPair(pp.by, msg.tid, false, msg.ok and "bad confirmation" or tostring(msg.reason or "failed"), pp.name)
    end
end

local function hostUnpairTheater(tid)
    local t = theaters[tid]
    if not t then return end
    hostYcCommand(tid, "unpair")   -- tell the player first, while we still have the secret
    theaters[tid], theaterRt[tid] = nil, nil
    saveConfig()
    setToast("Unpaired " .. tostring(t.name), "warn")
    if selectedTheater == tid then selectedTheater = nil end
    refreshTheaters(true)
end

local function hostRenameTheater(tid, name)
    local t = theaters[tid]
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if not t or name == "" then return end
    t.name = name:sub(1, 24)
    hostYcCommand(tid, "rename", { name = t.name })
    saveConfig()
    refreshTheaters(true)
end

-- A theater's signed status report
local function hostYcStatus(msg)
    local t = theaters[msg.tid]
    local ts = tonumber(msg.ts)
    if not t or type(msg.st) ~= "table" or not ts then return end
    if math.abs(auth.now() - ts) > CLOCK_SKEW then return end
    if not auth.eq(msg.sig, auth.sign(t.secret, msg.tid, ts, auth.canon(msg.st))) then return end
    local rt = theaterRt[msg.tid] or {}
    theaterRt[msg.tid] = rt
    rt.seen = os.clock()
    rt.st = msg.st
    if msg.st.name and tostring(msg.st.name) ~= t.name then
        t.name = tostring(msg.st.name):sub(1, 24)
        saveConfig()
    end
    if not rt.online then
        rt.online = true
        setToast(t.name .. " connected", "ok")
        send({ cmd = "yc_event", kind = "online", name = t.name })
    end
    refreshTheaters()
end

-- Relay control requested by a paired theater (signed, replay-protected)
local function hostYcRelay(msg)
    local t = theaters[msg.tid]
    local ts = tonumber(msg.ts)
    if not t or type(msg.p) ~= "table" or not ts or type(msg.rid) ~= "string" then return end
    if math.abs(auth.now() - ts) > CLOCK_SKEW then return end
    if not auth.eq(msg.sig, auth.sign(t.secret, msg.tid, ts, msg.rid, "yc_relay", auth.canon(msg.p))) then return end
    if not rememberRid(msg.rid) then return end
    if msg.p.id ~= nil and msg.p.state ~= nil then
        hostSetState(msg.p.id, msg.p.state and true or false, msg.p.side)
    end
end

-- Once a second: pairing timeouts, offline detection, keep-alive pings
local function theaterTick()
    if isPocket then return end
    local now = os.clock()
    for tid, pp in pairs(pendingPair) do
        if now - pp.started > 10 then
            pendingPair[tid] = nil
            notifyPair(pp.by, tid, false, "no response", pp.name)
        end
    end
    for tid, t in pairs(theaters) do
        local rt = theaterRt[tid]
        if rt and rt.online and now - rt.seen > 10 then
            rt.online = false
            setToast(t.name .. " disconnected", "warn")
            send({ cmd = "yc_event", kind = "offline", name = t.name })
        end
    end
    if now - ycPingAt >= 4 then
        ycPingAt = now
        for tid in pairs(theaters) do hostYcCommand(tid, "ping") end
    end
    refreshTheaters()
end

-- Screens and shortcuts use these; pocket and base share them -----------------

local function findTheater(tid)
    for _, t in ipairs(ycList.paired) do
        if t.tid == tid then return t end
    end
end

local function selTheater()
    local t = selectedTheater and findTheater(selectedTheater)
    if not t then
        t = ycList.paired[1]
        selectedTheater = t and t.tid or nil
    end
    return t
end

local function sendYouCubeRemote(action, payload, quiet)
    local t = selTheater()
    if not t then
        if not quiet then setToast("No theater paired yet (More > Theaters)", "warn") end
        return false
    end
    if isPocket then
        send({ cmd = "yc_remote", tid = t.tid, action = action, p = payload or {}, clientId = clientId })
    else
        hostYcCommand(t.tid, action, payload or {})
    end
    return true
end

local function ycPair(tid, code)
    if isPocket then send({ cmd = "yc_pair_req", tid = tid, code = code, by = clientId })
    else hostPairRequest(tid, code, nil) end
end

local function ycUnpair(tid)
    if isPocket then send({ cmd = "yc_unpair", tid = tid }) else hostUnpairTheater(tid) end
end

local function ycRename(tid, name)
    if isPocket then send({ cmd = "yc_rename", tid = tid, name = name }) else hostRenameTheater(tid, name) end
end

-- Dialogs -------------------------------------------------------------------

local function wrapText(text, width)
    local lines, line = {}, ""
    for word in tostring(text):gmatch("%S+") do
        if #line + #word + (line == "" and 0 or 1) > width then
            if line ~= "" then lines[#lines + 1] = line end
            line = word
        else
            line = (line == "") and word or (line .. " " .. word)
        end
    end
    if line ~= "" then lines[#lines + 1] = line end
    return lines
end

-- Yes/No question. Returns true on Yes.
local function confirmDialog(title, text)
    local w, h = term.getSize()
    while true do
        local pal = palette()
        setColors(term, pal.fg, pal.bg)
        term.clear()
        setColors(term, pal.headerFg, pal.headerBg)
        term.setCursorPos(1, 1)
        term.write((" " .. title .. string.rep(" ", w)):sub(1, w))

        setColors(term, pal.fg, pal.bg)
        local y = 3
        for _, line in ipairs(wrapText(text, w - 2)) do
            if y >= h - 3 then break end
            term.setCursorPos(2, y)
            term.write(line)
            y = y + 1
        end
        local btnY = math.min(h - 2, y + 1)
        setColors(term, colors.white, colors.green)
        term.setCursorPos(2, btnY); term.write("  Yes  ")
        setColors(term, colors.white, colors.red)
        term.setCursorPos(11, btnY); term.write("  No  ")

        setColors(term, pal.footerFg, pal.footerBg)
        term.setCursorPos(1, h); term.write(string.rep(" ", w)); term.setCursorPos(1, h)
        term.write((" [Y]es  [N]o / Esc"):sub(1, w))

        local ev, p1, p2, p3 = uiPull()
        if ev == "key" then
            if p1 == keys.y or p1 == keys.enter then return true end
            if p1 == keys.n or p1 == keys.escape then return false end
        elseif ev == "mouse_click" and p3 == btnY then
            if p2 >= 2 and p2 <= 8 then return true end
            if p2 >= 11 and p2 <= 16 then return false end
        end
    end
end

-- Big-target list menu. items = { { label=, action=, enabled= }, ... }
-- Returns the chosen action, or nil if dismissed.
local function menuScreen(title, items)
    local w, h = term.getSize()
    local rowsPer = 2
    local viewN = math.max(1, math.floor((h - 2) / rowsPer))
    local sel, top = 1, 0

    local function pick(i)
        local it = items[i]
        if it and it.enabled ~= false then return it.action end
        return nil
    end

    while true do
        if sel - 1 < top then top = sel - 1 end
        if sel > top + viewN then top = sel - viewN end
        top = math.max(0, math.min(top, math.max(0, #items - viewN)))

        local pal = palette()
        setColors(term, pal.fg, pal.bg)
        term.clear()
        setColors(term, pal.headerFg, pal.headerBg)
        term.setCursorPos(1, 1)
        term.write((" " .. title .. string.rep(" ", w)):sub(1, w))

        for i = 1, viewN do
            local idx = top + i
            local it = items[idx]
            if not it then break end
            local y = 2 + (i - 1) * rowsPer
            local enabled = it.enabled ~= false
            local isSel = (idx == sel)
            local bg = isSel and pal.selBg or pal.bg
            local fg = (not enabled) and colors.gray or (isSel and pal.selFg or pal.fg)
            setColors(term, fg, bg)
            term.setCursorPos(1, y)
            term.write((" " .. it.label .. string.rep(" ", w)):sub(1, w - 1))
        end
        if #items > viewN then
            setColors(term, colors.black, colors.yellow)
            term.setCursorPos(w, 2); term.write("^")
            term.setCursorPos(w, h - 1); term.write("v")
        end

        setColors(term, pal.footerFg, pal.footerBg)
        term.setCursorPos(1, h); term.write(string.rep(" ", w)); term.setCursorPos(1, h)
        term.write((" [Up/Dn] [Enter] Pick [Esc] Back"):sub(1, w))

        local ev, p1, p2, p3 = uiPull()
        if ev == "key" then
            if p1 == keys.up then sel = math.max(1, sel - 1)
            elseif p1 == keys.down then sel = math.min(#items, sel + 1)
            elseif p1 == keys.enter or p1 == keys.space then
                local a = pick(sel)
                if a then return a end
            elseif p1 == keys.escape or p1 == keys.m then return nil end
        elseif ev == "mouse_scroll" then
            sel = math.max(1, math.min(#items, sel + p1))
        elseif ev == "mouse_click" then
            if p3 == 2 and p2 == w and #items > viewN then
                sel = math.max(1, sel - 1)
            elseif p3 == h - 1 and p2 == w and #items > viewN then
                sel = math.min(#items, sel + 1)
            elseif p3 >= 2 and p3 <= h - 1 then
                local idx = top + math.floor((p3 - 2) / rowsPer) + 1
                if items[idx] then
                    sel = idx
                    local a = pick(idx)
                    if a then return a end
                end
            end
        end
    end
end

-- Theaters list + YouCube remote screens ------------------------------------

local youcubeRemoteUI   -- defined below

-- Draws the active toast over the footer row. Returns true if it drew one.
local function footerToast(w, h)
    local t = currentToast()
    if not t then return false end
    local lvl = t.level
    local bgc = (lvl == "warn") and colors.red or ((lvl == "ok") and colors.green or colors.yellow)
    setColors(term, (lvl == "warn" or lvl == "ok") and colors.white or colors.black, bgc)
    term.setCursorPos(1, h)
    term.write((" " .. t.text .. string.rep(" ", w)):sub(1, w))
    return true
end

local function askText(title, label, default)
    local state = { v = default or "" }
    if not runForm(term, title, { { key = "v", label = label, type = "text" } }, state) then return nil end
    return state.v
end

local function theaterStatusText(t)
    if not t.online then return "Offline" end
    local st = t.st or {}
    if st.state == "playing" then
        return (st.paused and "Paused: " or "Playing: ") .. tostring(st.title or "")
    end
    return "Idle"
end

-- Per-theater menu. Returns "open" if the viewer wants its remote.
local function theaterMenu(t)
    local pick = menuScreen(t.name, {
        { label = "Open remote", action = "open" },
        { label = "Rename", action = "rename" },
        { label = "Unpair", action = "unpair" },
    })
    if pick == "open" then
        selectedTheater = t.tid
        return "open"
    elseif pick == "rename" then
        local name = askText("Rename theater", "New name:", t.name)
        if name and name ~= "" then ycRename(t.tid, name) end
    elseif pick == "unpair" then
        if confirmDialog("UNPAIR", 'Unpair "' .. t.name .. '"? It will show a new pairing code.') then ycUnpair(t.tid) end
    end
end

local function theatersScreen()
    local focus, top = 1, 0
    local REDRAW = { modem_message = true, timer = true }
    while true do
        local w, h = term.getSize()
        local pal = palette()
        local rows = {}
        for _, t in ipairs(ycList.paired) do rows[#rows + 1] = { kind = "paired", t = t } end
        for _, d in ipairs(ycList.discovered) do rows[#rows + 1] = { kind = "new", t = d } end
        local rh = 2
        local view = math.max(1, math.floor((h - 2) / rh))
        focus = math.max(1, math.min(focus, math.max(1, #rows)))
        if focus - 1 < top then top = focus - 1 end
        if focus > top + view then top = focus - view end
        top = math.max(0, math.min(top, math.max(0, #rows - view)))

        setColors(term, pal.fg, pal.bg)
        term.clear()
        setColors(term, pal.headerFg, pal.headerBg)
        term.setCursorPos(1, 1)
        term.write((" THEATERS" .. string.rep(" ", w)):sub(1, w))

        local items = {}
        if #rows == 0 then
            setColors(term, colors.yellow, pal.bg)
            term.setCursorPos(2, 3); term.write("No theaters yet.")
            setColors(term, pal.fg, pal.bg)
            local y = 5
            for _, line in ipairs(wrapText("Start YouCube on a computer on this network. It shows a pairing code and appears here.", w - 2)) do
                term.setCursorPos(2, y); term.write(line); y = y + 1
            end
        end
        for i = 1, view do
            local row = rows[top + i]
            if not row then break end
            local y = 2 + (i - 1) * rh
            local f = (top + i == focus)
            local bg = f and pal.selBg or pal.bg
            setColors(term, pal.fg, bg)
            term.setCursorPos(1, y); term.write(string.rep(" ", w))
            term.setCursorPos(1, y + 1); term.write(string.rep(" ", w))
            if row.kind == "paired" then
                setColors(term, row.t.online and colors.lime or colors.red, bg)
                term.setCursorPos(2, y); term.write("\7")
                setColors(term, f and pal.selFg or pal.fg, bg)
                term.setCursorPos(4, y); term.write(row.t.name:sub(1, w - 4))
                setColors(term, colors.lightGray, bg)
                term.setCursorPos(4, y + 1); term.write(theaterStatusText(row.t):sub(1, w - 4))
            else
                setColors(term, colors.yellow, bg)
                term.setCursorPos(2, y); term.write(("+ New: " .. row.t.name):sub(1, w - 2))
                setColors(term, colors.lightGray, bg)
                term.setCursorPos(4, y + 1); term.write(("Tap to pair"):sub(1, w - 4))
            end
            items[#items + 1] = { y1 = y, y2 = y + 1, idx = top + i }
        end
        setColors(term, colors.white, colors.gray)
        term.setCursorPos(1, h); term.write((" [Back]  tap a theater" .. string.rep(" ", w)):sub(1, w))
        footerToast(w, h)

        local function activate(row)
            if not row then return end
            if row.kind == "paired" then
                if theaterMenu(row.t) == "open" then youcubeRemoteUI() end
            else
                local code = askText("Pair " .. row.t.name, "Code on the theater screen:", "")
                if code then
                    local digits = code:gsub("%D", "")
                    if #digits == 6 then ycPair(row.t.tid, digits)
                    else setToast("The code has 6 digits", "warn") end
                end
            end
        end

        local ev, p1, p2, p3 = uiPull(REDRAW)
        if ev == "key" then
            if p1 == keys.up then focus = math.max(1, focus - 1)
            elseif p1 == keys.down then focus = math.min(#rows, focus + 1)
            elseif p1 == keys.enter or p1 == keys.space then activate(rows[focus])
            elseif p1 == keys.escape or p1 == keys.g or p1 == keys.backspace then return end
        elseif ev == "mouse_scroll" then
            focus = math.max(1, math.min(#rows, focus + p1))
        elseif ev == "mouse_click" then
            if p3 == h then return end
            for _, it in ipairs(items) do
                if p3 >= it.y1 and p3 <= it.y2 then focus = it.idx; activate(rows[it.idx]); break end
            end
        end
    end
end

youcubeRemoteUI = function()
    local w, h = term.getSize()
    local btns = {}
    local who = isPocket and ((os.getComputerLabel and os.getComputerLabel()) or ("Pocket " .. os.getComputerID())) or hubName
    local REDRAW = { timer = true, modem_message = true }

    local function cur() return selTheater() end
    local function st() local t = cur(); return t and t.st or nil end
    local function captured() local s = st(); return s and s.captured end
    local function announce(open) sendYouCubeRemote("session", { who = who, open = open }, true) end

    local function switchTheater(dir)
        local list = ycList.paired
        if #list < 2 then return end
        local idx = 1
        for i, t in ipairs(list) do if t.tid == selectedTheater then idx = i end end
        announce(false)
        selectedTheater = list[((idx - 1 + dir) % #list) + 1].tid
        announce(true)
    end
    local function setCapture(on)
        sendYouCubeRemote("capture_toggle", { captured = on })
        local s = st(); if s then s.captured = on end
    end
    local function doPause()
        local s = st()
        sendYouCubeRemote("play_pause", s and { paused = not s.paused } or nil)
    end
    local function setVolume(pct)
        pct = math.max(0, math.min(100, math.floor(pct + 0.5)))
        sendYouCubeRemote("volume_set", { volume = pct })
        local s = st(); if s then s.volume = pct end
    end
    local function stepVolume(d)
        local s = st()
        setVolume(((s and s.volume) or 100) + d)
    end

    announce(true)
    local sessTimer = os.startTimer(4)

    local function draw()
        local pal = palette()
        btns = {}
        local function btn(y, x1, label, bg, fg, fn)
            setColors(term, fg or colors.white, bg)
            term.setCursorPos(x1, y)
            term.write(label)
            btns[#btns + 1] = { y = y, x1 = x1, x2 = x1 + #label - 1, fn = fn }
            return x1 + #label + 1
        end
        setColors(term, pal.fg, pal.bg)
        term.clear()
        setColors(term, pal.headerFg, pal.headerBg)
        term.setCursorPos(1, 1)
        term.write((" YOUCUBE REMOTE" .. string.rep(" ", w)):sub(1, w))

        local t = cur()
        if not t then
            setColors(term, colors.yellow, pal.bg)
            term.setCursorPos(2, 3); term.write("No theater paired yet.")
            btn(5, 2, " Open Theaters ", colors.green, colors.white, function() theatersScreen() end)
        else
            local multi = #ycList.paired > 1
            btn(2, 1, " < ", multi and colors.gray or colors.black, colors.white, function() switchTheater(-1) end)
            btn(2, w - 2, " > ", multi and colors.gray or colors.black, colors.white, function() switchTheater(1) end)
            setColors(term, t.online and colors.lime or colors.red, pal.bg)
            term.setCursorPos(5, 2); term.write("\7")
            setColors(term, pal.fg, pal.bg)
            term.setCursorPos(7, 2); term.write(t.name:sub(1, w - 12))

            setColors(term, pal.accentFg, pal.bg)
            term.setCursorPos(2, 4); term.write("Now playing:")
            local s = t.st or {}
            local title = (s.title and s.title ~= "") and s.title or "-"
            local avail = w - 2
            if #title > avail then
                local maxScroll = #title - avail
                local pos = marqueePhase % (maxScroll + 4)
                local startIdx = math.min(maxScroll, pos) + 1
                title = title:sub(startIdx, startIdx + avail - 1)
            end
            setColors(term, pal.fg, pal.bg)
            term.setCursorPos(2, 5); term.write(title)

            local label, fg
            if not t.online then label, fg = "Offline", colors.red
            elseif s.state ~= "playing" then label, fg = "Idle", colors.lightGray
            elseif s.paused then label, fg = "Paused", colors.yellow
            else label, fg = "Playing", colors.lime end
            setColors(term, fg, pal.bg)
            term.setCursorPos(2, 6); term.write(label)

            local x = 2
            x = btn(8, x, " Restart ", colors.gray, colors.white, function() sendYouCubeRemote("restart") end)
            x = btn(8, x, s.paused and " Play " or " Pause ", s.paused and colors.green or colors.orange, colors.white, doPause)
            btn(8, x, " Skip ", colors.gray, colors.white, function() sendYouCubeRemote("skip") end)

            local vol = s.volume or 100
            setColors(term, pal.fg, pal.bg)
            term.setCursorPos(2, 10); term.write(string.format("Volume: %d%%", vol))
            local barX, barW = 6, math.max(4, w - 12)
            btn(11, 2, "[-]", colors.gray, colors.white, function() stepVolume(-10) end)
            setColors(term, colors.white, colors.gray)
            term.setCursorPos(barX, 11); term.write(string.rep(" ", barW))
            setColors(term, colors.white, colors.lime)
            term.setCursorPos(barX, 11); term.write(string.rep(" ", math.floor(vol / 100 * barW + 0.5)))
            btns[#btns + 1] = { y = 11, x1 = barX, x2 = barX + barW - 1, bar = { x = barX, w = barW } }
            btn(11, barX + barW + 1, "[+]", colors.gray, colors.white, function() stepVolume(10) end)

            local cap = s.captured
            setColors(term, pal.fg, pal.bg)
            term.setCursorPos(2, 13); term.write("Send my keyboard:")
            btn(14, 2, cap and " ON  " or " OFF ", cap and colors.green or colors.red, colors.white, function() setCapture(not cap) end)
            if cap then
                setColors(term, colors.yellow, pal.bg)
                term.setCursorPos(9, 14); term.write("Esc = stop")
            end
        end

        setColors(term, pal.footerFg, pal.footerBg)
        term.setCursorPos(1, h); term.write(string.rep(" ", w)); term.setCursorPos(1, h)
        if captured() then
            term.write((" Keys go to the theater"):sub(1, w))
        else
            term.write((" Space Pause S Skip R Restart Tab Next Esc"):sub(1, w))
        end
        footerToast(w, h)
    end

    local SPECIAL_KEYS = { enter = true, backspace = true, tab = true, up = true, down = true,
        left = true, right = true, delete = true, home = true, ["end"] = true, pageUp = true, pageDown = true }

    local function leave()
        announce(false)
    end

    while true do
        draw()
        local ev, p1, p2, p3 = uiPull(REDRAW)
        if ev == "timer" and p1 == sessTimer then
            announce(true)
            sessTimer = os.startTimer(4)
        elseif ev == "key" then
            if captured() then
                if p1 == keys.escape then
                    setCapture(false)
                else
                    local name = keys.getName(p1)
                    if name and SPECIAL_KEYS[name] then
                        sendYouCubeRemote("keystroke", { key = name })
                    end
                end
            else
                if p1 == keys.escape or p1 == keys.y then
                    leave()
                    return
                elseif p1 == keys.space or p1 == keys.p then doPause()
                elseif p1 == keys.s or p1 == keys.d then sendYouCubeRemote("skip")
                elseif p1 == keys.r then sendYouCubeRemote("restart")
                elseif p1 == keys.tab then switchTheater(1)
                elseif p1 == keys.g then theatersScreen()
                elseif p1 == keys.minus then stepVolume(-10)
                elseif p1 == keys.equals then stepVolume(10)
                elseif p1 == keys.c or p1 == keys.k then setCapture(true)
                end
            end
        elseif ev == "char" then
            if captured() then
                sendYouCubeRemote("keystroke", { key = p1 })
            end
        elseif ev == "mouse_click" then
            for _, b in ipairs(btns) do
                if p3 == b.y and p2 >= b.x1 and p2 <= b.x2 then
                    if b.bar then
                        setVolume((p2 - b.bar.x + 1) / b.bar.w * 100)
                    else
                        b.fn()
                    end
                    break
                end
            end
        end
    end
end

-- Actions: one place for every keyboard shortcut, toolbar button and menu item -------

local function selectedRelay()
    local r = selectedRelayId and findRelayById(selectedRelayId)
    if not r then setToast("Select a relay first (tap its name)", "warn") end
    return r
end

local runAction

local function openMoreMenu()
    local r = selectedRelayId and findRelayById(selectedRelayId)
    local has = r ~= nil
    local items = {
        { label = "Pause / clear override", action = "pause", enabled = has },
        { label = "Pin / unpin", action = "pin", enabled = has },
        { label = "Move up", action = "moveup", enabled = has },
        { label = "Move down", action = "movedown", enabled = has },
        { label = "Delete relay", action = "delete", enabled = has },
        { label = "Theaters (YouCube)", action = "theaters" },
        { label = "YouCube remote", action = "youcube" },
        { label = "Display settings", action = "settings" },
        { label = "Cycle list style", action = "style" },
        { label = "Network", action = "network" },
    }
    if not isPocket then items[#items + 1] = { label = "Monitor scale", action = "scale" } end
    items[#items + 1] = { label = "Shortcuts / help", action = "help" }
    local title = r and ("MORE: " .. (r.name or "Relay")) or "MORE"
    local pick = menuScreen(title, items)
    if pick then runAction(pick) end
end

runAction = function(name)
    if name == "toggle" then
        local r = selectedRelay()
        if r then sendRelayCmd({ cmd = "toggle", id = r.id }) end
    elseif name == "add" then
        local fields = editRelayForm({})
        if fields then
            local res = sendRelayCmd({ cmd = "addRelay", data = fields })
            if not isPocket and type(res) == "table" then selectedRelayId = res.id end
        end
    elseif name == "edit" then
        local r = selectedRelay()
        if r then
            local fields = editRelayForm(r)
            if fields then sendRelayCmd({ cmd = "editRelay", id = r.id, data = fields }) end
        end
    elseif name == "triggers" then
        local r = selectedRelay()
        if r then
            local triggers = editTriggersForm(r)
            if triggers then sendRelayCmd({ cmd = "editTriggers", id = r.id, data = triggers }) end
        end
    elseif name == "pause" then
        local r = selectedRelay()
        if r then sendRelayCmd({ cmd = "setPaused", id = r.id }) end
    elseif name == "pin" then
        local r = selectedRelay()
        if r then sendRelayCmd({ cmd = "setPinned", id = r.id }) end
    elseif name == "moveup" then
        local r = selectedRelay()
        if r then sendRelayCmd({ cmd = "moveRelay", id = r.id, dir = -1 }) end
    elseif name == "movedown" then
        local r = selectedRelay()
        if r then sendRelayCmd({ cmd = "moveRelay", id = r.id, dir = 1 }) end
    elseif name == "delete" then
        local r = selectedRelay()
        if r and confirmDialog("DELETE RELAY", 'Delete "' .. tostring(r.name or "Relay") .. '"? This cannot be undone.') then
            sendRelayCmd({ cmd = "deleteRelay", id = r.id })
            selectedRelayId = nil
        end
    elseif name == "style" then
        if uiStyle == "compact" then uiStyle = "detailed"
        elseif uiStyle == "detailed" then uiStyle = "spacious"
        else uiStyle = "compact" end
        persistSettings()
    elseif name == "settings" then
        if editSettingsForm() then persistSettings() end
    elseif name == "network" then
        if editNetworkForm() then
            ycList = { paired = {}, discovered = {} }
            selectedTheater = nil
            if isPocket then
                saveClientState()
                clientSayHello()
            else
                saveConfig()
            end
        end
    elseif name == "scale" then
        if isPocket then setToast("Monitor scale is a base setting", "warn") else cycleMonitorScale() end
    elseif name == "youcube" then
        youcubeRemoteUI()
    elseif name == "theaters" then
        theatersScreen()
    elseif name == "help" then
        showHelpScreen(term)
    elseif name == "menu" then
        openMoreMenu()
    end
end

local KEY_ACTIONS = {
    [keys.enter] = "toggle", [keys.space] = "toggle",
    [keys.a] = "add", [keys.e] = "edit", [keys.t] = "triggers",
    [keys.p] = "pause", [keys.d] = "delete", [keys.n] = "pin",
    [keys.comma] = "moveup", [keys.period] = "movedown",
    [keys.v] = "style", [keys.c] = "settings", [keys.w] = "network",
    [keys.h] = "help", [keys.s] = "scale", [keys.y] = "youcube", [keys.g] = "theaters", [keys.m] = "menu",
}

-- Handles a click inside the relay list area of the main terminal.
-- Tapping the ON/OFF pill toggles; tapping a name selects (so Edit/Trig/More apply to it).
local function handleListClick(x, y, w, h, rowMap, contentStartY, toolbarHits)
    if y == h then
        for _, hit in ipairs(toolbarHits or {}) do
            if x >= hit.x1 and x <= hit.x2 then
                runAction(hit.action)
                return
            end
        end
        return
    end
    if x == w then
        if y == contentStartY then scrollOffset = math.max(0, scrollOffset - 1)
        elseif y == h - 1 then scrollOffset = scrollOffset + 1 end
        return
    end
    local id = rowMap[y]
    if not id then return end
    selectedRelayId = id
    if x <= 7 then sendRelayCmd({ cmd = "toggle", id = id }) end
end

-- ===========================================================================
-- Base Station Engine
-- ===========================================================================

local function hostNetwork(msg)
    if hostExec(msg) then return end
    local c = msg.cmd
    if c == "get" then
        broadcastSync()
        refreshTheaters(true)
    elseif c == "location" then
        lastPlayerPos = { x = msg.x, y = msg.y, z = msg.z }
        lastGPSFixTime = os.clock()
        evaluateAutomations()
    elseif c == "hello" and msg.clientId then
        if baseClientSettings[msg.clientId] then
            send({ cmd = "clientConfig", clientId = msg.clientId, data = baseClientSettings[msg.clientId] })
        elseif msg.settings then
            baseClientSettings[msg.clientId] = msg.settings
            saveConfig()
        end
        broadcastSync()
        refreshTheaters(true)
    elseif c == "setClientConfig" and msg.clientId and msg.data then
        baseClientSettings[msg.clientId] = msg.data
        saveConfig()
    elseif c == "yc_beacon" and msg.tid then
        -- An unpaired theater announcing itself
        local d = discovered[msg.tid]
        discovered[msg.tid] = { name = tostring(msg.name or "Theater"):sub(1, 24), nonce = tostring(msg.nonce or ""), seen = os.clock() }
        if not d then refreshTheaters() end
    elseif c == "yc_status" then
        hostYcStatus(msg)
    elseif c == "yc_relay" then
        hostYcRelay(msg)
    elseif c == "yc_pair_result" and msg.tid then
        hostPairResult(msg)
    elseif c == "yc_pair_req" and msg.tid and msg.code then
        hostPairRequest(msg.tid, tostring(msg.code), msg.by)
    elseif c == "yc_remote" and msg.tid and msg.action then
        hostYcCommand(msg.tid, msg.action, type(msg.p) == "table" and msg.p or {})
    elseif c == "yc_unpair" and msg.tid then
        hostUnpairTheater(msg.tid)
    elseif c == "yc_rename" and msg.tid then
        hostRenameTheater(msg.tid, msg.name)
    end
end

local function runHost()
    loadConfig()
    tuneToNetwork(networkName)
    local clockTimer = os.startTimer(1.0)
    local marqueeTimer = os.startTimer(MARQUEE_INTERVAL)

    -- Timers, redstone and network traffic: also used while a form/menu is open
    local function background(ev, p1, p2, p3, msg)
        if ev == "timer" then
            if p1 == clockTimer then
                evaluateAutomations()
                theaterTick()
                clockTimer = os.startTimer(1.0)
            elseif p1 == marqueeTimer then
                marqueePhase = marqueePhase + 1
                marqueeTimer = os.startTimer(MARQUEE_INTERVAL)
            elseif activePulses[p1] then
                local info = activePulses[p1]
                local r = findRelayById(info.id)
                if r then
                    r.state = info.targetState
                    commit()
                end
                activePulses[p1] = nil
            end
            return true
        elseif ev == "redstone" then
            evaluateAutomations()
            return true
        elseif ev == "modem_message" then
            if type(msg) == "table" then hostNetwork(msg) end
            return true
        end
        return false
    end
    backgroundHandler = background

    while true do
        local tw, th = term.getSize()
        local termRowMap, newOffset, termHits, termStartY =
            drawUI(term, selectedRelayId, scrollOffset, currentToast(), nil, true)
        scrollOffset = newOffset

        local mon = peripheral.find("monitor")
        local monRowMap, monStartY = {}, 2
        if mon then
            mon.setTextScale(monitorScale)
            local _o, _h
            monRowMap, _o, _h, monStartY = drawUI(mon, nil, scrollOffset)
        end

        local ev, p1, p2, p3, msg = os.pullEvent()

        if background(ev, p1, p2, p3, msg) then
            -- handled
        elseif ev == "key" then
            if p1 == keys.up then
                moveSelection(-1)
            elseif p1 == keys.down then
                moveSelection(1)
            elseif KEY_ACTIONS[p1] then
                runAction(KEY_ACTIONS[p1])
            end
        elseif ev == "mouse_scroll" then
            scrollOffset = math.max(0, scrollOffset + p1)
        elseif ev == "mouse_click" then
            handleListClick(p2, p3, tw, th, termRowMap, termStartY, termHits)
        elseif ev == "monitor_touch" and mon then
            -- Monitors have no selection or toolbar: any tap on a row toggles it
            local mw, mh = mon.getSize()
            if p2 == mw then
                if p3 == monStartY then scrollOffset = math.max(0, scrollOffset - 1)
                elseif p3 == mh - 1 then scrollOffset = scrollOffset + 1 end
            else
                local clickedId = monRowMap[p3]
                if clickedId then
                    selectedRelayId = clickedId
                    hostToggle(clickedId)
                end
            end
        end
    end
end

-- ===========================================================================
-- Pocket Client Engine (UI and GPS run in parallel threads)
-- ===========================================================================

local function runClient()
    loadClientState()
    tuneToNetwork(networkName)
    if term.setTextScale then pcall(term.setTextScale, textSize) end
    clientSayHello()

    local function clientUIThread()
        local heartbeatTimer = os.startTimer(5.0)
        local marqueeTimer = os.startTimer(MARQUEE_INTERVAL)

        -- Timers and base traffic: also used while a form/menu is open
        local function background(ev, p1, p2, p3, msg)
            if ev == "timer" then
                if p1 == heartbeatTimer then
                    send({ cmd = "get" })
                    heartbeatTimer = os.startTimer(5.0)
                elseif p1 == marqueeTimer then
                    marqueePhase = marqueePhase + 1
                    marqueeTimer = os.startTimer(MARQUEE_INTERVAL)
                end
                return true
            elseif ev == "modem_message" then
                if type(msg) == "table" then
                    if msg.cmd == "sync" then
                        relays = msg.data or {}
                        lastSyncTime = os.clock()
                        hasEverSynced = true
                        saveClientState()
                    elseif msg.cmd == "clientConfig" and msg.clientId == clientId then
                        applyReceivedClientConfig(msg.data)
                    elseif msg.cmd == "yc_theaters" then
                        ycList = { paired = msg.paired or {}, discovered = msg.discovered or {} }
                    elseif msg.cmd == "yc_event" then
                        local online = (msg.kind == "online")
                        setToast(tostring(msg.name) .. (online and " connected" or " disconnected"), online and "ok" or "warn")
                    elseif msg.cmd == "yc_pair_done" and msg.by == clientId then
                        if msg.ok then setToast("Paired " .. tostring(msg.name or "theater"), "ok")
                        else setToast("Pairing failed: " .. tostring(msg.reason or "unknown"), "warn") end
                    end
                end
                return true
            end
            return false
        end
        backgroundHandler = background

        while true do
            local w, h = term.getSize()
            local banner = currentToast() or clientBanner()
            local emptyMsg = (not hasEverSynced) and "Waiting for base station..." or nil
            local termRowMap, newOffset, hits, startY = drawUI(term, selectedRelayId, scrollOffset, banner, emptyMsg, true)
            scrollOffset = newOffset

            local ev, p1, p2, p3, msg = os.pullEvent()

            if background(ev, p1, p2, p3, msg) then
                -- handled
            elseif ev == "key" then
                if p1 == keys.up then
                    moveSelection(-1)
                elseif p1 == keys.down then
                    moveSelection(1)
                elseif KEY_ACTIONS[p1] and KEY_ACTIONS[p1] ~= "scale" then
                    runAction(KEY_ACTIONS[p1])
                end
            elseif ev == "mouse_scroll" then
                scrollOffset = math.max(0, scrollOffset + p1)
            elseif ev == "mouse_click" then
                handleListClick(p2, p3, w, h, termRowMap, startY, hits)
            end
        end
    end

    local function clientGPSThread()
        local gpsTimer = os.startTimer(0.5)

        while true do
            local ev, p1 = os.pullEvent()
            if ev == "timer" and p1 == gpsTimer then
                local x, y, z = gps.locate(0.2)
                local delay = 2.0
                if x then
                    lastPlayerPos = { x = x, y = y, z = z }
                    lastGPSFixTime = os.clock()
                    send({ cmd = "location", x = x, y = y, z = z })
                    delay = getDynamicGPSInterval(x, y, z)
                end
                gpsTimer = os.startTimer(delay)
            end
        end
    end

    parallel.waitForAny(clientUIThread, clientGPSThread)
end

if isPocket then runClient() else runHost() end
