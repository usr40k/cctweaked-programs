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
        local isWarn = (banner.level == "warn")
        setColors(target, isWarn and colors.white or colors.black, isWarn and colors.red or colors.yellow)
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

local function hostSetState(idOrName, state)
    local r = nil
    -- Try numeric ID first
    if type(idOrName) == "number" then
        r = findRelayById(idOrName)
    end
    -- Fall back to matching by relayName (peripheral name)
    if not r then
        for _, candidate in ipairs(relays) do
            if candidate.relayName == tostring(idOrName) then
                r = candidate
                break
            end
        end
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
    elseif c == "setState" and msg.id ~= nil and msg.state ~= nil then hostSetState(msg.id, msg.state)
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

-- YouCube player state, learned from the player's "youcube_status" broadcasts
-- (received by both base and pocket).
local ycStatus = nil -- { title, state, paused, volume(0-100), captured, seen }
local YC_STALE_AFTER = 8

local function noteYouCubeStatus(msg)
    ycStatus = {
        title = tostring(msg.title or ""),
        state = msg.state or "idle",
        paused = msg.paused and true or false,
        volume = tonumber(msg.volume) or 100,
        captured = msg.captured and true or false,
        seen = os.clock(),
    }
end

local remoteSeq = 0
local function sendYouCubeRemote(action, payload)
    remoteSeq = remoteSeq + 1
    local msg = {
        cmd = "youcube_remote", action = action,
        rid = tostring(os.getComputerID()) .. ":" .. tostring(os.epoch and os.epoch("utc") or os.time()) .. ":" .. remoteSeq,
    }
    if payload then
        for k, v in pairs(payload) do msg[k] = v end
    end
    send(msg)
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

-- YouCube remote screen -----------------------------------------------------

local function youcubeRemoteUI()
    local w, h = term.getSize()
    local btns = {}

    local function online() return ycStatus and (os.clock() - ycStatus.seen) < YC_STALE_AFTER end
    local function captured() return ycStatus and ycStatus.captured end

    local function setCapture(on)
        sendYouCubeRemote("capture_toggle", { captured = on })
        if ycStatus then ycStatus.captured = on end
    end
    local function doPause()
        local payload = nil
        if ycStatus then payload = { paused = not ycStatus.paused } end
        sendYouCubeRemote("play_pause", payload)
    end
    local function setVolume(pct)
        pct = math.max(0, math.min(100, math.floor(pct + 0.5)))
        sendYouCubeRemote("volume_set", { volume = pct })
        if ycStatus then ycStatus.volume = pct end
    end
    local function stepVolume(d)
        setVolume(((ycStatus and ycStatus.volume) or 100) + d)
    end

    -- Ask the player to report right away (it also reports every few seconds)
    sendYouCubeRemote("status_request")

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

        -- Now playing
        setColors(term, pal.accentFg, pal.bg)
        term.setCursorPos(2, 3)
        term.write(("Now playing:"):sub(1, w - 2))
        local title = (ycStatus and ycStatus.title ~= "") and ycStatus.title or "-"
        local avail = w - 2
        if #title > avail then
            local maxScroll = #title - avail
            local pos = marqueePhase % (maxScroll + 4)
            local startIdx = math.min(maxScroll, pos) + 1
            title = title:sub(startIdx, startIdx + avail - 1)
        end
        setColors(term, pal.fg, pal.bg)
        term.setCursorPos(2, 4)
        term.write(title)

        local label, fg
        if not ycStatus then
            label, fg = "No player heard yet", colors.red
        elseif not online() then
            label, fg = "Player offline (" .. math.floor(os.clock() - ycStatus.seen) .. "s)", colors.red
        elseif ycStatus.state == "idle" then
            label, fg = "Idle", colors.lightGray
        elseif ycStatus.paused then
            label, fg = "Paused", colors.yellow
        else
            label, fg = "Playing", colors.lime
        end
        setColors(term, fg, pal.bg)
        term.setCursorPos(2, 5)
        term.write(label:sub(1, w - 2))

        -- Transport
        local paused = ycStatus and ycStatus.paused
        local x = 2
        x = btn(7, x, " Restart ", colors.gray, colors.white, function() sendYouCubeRemote("restart") end)
        x = btn(7, x, paused and " Play " or " Pause ", paused and colors.green or colors.orange, colors.white, doPause)
        btn(7, x, " Skip ", colors.gray, colors.white, function() sendYouCubeRemote("skip") end)

        -- Volume
        local vol = (ycStatus and ycStatus.volume) or 100
        setColors(term, pal.fg, pal.bg)
        term.setCursorPos(2, 9)
        term.write(string.format("Volume: %d%%", vol))
        local barX, barW = 6, math.max(4, w - 12)
        btn(10, 2, "[-]", colors.gray, colors.white, function() stepVolume(-10) end)
        setColors(term, colors.white, colors.gray)
        term.setCursorPos(barX, 10)
        term.write(string.rep(" ", barW))
        local filled = math.floor(vol / 100 * barW + 0.5)
        setColors(term, colors.white, colors.lime)
        term.setCursorPos(barX, 10)
        term.write(string.rep(" ", filled))
        btns[#btns + 1] = { y = 10, x1 = barX, x2 = barX + barW - 1, bar = { x = barX, w = barW } }
        btn(10, barX + barW + 1, "[+]", colors.gray, colors.white, function() stepVolume(10) end)

        -- Keyboard capture
        local cap = captured()
        setColors(term, pal.fg, pal.bg)
        term.setCursorPos(2, 12)
        term.write("Send my keyboard:")
        btn(13, 2, cap and " ON  " or " OFF ", cap and colors.green or colors.red, colors.white, function() setCapture(not cap) end)
        if cap then
            setColors(term, colors.yellow, pal.bg)
            term.setCursorPos(9, 13)
            term.write("Esc = stop")
        end

        setColors(term, pal.footerFg, pal.footerBg)
        term.setCursorPos(1, h); term.write(string.rep(" ", w)); term.setCursorPos(1, h)
        if cap then
            term.write((" Keys go to the player"):sub(1, w))
        else
            term.write((" Space Pause  S Skip  R Restart  Esc Back"):sub(1, w))
        end
    end

    local REDRAW = { timer = true, modem_message = true }
    local SPECIAL_KEYS = { enter = true, backspace = true, tab = true, up = true, down = true,
        left = true, right = true, delete = true, home = true, ["end"] = true, pageUp = true, pageDown = true }

    while true do
        draw()
        local ev, p1, p2, p3 = uiPull(REDRAW)
        if ev == "key" then
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
                    return
                elseif p1 == keys.space or p1 == keys.p then doPause()
                elseif p1 == keys.s or p1 == keys.d then sendYouCubeRemote("skip")
                elseif p1 == keys.r then sendYouCubeRemote("restart")
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
            ycStatus = nil
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
    [keys.h] = "help", [keys.s] = "scale", [keys.y] = "youcube", [keys.m] = "menu",
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
    elseif c == "setClientConfig" and msg.clientId and msg.data then
        baseClientSettings[msg.clientId] = msg.data
        saveConfig()
    elseif c == "youcube_remote" and not msg.fwd then
        -- Range extender: re-send once so the player hears pockets that are
        -- out of its range. The player drops duplicates by rid.
        msg.fwd = true
        send(msg)
    elseif c == "youcube_status" then
        noteYouCubeStatus(msg)
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
                    elseif msg.cmd == "youcube_status" then
                        noteYouCubeStatus(msg)
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
