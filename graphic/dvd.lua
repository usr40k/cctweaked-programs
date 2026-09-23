-- CC: Tweaked Classic Text DVD Bouncer for Monitor
local targetMonitor = "monitor_5"
local monitor = peripheral.wrap(targetMonitor)

if not monitor then
    error("Monitor not found: " .. targetMonitor)
end

-- Set text scale to 1.0
monitor.setTextScale(1.0)

local logo = "DVD"
local logoH = 1
local logoW = string.len(logo)

-- Color cycling list for wall bounces
local possibleColors = {
    colors.red, colors.orange, colors.yellow, colors.lime, 
    colors.cyan, colors.lightBlue, colors.purple, colors.pink
}
local currentColorIdx = 1

local screenW, screenH = monitor.getSize()
local x = math.random(1, math.max(1, screenW - logoW + 1))
local y = math.random(1, math.max(1, screenH - logoH + 1))

local dx = 1
local dy = 1

local function changeColor()
    currentColorIdx = (currentColorIdx % #possibleColors) + 1
end

while true do
    screenW, screenH = monitor.getSize()

    x = x + dx
    y = y + dy

    local hit = false

    if x < 1 then
        x = 1
        dx = -dx
        hit = true
    elseif x + logoW - 1 > screenW then
        x = screenW - logoW + 1
        dx = -dx
        hit = true
    end

    if y < 1 then
        y = 1
        dy = -dy
        hit = true
    elseif y + logoH - 1 > screenH then
        y = screenH - logoH + 1
        dy = -dy
        hit = true
    end

    if hit then
        changeColor()
    end

    local oldTerm = term.redirect(monitor)
    monitor.setBackgroundColor(colors.black)
    monitor.clear()

    monitor.setCursorPos(math.floor(x), math.floor(y))
    monitor.setTextColor(possibleColors[currentColorIdx])
    monitor.write(logo)

    term.redirect(oldTerm)
    
    sleep(0.1)
end
