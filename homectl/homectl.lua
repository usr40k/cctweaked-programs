local configFile = "devices.cfg"
local winWidth, winHeight = term.getSize()
local tmpClientFile = "client_gen.lua"

-- Load devices
local devices = {}
if fs.exists(configFile) then
  local f = fs.open(configFile, "r")
  local data = textutils.unserialize(f.readAll())
  f.close()
  if type(data) == "table" then devices = data end
end
if #devices == 0 then
  devices = {
    { channel = 1, name = "DEMO", status = "[?]", gateway = false },
  }
end

-- Save config
local function saveConfig()
  local f = fs.open(configFile, "w")
  f.write(textutils.serialize(devices))
  f.close()
end

local function generateClient()
  local tmpClientFile = "client_gen.lua"

  shell.run("wget https://raw.githubusercontent.com/usr40k/cctweaked-programs/main/homectl/config_gen.lua config_gen.lua")
  shell.run("wget https://raw.githubusercontent.com/usr40k/cctweaked-programs/main/homectl/client_base.lua client_base.lua")

  shell.run("config_gen.lua")

  print("Uploading client to Pastebin...")
  shell.run("pastebin put " .. tmpClientFile)
  print("make note of this and press enter")
  read()

  write("Add this device to controller config? (y/n): ")
  local ans = read()
  if ans == "y" then
    write("Enter a name for this device: ")
    local name = read()

    local gatewayFlag = false
    if fs.exists("last_gateway.txt") then
      local fgw = fs.open("last_gateway.txt", "r")
      gatewayFlag = (fgw.readAll() == "1")
      fgw.close()
    end

    local channel = 0
    if not gatewayFlag then
      local f = fs.open("last_channel.txt", "r")
      channel = tonumber(f.readAll())
      f.close()
    else
      channel = 124 -- fixed gateway server channel
    end

    table.insert(devices, { channel = channel, name = name, status = "[?]", gateway = gatewayFlag })
    saveConfig()
    print("Device added to controller config.")
  end

  shell.run("rm config_gen.lua")
  shell.run("rm client_base.lua")
end

-- Open modem
local modem = peripheral.find("modem") or error("No modem found!")
for _, dev in ipairs(devices) do modem.open(dev.channel) end

local password = "superSecret123" -- must match gateway server

-- Async status request
local pending = {}
local function requestStatus()
  pending = {}
  for _, dev in ipairs(devices) do
    if dev.gateway then
      modem.transmit(dev.channel, dev.channel, { password = password, cmd = "status" })
    else
      modem.transmit(dev.channel, dev.channel, "status")
    end
    pending[dev.channel] = { dev = dev, timeout = os.clock() + 5 }
    dev.status = "[...]"
  end
end

-- Handle modem responses
local function handleEvents()
  while true do
    local event, p1, p2, p3, p4 = os.pullEvent()
    if event == "modem_message" then
      local side, ch, reply, msg = p1, p2, p3, p4
      if pending[ch] then
        local dev = pending[ch].dev
        if type(msg) == "string" then
          dev.status = (msg == "ON") and "[ON ]" or (msg == "OFF" and "[OFF]" or "[ERR]")
        else
          dev.status = "[ERR]"
        end
        pending[ch] = nil
      end
    end
    -- timeouts
    local now = os.clock()
    for ch, info in pairs(pending) do
      if now > info.timeout then
        info.dev.status = "[ERR]"
        pending[ch] = nil
      end
    end
  end
end

-- Config editor
local function editConfig()
  while true do
    term.clear()
    print("=== Config Editor ===")
    for i, dev in ipairs(devices) do
      local tag = dev.gateway and " [GW]" or ""
      print(i .. ". " .. dev.name .. " (Channel " .. dev.channel .. ")" .. tag)
    end
    print("a=add, r=remove, m=move, q=quit")
    local choice = read()
    if choice == "q" then
      break
    elseif choice == "a" then
      generateClient()
    elseif choice == "r" then
      write("Index to remove: ")
      local idx = tonumber(read())
      if devices[idx] then table.remove(devices, idx) end
    elseif choice == "m" then
      write("Index to move: ")
      local idx = tonumber(read())
      write("New position: ")
      local pos = tonumber(read())
      if devices[idx] and pos >= 1 and pos <= #devices then
        local dev = table.remove(devices, idx)
        table.insert(devices, pos, dev)
      end
    end
    saveConfig()
  end
end

-- UI loop
local currentIndex, cursor = 1, 1
local function mainUI()
  requestStatus()
  while true do
    term.clear()
    term.setCursorPos(1,1)
    for i=0, winHeight-1 do
      local idx = currentIndex+i
      if idx <= #devices then
        local dev = devices[idx]
        local tag = dev.gateway and " [GW]" or ""
        local line = dev.status.." "..dev.name..tag
        if cursor == i+1 then write("-> "..line) else write(line) end
        term.setCursorPos(1,i+2)
      end
    end

    local event, p1 = os.pullEvent()
    if event == "key" then
      local key = p1
      if key == keys.enter then
        local dev = devices[currentIndex+cursor-1]
        if dev then
          local cmd = (dev.status=="[ON ]") and "off" or "on"
          if dev.gateway then
            modem.transmit(dev.channel, dev.channel, { password = password, cmd = cmd })
          else
            modem.transmit(dev.channel, dev.channel, cmd)
          end
          os.sleep(0.5)
          requestStatus()
        end
      elseif key == keys.c then
        editConfig()
        requestStatus()
      elseif key == keys.r then
        requestStatus()
      elseif key == keys.q then
        break
      elseif key == keys.up then
        if cursor>1 then cursor=cursor-1 elseif currentIndex>1 then currentIndex=currentIndex-1 end
      elseif key == keys.down then
        if cursor<winHeight-1 and cursor<#devices-currentIndex+1 then cursor=cursor+1
        elseif currentIndex+winHeight-1<#devices then currentIndex=currentIndex+1 end
      end
    end
  end
end

parallel.waitForAny(handleEvents, mainUI)
