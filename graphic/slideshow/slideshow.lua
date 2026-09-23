-- CC: Tweaked NFP Slideshow Program with Auto-Discovery, Network Monitor, and Auto-Scaling
local targetMonitor = "monitor_5" -- Can be a peripheral name ("monitor_5") or a side ("right")
local monitor = peripheral.wrap(targetMonitor)

if not monitor then
    error("Monitor not found: " .. targetMonitor)
end

-- Set text scale to 0.5 for high-density display
monitor.setTextScale(0.5)

local targetDir = "nfp"
local delay = 3 -- Seconds to display each image

local function getSlides()
    local slides = {}
    if fs.exists(targetDir) and fs.isDir(targetDir) then
        local files = fs.list(targetDir)
        for _, file in ipairs(files) do
            local fullPath = fs.combine(targetDir, file)
            if not fs.isDir(fullPath) and file:sub(-4):lower() == ".nfp" then
                table.insert(slides, fullPath)
            end
        end
    end
    table.sort(slides)
    return slides
end

-- Simple nearest-neighbor image scaling function
local function scaleImage(img, targetW, targetH)
    local srcH = #img
    local srcW = #img[1]
    
    local scaled = {}
    for y = 1, targetH do
        scaled[y] = {}
        local srcY = math.floor((y - 1) * srcH / targetH) + 1
        for x = 1, targetW do
            local srcX = math.floor((x - 1) * srcW / targetW) + 1
            scaled[y][x] = img[srcY][srcX]
        end
    end
    return scaled
end

while true do
    local slides = getSlides()
    
    if #slides == 0 then
        print("No .nfp files found in /" .. targetDir .. "/ directory. Waiting...")
        sleep(5)
    else
        -- Dynamically fetch monitor dimensions (expanded due to 0.5 text scale)
        local screenW, screenH = monitor.getSize()
        
        for _, path in ipairs(slides) do
            local img = paintutils.loadImage(path)
            if img then
                -- Resize image to fit the current monitor resolution
                local scaledImg = scaleImage(img, screenW, screenH)
                
                local oldTerm = term.redirect(monitor)
                monitor.clear()
                paintutils.drawImage(scaledImg, 1, 1)
                term.redirect(oldTerm)
            else
                print("Failed to parse NFP file: " .. path)
            end
            sleep(delay)
        end
    end
end
