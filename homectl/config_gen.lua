-- homectl/config_gen.lua

write("Generate gateway server? (y/n): ")
local makeGatewayServer = (read() == "y")

if makeGatewayServer then
  -- Prompt for gateway server settings
  write("Listen channel: ") local listenChannel = tonumber(read())
  write("Password: ") local password = read()
  write("Wireless modem side: ") local wirelessModemSide = read()
  write("Wired modem side: ") local wiredModemSide = read()

  -- Build config block
  local configBlock = string.format([[
-- Gateway Server Configuration
local listenChannel = %d
local password = "%s"
local wirelessModemSide = "%s"
local wiredModemSide = "%s"
]], listenChannel, password, wirelessModemSide, wiredModemSide)

  -- Gateway server base code
  shell.run("wget https://raw.githubusercontent.com/usr40k/cctweaked-programs/main/homectl/gateway_server_base.lua gateway_server_base.lua")
  local f2 = fs.open("gateway_server_base.lua", "r")
  serverBase = f2.readAll()
  f2.close()
  shell.run("rm gateway_server_base.lua")


  -- Write gateway_server.lua as client_gen.lua
  local out = fs.open("client_gen.lua", "w")
  out.write(configBlock .. "\n" .. serverBase)
  out.close()

  print("Gateway server generated as client_gen.lua")
else
  -- Normal client generation path (your existing code)
  write("Modem side: ") local modemSide = read()
  write("Redstone output side: ") local redstoneSide = read()
  write("Redstone input side: ") local inputSide = read()
  write("Channel number: ") local channel = tonumber(read())
  write("Default value (on/off/none): ") local defaultValue = read()
  write("Mode (1=normal,2=pulse,3=invert): ") local mode = tonumber(read())

  -- Ask about monitor
  write("Use monitor display? (y/n): ") local useMonitor = read()
  local monitorName = nil
  if useMonitor == "y" then
    write("Enter monitor peripheral name (e.g. monitor_6): ")
    monitorName = read()
  end

  local configBlock = string.format([[
-- Configuration
local modemSide = "%s"
local redstoneSide = "%s"
local inputSide = "%s"
local channel = %d
local defaultValue = '%s'
local mode = %d
local monitorName = %s
]], modemSide, redstoneSide, inputSide, channel, defaultValue, mode,
     monitorName and string.format('"%s"', monitorName) or "nil")

  local f = fs.open("client_base.lua", "r")
  local clientBase = f.readAll()
  f.close()

  local monitorCode = ""
  if monitorName then
    shell.run("wget https://raw.githubusercontent.com/usr40k/cctweaked-programs/main/homectl/door.lua door.lua")
    local f2 = fs.open("door.lua", "r")
    monitorCode = f2.readAll()
    f2.close()
    shell.run("rm door.lua")
  end

  local out = fs.open("client_gen.lua", "w")
  out.write(configBlock .. "\n" .. monitorCode .. "\n" .. clientBase ..
    "\nprint(\"Listening for signals and monitoring input...\")\nparallel.waitForAny(monitorInput, handleModemMessages)")
  out.close()

  local f3 = fs.open("last_channel.txt", "w")
  f3.write(tostring(channel))
  f3.close()

  print("Client generated as client_gen.lua")
end
