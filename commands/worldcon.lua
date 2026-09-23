-- CC: Tweaked Sky & World Controller (Command Computer)

local mon = peripheral.find("monitor")
if not mon or not mon.isColor() then
    error("Please attach an Advanced Monitor to run this program.")
end

if not commands then
    error("This program must be run on a Command Computer.")
end

----------------------------------------------------
-- 1. HELPER & WORLD QUERY FUNCTIONS
----------------------------------------------------
local function getRealWeather()
    local okT, successT = pcall(commands.exec, 'execute if predicate {"condition":"minecraft:weather_check","thundering":true}')
    if okT and successT then
        return "Storm"
    end

    local okR, successR = pcall(commands.exec, 'execute if predicate {"condition":"minecraft:weather_check","raining":true}')
    if okR and successR then
        return "Rain"
    end

    return "Clear"
end

----------------------------------------------------
-- 2. STARTUP SELF-TEST (Runs on Computer Screen)
----------------------------------------------------
term.clear()
term.setCursorPos(1, 1)
term.setTextColor(colors.yellow)
print("====================================")
print("   SKY & WORLD CONTROLLER SELF-TEST  ")
print("====================================")
term.setTextColor(colors.white)

-- Test 1: Monitor Peripheral
write("[TEST 1/3] Checking Monitor... ")
if mon and mon.isColor() then
    term.setTextColor(colors.green)
    print("OK")
    term.setTextColor(colors.white)
else
    term.setTextColor(colors.red)
    print("FAILED")
    error("Advanced Monitor not found or does not support color.")
end

-- Test 2: Command Computer API
write("[TEST 2/3] Checking Command API... ")
if commands then
    term.setTextColor(colors.green)
    print("OK")
    term.setTextColor(colors.white)
else
    term.setTextColor(colors.red)
    print("FAILED")
    error("This program must be run on a Command Computer.")
end

-- Test 3: World Query Capability
write("[TEST 3/3] Testing World Query... ")
local initialWeather = getRealWeather()
term.setTextColor(colors.green)
print("OK (" .. initialWeather .. ")")
term.setTextColor(colors.white)

print("------------------------------------")
term.setTextColor(colors.green)
print("Self-test complete! Starting system...")
term.setTextColor(colors.white)
sleep(1.2)

----------------------------------------------------
-- 3. MAIN APPLICATION SETUP
----------------------------------------------------
mon.setTextScale(0.5)
local w, h = mon.getSize()

-- Off-screen double buffer window
local canvas = window.create(mon, 1, 1, w, h, false)

-- Layout Dimensions
local leftW = 7      -- Left sidebar for Time Control buttons
local rightW = 12    -- Right sidebar for Weather buttons & Clock
local skyX1 = leftW + 1
local skyX2 = w - rightW
local skyW = skyX2 - skyX1 + 1
local horizonY = h - 2

-- State Variables
local displayTime = os.time()
local isEditing = false
local weather = initialWeather
local cmdQueue = {}

-- Stars Setup
math.randomseed(1337)
local stars = {}
for i = 1, math.floor(skyW * 0.8) do
    table.insert(stars, {
        x = math.random(skyX1, skyX2),
        y = math.random(1, horizonY - 1),
        brightness = math.random(1, 2)
    })
end

-- Weather Particles Setup
local particles = {}
for i = 1, 30 do
    table.insert(particles, {
        x = math.random(skyX1, skyX2),
        y = math.random(1, horizonY - 1),
        speed = math.random(1, 2)
    })
end

----------------------------------------------------
-- 4. COMMAND QUEUE & WORLD SYNC
----------------------------------------------------
local function queueCommand(cmd)
    table.insert(cmdQueue, cmd)
end

local function commandWorker()
    while true do
        if #cmdQueue > 0 then
            local cmd = table.remove(cmdQueue, 1)
            pcall(commands.exec, cmd)
        else
            os.sleep(0.05)
        end
    end
end

local function weatherSyncLoop()
    while true do
        sleep(2) -- Poll world weather every 2 seconds
        local realW = getRealWeather()
        
        if realW == "Storm" and weather ~= "Storm" then
            weather = "Storm"
        elseif realW == "Clear" and weather ~= "Clear" then
            weather = "Clear"
        elseif realW == "Rain" and weather ~= "Rain" and weather ~= "Snow" then
            weather = "Rain"
        end
    end
end

local function setWorldTime(hours)
    local ticks = math.floor(((hours - 6) % 24) * 1000)
    queueCommand("time set " .. ticks)
end

local function setWorldWeather(wType)
    local cmd = "weather clear"
    if wType == "Rain" or wType == "Snow" then
        cmd = "weather rain"
    elseif wType == "Storm" then
        cmd = "weather thunder"
    end
    queueCommand(cmd)
end

----------------------------------------------------
-- 5. RENDERING FUNCTIONS
----------------------------------------------------
local function getSkyColor(t)
    if t >= 5 and t < 7 then
        return colors.orange       -- Dawn (5:00 - 7:00)
    elseif t >= 7 and t < 17 then
        return colors.lightBlue    -- Daytime (7:00 - 17:00)
    elseif t >= 17 and t < 19 then
        return colors.magenta      -- Dusk (17:00 - 19:00)
    else
        return colors.black        -- Night (19:00 - 5:00)
    end
end

-- Calculates position based on Minecraft's ~14h daytime arc (5:00 AM to 7:00 PM)
local function getPositions(t)
    local angle = ((t - 5) / 14) * math.pi
    local rx = (skyW / 2) - 3
    local ry = horizonY - 4
    local cx = skyX1 + (skyW / 2) - 1
    local cy = horizonY

    local sx = cx - rx * math.cos(angle)
    local sy = cy - ry * math.sin(angle)

    local mx = cx - rx * math.cos(angle + math.pi)
    local my = cy - ry * math.sin(angle + math.pi)

    return math.floor(sx + 0.5), math.floor(sy + 0.5), math.floor(mx + 0.5), math.floor(my + 0.5)
end

-- Renders larger 5x3 celestial bodies centered at (cx, cy)
local function drawSprite(cx, cy, bgCol)
    local width = 5
    local height = 3
    local startX = cx - math.floor(width / 2)
    local startY = cy - math.floor(height / 2)

    for dx = 0, width - 1 do
        for dy = 0, height - 1 do
            local px, py = startX + dx, startY + dy
            if px >= skyX1 and px <= skyX2 and py >= 1 and py < horizonY then
                canvas.setCursorPos(px, py)
                canvas.setBackgroundColor(bgCol)
                canvas.write(" ")
            end
        end
    end
end

local function draw()
    canvas.setBackgroundColor(colors.black)
    canvas.clear()

    local skyColor = getSkyColor(displayTime)

    -- 1. Sky Area
    for y = 1, horizonY - 1 do
        canvas.setCursorPos(skyX1, y)
        canvas.setBackgroundColor(skyColor)
        canvas.write(string.rep(" ", skyW))
    end

    -- 2. Stars
    if skyColor == colors.black or skyColor == colors.magenta then
        canvas.setTextColor(colors.white)
        canvas.setBackgroundColor(skyColor)
        for _, star in ipairs(stars) do
            canvas.setCursorPos(star.x, star.y)
            canvas.write(star.brightness == 1 and "." or "+")
        end
    end

    -- 3. Sun and Moon Sprites
    local sx, sy, mx, my = getPositions(displayTime)
    drawSprite(sx, sy, colors.yellow)
    drawSprite(mx, my, colors.white)

    -- 4. Weather Particles
    if weather ~= "Clear" then
        canvas.setBackgroundColor(skyColor)
        for _, p in ipairs(particles) do
            if p.y < horizonY then
                canvas.setCursorPos(p.x, p.y)
                if weather == "Rain" then
                    canvas.setTextColor(colors.cyan)
                    canvas.write("|")
                elseif weather == "Snow" then
                    canvas.setTextColor(colors.white)
                    canvas.write("*")
                elseif weather == "Storm" then
                    local isFlash = math.random() > 0.85
                    canvas.setTextColor(isFlash and colors.yellow or colors.blue)
                    canvas.write(isFlash and "/" or "|")
                end
            end
        end
    end

    -- 5. Ground Line
    for y = horizonY, h do
        canvas.setCursorPos(skyX1, y)
        canvas.setBackgroundColor(colors.green)
        canvas.write(string.rep(" ", skyW))
    end

    -- 6. LEFT SIDEBAR: Time Buttons (<, SET, >)
    local btnH = h / 3
    local timeBtns = {
        { label = " < ", col = colors.gray, fg = colors.white },
        { label = "SET", col = isEditing and colors.green or colors.lightGray, fg = isEditing and colors.white or colors.black },
        { label = " > ", col = colors.gray, fg = colors.white }
    }

    for i, btn in ipairs(timeBtns) do
        local startY = math.floor((i - 1) * btnH) + 1
        local endY = math.floor(i * btnH)
        if i == 3 then endY = h end

        for y = startY, endY do
            canvas.setCursorPos(1, y)
            canvas.setBackgroundColor(btn.col)
            canvas.setTextColor(btn.fg)
            
            local midY = math.floor((startY + endY) / 2)
            if y == midY then
                local pad = math.floor((leftW - #btn.label) / 2)
                canvas.write(string.rep(" ", pad) .. btn.label .. string.rep(" ", leftW - #btn.label - pad))
            else
                canvas.write(string.rep(" ", leftW))
            end
        end
    end

    -- 7. RIGHT SIDEBAR: Clock + Weather Buttons
    local sbX = skyX2 + 1
    local timeH = 3

    local timeStr = string.format("%02d:%02d", math.floor(displayTime) % 24, math.floor((displayTime % 1) * 60))
    if isEditing then
        timeStr = "*" .. timeStr .. "*"
    end

    for y = 1, timeH do
        canvas.setCursorPos(sbX, y)
        canvas.setBackgroundColor(colors.black)
        canvas.setTextColor(isEditing and colors.orange or colors.yellow)
        if y == 2 then
            local pad = math.floor((rightW - #timeStr) / 2)
            canvas.write(string.rep(" ", pad) .. timeStr .. string.rep(" ", rightW - #timeStr - pad))
        else
            canvas.write(string.rep(" ", rightW))
        end
    end

    local weatherList = {
        { name = "Clear", color = colors.lime },
        { name = "Rain", color = colors.lightBlue },
        { name = "Snow", color = colors.white },
        { name = "Storm", color = colors.purple }
    }

    local remHeight = h - timeH
    local wBtnH = remHeight / #weatherList

    for i, wItem in ipairs(weatherList) do
        local startY = timeH + math.floor((i - 1) * wBtnH) + 1
        local endY = timeH + math.floor(i * wBtnH)
        if i == #weatherList then endY = h end

        local isActive = (weather == wItem.name)
        local bgColor = isActive and wItem.color or colors.gray
        local fgColor = isActive and colors.black or colors.white

        for y = startY, endY do
            canvas.setCursorPos(sbX, y)
            canvas.setBackgroundColor(bgColor)
            canvas.setTextColor(fgColor)
            
            local midY = math.floor((startY + endY) / 2)
            if y == midY then
                local label = wItem.name
                local pad = math.floor((rightW - #label) / 2)
                canvas.write(string.rep(" ", pad) .. label .. string.rep(" ", rightW - #label - pad))
            else
                canvas.write(string.rep(" ", rightW))
            end
        end
    end

    canvas.setVisible(true)
    canvas.setVisible(false)
end

----------------------------------------------------
-- 6. EVENT HANDLERS & PARALLEL LOOPS
----------------------------------------------------
local function handleInput(x, y)
    -- Left Sidebar Controls
    if x <= leftW then
        local btnH = h / 3
        local idx = math.floor((y - 1) / btnH) + 1
        idx = math.max(1, math.min(3, idx))

        if idx == 1 then
            isEditing = true
            displayTime = (displayTime - 1) % 24
        elseif idx == 2 then
            if isEditing then
                setWorldTime(displayTime)
                isEditing = false
            end
        elseif idx == 3 then
            isEditing = true
            displayTime = (displayTime + 1) % 24
        end
        return
    end

    -- Right Sidebar Controls
    if x > skyX2 then
        local timeH = 3
        if y > timeH then
            local remHeight = h - timeH
            local wBtnH = remHeight / 4
            local idx = math.floor((y - timeH - 1) / wBtnH) + 1
            idx = math.max(1, math.min(4, idx))
            
            local weatherList = {"Clear", "Rain", "Snow", "Storm"}
            weather = weatherList[idx]
            setWorldWeather(weather)
        end
        return
    end
end

local function uiLoop()
    local mainTimer = os.startTimer(0.05)

    while true do
        local event, p1, p2, p3 = os.pullEvent()

        if event == "timer" and p1 == mainTimer then
            if not isEditing then
                displayTime = os.time()
            end

            for _, p in ipairs(particles) do
                p.y = p.y + p.speed
                if p.y >= horizonY then
                    p.y = 1
                    p.x = math.random(skyX1, skyX2)
                end
            end

            draw()
            mainTimer = os.startTimer(0.05)

        elseif event == "monitor_touch" then
            handleInput(p2, p3)
        end
    end
end

parallel.waitForAny(uiLoop, commandWorker, weatherSyncLoop)
