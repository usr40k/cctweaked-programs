--[[
_   _ ____ _  _ ____ _  _ ___  ____
 \_/  |  | |  | |    |  | |__] |___
  |   |__| |__| |___ |__| |__] |___

Github Repository: https://github.com/Commandcracker/YouCube
License: GPL-3.0
]]

local _VERSION = "0.0.0-poc.1.1.2"

-- Libraries - OpenLibrarieLoader v1.0.1 --

--TODO: Optional libs:
-- For something like a JSON lib that is only needed for older CC Versions or
-- optional logging.lua support

local function is_lib(libs, lib)
    for i = 1, #libs do
        local value = libs[i]
        if value == lib or value .. ".lua" == lib then
            return true, value
        end
    end
    return false
end

local libs = { "youcubeapi", "numberformatter", "semver", "argparse", "string_pack", "ycauth", "yctheater", "ycui", "ycbig", "ycnet" }
local lib_paths = { ".", "./lib", "./apis", "./modules", "/", "/lib", "/apis", "/modules" }

-- LevelOS Support
if _G.lOS then
    lib_paths[#lib_paths + 1] = "/Program_Files/YouCube/lib"
end

local function load_lib(lib)
    if require then
        return require(lib:gsub(".lua", ""))
    end
    return dofile(lib)
end

for i_path = 1, #lib_paths do
    local path = lib_paths[i_path]
    if fs.exists(path) then
        local files = fs.list(path)
        for i_file = 1, #files do
            local found, lib = is_lib(libs, files[i_file])
            if found and lib ~= nil and libs[lib] == nil then
                libs[lib] = load_lib(path .. "/" .. files[i_file])
            end
        end
    end
end

for i = 1, #libs do
    local lib = libs[i]
    if libs[lib] == nil then
        error(('Library "%s" not found.'):format(lib))
    end
end

-- args --

local function get_program_name()
    if arg then
        return arg[0]
    end
    return fs.getName(shell.getRunningProgram()):gsub("[\\.].*$", "")
end

-- stylua: ignore start

local parser = libs.argparse {
    help_max_width = ({ term.getSize() })[1],
    name = get_program_name()
}
    :description "Official YouCube client for accessing media from services like YouTube"

parser:argument "URL"
    :args "*"
    :description "URL or search term."

parser:flag "-v" "--verbose"
    :description "Enables verbose output."
    :target "verbose"
    :action "store_true"

parser:option "-V" "--volume"
    :description "Sets the volume of the audio. A value from 0-100"
    :target "volume"

parser:option "-s" "--server"
    :description "The server that YC should use."
    :target "server"
    :args(1)

parser:flag "--nv" "--no-video"
    :description "Disables video."
    :target "no_video"
    :action "store_true"

parser:flag "--na" "--no-audio"
    :description "Disables audio."
    :target "no_audio"
    :action "store_true"

parser:flag "--sh" "--shuffle"
    :description "Shuffles audio before playing"
    :target "shuffle"
    :action "store_true"

parser:flag "-l" "--loop"
    :description "Loops the media."
    :target "loop"
    :action "store_true"

parser:flag "--lp" "--loop-playlist"
    :description "Loops the playlist."
    :target "loop_playlist"
    :action "store_true"

parser:option "--fps"
    :description "Force sanjuuni to use a specified frame rate"
    :target "force_fps"

parser:option "--relay-id"
    :description "Relay ID (from relaycon) to control when media plays/stops"
    :target "relay_id"
    :args(1)

parser:option "--relay-side"
    :description "Redstone output side of the relay (top, bottom, left, right, front, back)"
    :target "relay_side"
    :args(1)

parser:option "--relay-network"
    :description "Wireless network name for relaycon communication (default: default)"
    :target "relay_network"
    :args(1)

parser:option "--theater-name"
    :description "Name of this theater (shown in relaycon)"
    :target "theater_name"
    :args(1)

parser:option "--rs-side"
    :description "Output a redstone signal on one of THIS computer's sides (top, bottom, left, right, front, back, off)"
    :target "rs_side"
    :args(1)

parser:option "--rs-when"
    :description "Redstone is ON while 'playing' (default) or while 'idle'"
    :target "rs_when"
    :args(1)

parser:flag "--pair"
    :description "Forget the current hub pairing and show a new pairing code"
    :target "pair"
    :action "store_true"

-- stylua: ignore end

local args = parser:parse({ ... })

do
    local valid = { top = 1, bottom = 1, left = 1, right = 1, front = 1, back = 1, off = 1 }
    if args.rs_side and not valid[args.rs_side] then
        parser:error("--rs-side must be top, bottom, left, right, front, back or off")
    end
    if args.rs_when and args.rs_when ~= "playing" and args.rs_when ~= "idle" then
        parser:error("--rs-when must be 'playing' or 'idle'")
    end
end

if args.force_fps then
    args.force_fps = tonumber(args.force_fps)
end

if args.volume then
    args.volume = tonumber(args.volume)
    if args.volume == nil then
        parser:error("Volume must be a number")
    end

    if args.volume > 100 then
        parser:error("Volume cant be over 100")
    end

    if args.volume < 0 then
        parser:error("Volume cant be below 0")
    end
    args.volume = args.volume / 100
end

if #args.URL > 0 then
    args.URL = table.concat(args.URL, " ")
else
    args.URL = nil
end

if args.no_video and args.no_audio then
    parser:error("Nothing will happen, when audio and video is disabled!")
end

-- ===========================================================================
-- Theater / relaycon integration
-- ===========================================================================

local yc_modem = nil
local yc_channel = nil
local yc_network = args.relay_network or "default"
-- --relay-id can be a numeric relay ID or a relayName (peripheral name like "redstone_relay_13")
local yc_relay_id = args.relay_id or nil
if yc_relay_id and tonumber(yc_relay_id) then yc_relay_id = tonumber(yc_relay_id) end
local yc_relay_side = args.relay_side or "top"

-- Deterministic name -> modem channel (same hash as relaycon)
local function yc_nameToChannel(name)
    local h = 0
    for i = 1, #name do
        h = (h * 31 + string.byte(name, i)) % 65536
    end
    return (h % 65000) + 1
end

local function yc_openWireless()
    local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
    if not modem then
        print("Warning: No wireless modem found. Remote control and relay output disabled.")
        return nil
    end
    if yc_channel then pcall(modem.close, yc_channel) end
    yc_channel = yc_nameToChannel(yc_network)
    modem.open(yc_channel)
    print(string.format("[Wireless] Modem opened on channel %d (network: %s)", yc_channel, yc_network))
    return modem
end

local function yc_send(msg)
    if yc_modem and yc_channel then
        yc_modem.transmit(yc_channel, yc_channel, msg)
    end
end

-- Playback / remote-control state
local yc_paused = false
local yc_captured = false   -- when false, remote keystrokes are ignored
local yc_volume = args.volume or 1.0
local yc_state = "idle"     -- "idle" | "playing"
local yc_currentTitle = ""

yc_modem = yc_openWireless()

local yc_handleCommand      -- assigned below, once the player pieces it drives exist
local yc_theater
local yc_history = libs.ycui.history_new("/youcube_history.json")

-- Relay control goes through the paired hub (signed), never as a bare broadcast.
local function yc_relayCmd(state)
    if not yc_relay_id or not yc_theater or not yc_theater:is_paired() then return end
    yc_theater:send_signed("yc_relay", { id = yc_relay_id, state = state, side = yc_relay_side })
end

-- Relay is ON while nothing plays and OFF while media plays.
local function yc_applyRelay()
    yc_relayCmd(yc_state ~= "playing")
end

-- Redstone output on this computer's own side (settings: rs_side / rs_when)
local yc_rs_active_side = nil
local function yc_applyRedstone()
    local side = yc_theater.settings.rs_side
    if side == "off" then side = nil end
    if yc_rs_active_side and yc_rs_active_side ~= side then
        pcall(redstone.setOutput, yc_rs_active_side, false)
    end
    yc_rs_active_side = side
    if not side then return end
    local playing = (yc_state == "playing")
    local on = playing
    if yc_theater.settings.rs_when == "idle" then on = not playing end
    pcall(redstone.setOutput, side, on)
end

yc_theater = libs.yctheater.use(libs.ycauth).new({
    path = "/youcube_theater.json",
    network = yc_network,
    name_override = args.theater_name,
    transmit = yc_send,
    toast = libs.ycui.toast,
    status = function()
        return {
            title = yc_currentTitle, state = yc_state, paused = yc_paused,
            volume = math.floor((yc_volume or 1) * 100 + 0.5), captured = yc_captured,
        }
    end,
    command = function(action, p) return yc_handleCommand(action, p) end,
    on_paired = function() yc_applyRelay() end,
    on_change = function()
        if yc_theater.hub_connected then yc_applyRelay() end
    end,
})

if args.pair and yc_theater:is_paired() then yc_theater:unpair("Pairing reset") end
if args.rs_side then yc_theater:set_setting("rs_side", args.rs_side) end
if args.rs_when then yc_theater:set_setting("rs_when", args.rs_when) end

-- Call whenever idle/playing changes
local function yc_stateChanged()
    yc_applyRedstone()
    yc_applyRelay()
    yc_theater:broadcast_status()
end

-- CraftOS-PC support --

if periphemu then
    periphemu.create("top", "speaker")
    -- Fuck the max websocket message police
    config.set("http_max_websocket_message", 2 ^ 30)
end

local function get_audiodevices()
    local audiodevices = {}

    local speakers = { peripheral.find("speaker") }
    for i = 1, #speakers do
        audiodevices[#audiodevices + 1] = libs.youcubeapi.Speaker.new(speakers[i])
    end

    local tapes = { peripheral.find("tape_drive") }
    for i = 1, #tapes do
        audiodevices[#audiodevices + 1] = libs.youcubeapi.Tape.new(tapes[i])
    end

    if #audiodevices == 0 then
        -- Disable audio when no audiodevice is found
        args.no_audio = true
        return audiodevices
    end

    -- Validate audiodevices
    local last_error
    local valid_audiodevices = {}

    for i = 1, #audiodevices do
        local audiodevice = audiodevices[i]
        local _error = audiodevice:validate()
        if _error == nil then
            valid_audiodevices[#valid_audiodevices + 1] = audiodevice
        else
            last_error = _error
        end
    end

    if #valid_audiodevices == 0 then
        error(last_error)
    end

    return valid_audiodevices
end

-- main --

local youcubeapi = libs.youcubeapi.API.new()
local audiodevices = get_audiodevices()

-- update check --

local function get_versions()
    local url = "https://raw.githubusercontent.com/CC-YouCube/installer/main/versions.json"

    -- Check if the URL is valid
    local ok, err = http.checkURL(url)
    if not ok then
        printError("Invalid Update URL.", '"' .. url .. '" ', err)
        return
    end

    local response, http_err = http.get(url, nil, true)
    if not response then
        printError('Failed to retreat data from update URL. "' .. url .. '" (' .. http_err .. ")")
        return
    end

    local sResponse = response.readAll()
    response.close()

    return textutils.unserialiseJSON(sResponse)
end

local function write_colored(text, color)
    term.setTextColor(color)
    term.write(text)
end

local function new_line()
    local w, h = term.getSize()
    local x, y = term.getCursorPos()
    if y + 1 <= h then
        term.setCursorPos(1, y + 1)
    else
        term.setCursorPos(1, h)
        term.scroll(1)
    end
end

local function write_outdated(current, latest)
    if libs.semver(current) ^ libs.semver(latest) then
        term.setTextColor(colors.yellow)
    else
        term.setTextColor(colors.red)
    end

    term.write(current)
    write_colored(" -> ", colors.lightGray)
    write_colored(latest, colors.lime)
    term.setTextColor(colors.white)
    new_line()
end

local function can_update(name, current, latest)
    if libs.semver(current) < libs.semver(latest) then
        term.write(name .. " ")
        write_outdated(current, latest)
    end
end

local function update_checker()
    local versions = get_versions()
    if versions == nil then
        return
    end

    can_update("youcube", _VERSION, versions.client.version)
    can_update("youcubeapi", libs.youcubeapi._VERSION, versions.client.libraries.youcubeapi.version)
    can_update("numberformatter", libs.numberformatter._VERSION, versions.client.libraries.numberformatter.version)
    can_update("semver", tostring(libs.semver._VERSION), versions.client.libraries.semver.version)
    can_update("argparse", libs.argparse.version, versions.client.libraries.argparse.version)

    local handshake = youcubeapi:handshake()

    if libs.semver(handshake.server.version) < libs.semver(versions.server.version) then
        print("Tell the server owner to update their server!")
        write_outdated(handshake.server.version, versions.server.version)
    end

    if not libs.semver(libs.youcubeapi._API_VERSION) ^ libs.semver(handshake.api.version) then
        print("Client is not compatible with server")
        write_colored(libs.youcubeapi._API_VERSION, colors.red)
        write_colored(" ^ ", colors.lightGray)
        write_colored(handshake.api.version, colors.red)
        term.setTextColor(colors.white)
        new_line()
    end

    if libs.semver(libs.youcubeapi._API_VERSION) < libs.semver(versions.api.version) then
        print("Your client is using an outdated API version")
        write_outdated(libs.youcubeapi._API_VERSION, versions.api.version)
    end

    if libs.semver(handshake.api.version) < libs.semver(versions.api.version) then
        print("The server is using an outdated API version")
        write_outdated(libs.youcubeapi._API_VERSION, versions.api.version)
    end
end

-- Set volume on all audio devices
local function yc_setVolume(vol)
    yc_volume = vol
    for i = 1, #audiodevices do
        audiodevices[i]:setVolume(vol)
    end
end

local function play_audio(buffer, title)
    for i = 1, #audiodevices do
        local audiodevice = audiodevices[i]
        audiodevice:reset()
        audiodevice:setLabel(title)
        audiodevice:setVolume(yc_volume)
    end

    while true do
        while yc_paused do
            local ev = os.pullEvent()
            if ev == "youcube:resume" then break end
        end
        local chunk = buffer:next()

        -- Adjust buffer size on first chunk
        if buffer.filler.chunkindex == 1 then
            buffer.size = math.ceil(1024 / (#chunk / 16))
        end

        if chunk == "" then
            local play_functions = {}
            for i = 1, #audiodevices do
                local audiodevice = audiodevices[i]
                play_functions[#play_functions + 1] = function()
                    audiodevice:play()
                end
            end

            parallel.waitForAll(table.unpack(play_functions))
            return
        end

        local write_functions = {}
        for i = 1, #audiodevices do
            local audiodevice = audiodevices[i]
            table.insert(write_functions, function()
                audiodevice:write(chunk)
            end)
        end

        parallel.waitForAll(table.unpack(write_functions))
    end
end

-- #region playback controll vars
local back_buffer = {}
local max_back = settings.get("youcube.max_back") or 32
local queue = {}
local restart = false
-- #endregion

-- keys
local skip_key = settings.get("youcube.keys.skip") or keys.d
local restart_key = settings.get("youcube.keys.restart") or keys.r
local back_key = settings.get("youcube.keys.back") or keys.a

-- Commands from a paired hub (already signature-checked by yctheater).
yc_handleCommand = function(action, p)
    p = p or {}
    if action == "play_pause" then
        if yc_state ~= "playing" then return end
        local want = p.paused
        if want == nil then want = not yc_paused end
        if want ~= yc_paused then
            yc_paused = want
            os.queueEvent(want and "youcube:pause" or "youcube:resume")
        end
    elseif action == "volume_up" then
        yc_setVolume(math.min(1, (yc_volume or 1) + 0.1))
    elseif action == "volume_down" then
        yc_setVolume(math.max(0, (yc_volume or 1) - 0.1))
    elseif action == "volume_set" then
        yc_setVolume(math.max(0, math.min(1, (tonumber(p.volume) or 100) / 100)))
    elseif action == "skip" then
        os.queueEvent("youcube:remote_key", skip_key)
    elseif action == "restart" then
        os.queueEvent("youcube:remote_key", restart_key)
    elseif action == "capture_toggle" then
        yc_captured = p.captured ~= false
        libs.ycui.toast(yc_captured and "Remote keyboard ON" or "Remote keyboard off", yc_captured and "ok" or "info")
    elseif action == "keystroke" then
        -- A real remote keyboard: becomes ordinary char/key events, so it types into
        -- the on-screen search and triggers the normal hotkeys. Needs capture on.
        if yc_captured and p.key then
            local name = tostring(p.key)
            if #name == 1 then
                os.queueEvent("char", name)
                local k = keys[name:lower()]
                if k then os.queueEvent("key", k) end
            else
                local k = keys[name]
                if k then os.queueEvent("key", k) end
            end
        end
    elseif action == "text" then
        if yc_captured and p.text then
            for i = 1, #tostring(p.text) do
                os.queueEvent("char", tostring(p.text):sub(i, i))
            end
        end
    end
end

local function play(url)
    restart = false
    print("Requesting media ...")

    if not args.no_video then
        youcubeapi:request_media(url, term.getSize())
    else
        youcubeapi:request_media(url)
    end

    local data
    local Big = libs.ycbig
    local ld = { title = yc_history and yc_history:title_of(url) or url, status = "Requesting media ...", pct = nil, phase = 0 }
    local function ld_draw()
        if args.verbose then return end
        Big.screen(term, ld)
    end
    ld_draw()

    local function receive_loop()
        repeat
            data = youcubeapi:receive()
            if data.action == "status" then
                os.queueEvent("youcube:status", data)
                ld.status = tostring(data.message or "")
                ld.pct = Big.parse_pct(ld.status)
                ld_draw()
            end
        until data.action == "media" or data.action == "error"
    end
    local function animate()
        local t = os.startTimer(0.15)
        while true do
            local ev, id = os.pullEvent("timer")
            if id == t then
                ld.phase = (ld.phase + 0.06) % 1
                if not ld.pct then ld_draw() end
                t = os.startTimer(0.15)
            end
        end
    end
    parallel.waitForAny(receive_loop, animate)

    if data.action == "error" then
        error(data.message)
    end

    ld.title = tostring(data.title or ld.title)
    ld.status = "Buffering ..."
    ld.pct = 0
    ld_draw()
    if args.verbose then
        print("Playing: " .. tostring(data.title))
    end

    local video_buffer = libs.youcubeapi.Buffer.new(
        libs.youcubeapi.VideoFiller.new(youcubeapi, data.id, term.getSize()),
        60 -- Most videos run on 30 fps, so we store 2s of video.
    )

    local audio_buffer = libs.youcubeapi.Buffer.new(
        libs.youcubeapi.AudioFiller.new(youcubeapi, data.id),
        --[[
            We want to buffer 1024 chunks.
            One chunks is 16 bits.
            The server (with default settings) sends 32 chunks at once.
        ]]
        32
    )

    -- Prefill so playback starts smooth, with a big progress screen.
    do
        local want_a = args.no_audio and 0 or math.min(audio_buffer.size, 8)
        local want_v = args.no_video and 0 or math.min(video_buffer.size, 30)
        local guard = 0
        while guard < 300 do
            guard = guard + 1
            local a = want_a > 0 and math.min(1, #audio_buffer.buffer / want_a) or 1
            local v = want_v > 0 and math.min(1, #video_buffer.buffer / want_v) or 1
            ld.pct = math.floor(((a + v) / 2) * 100)
            ld.status = "Buffering ..."
            ld_draw()
            if a >= 1 and v >= 1 then break end
            if a < 1 then audio_buffer:fill() end
            if v < 1 then video_buffer:fill() end
        end
        ld.pct, ld.status = 100, "Starting ..."
        ld_draw()
    end

    if args.verbose then
        term.clear()
        term.setCursorPos(1, 1)
        term.write("[DEBUG MODE]")
    end

    local function fill_buffers()
        while true do
            os.queueEvent("youcube:fill_buffers")

            local event = os.pullEventRaw()

            if event == "terminate" then
                libs.youcubeapi.reset_term()
            end

            if not args.no_audio then
                audio_buffer:fill()
            end

            if args.verbose then
                term.setCursorPos(1, ({ term.getSize() })[2])
                term.clearLine()
                term.write("Audio_Buffer: " .. #audio_buffer.buffer)
            end

            if not args.no_video then
                video_buffer:fill()
            end
        end
    end

    local function _play_video()
        if not args.no_video then
            local string_unpack
            if not string.unpack then
                string_unpack = libs.string_pack.unpack
            end

            os.queueEvent("youcube:vid_playing", data)
            libs.youcubeapi.play_vid(video_buffer, args.force_fps, string_unpack, function() return yc_paused end)
            os.queueEvent("youcube:vid_eof", data)
        end
    end

    local function _play_audio()
        if not args.no_audio then
            os.queueEvent("youcube:audio_playing", data)
            play_audio(audio_buffer, data.title)
            os.queueEvent("youcube:audio_eof", data)
        end
    end

    local function _play_media()
        yc_state = "playing"
        yc_currentTitle = tostring(data.title or "")
        yc_history:set_title(url, data.title)
        yc_stateChanged()
        os.queueEvent("youcube:playing")
        parallel.waitForAll(_play_video, _play_audio)
    end

    local function _hotkey_handler()
        while true do
            local _, key = os.pullEvent("key")

            if key == skip_key then
                back_buffer[#back_buffer + 1] = url --finished playing, push the value to the back buffer
                if #back_buffer > max_back then
                    back_buffer[1] = nil --remove it from the front of the buffer
                end
                if not args.no_video then
                    libs.youcubeapi.reset_term()
                end
                break
            end

            if key == restart_key then
                queue[#queue + 1] = url --add the current song to upcoming
                if not args.no_video then
                    libs.youcubeapi.reset_term()
                end
                restart = true
                break
            end

            -- Local keys also respect capture state: when not captured, local input works normally.
            -- When captured, local keys are still processed (local override).
        end
    end

    -- Handles remote keystroke injection (skip/restart) without interfering with local hotkeys.
    local function _remote_key_handler()
        while true do
            local _, key = os.pullEvent("youcube:remote_key")

            if key == skip_key then
                back_buffer[#back_buffer + 1] = url
                if #back_buffer > max_back then
                    back_buffer[1] = nil
                end
                if not args.no_video then
                    libs.youcubeapi.reset_term()
                end
                break
            end

            if key == restart_key then
                queue[#queue + 1] = url
                if not args.no_video then
                    libs.youcubeapi.reset_term()
                end
                restart = true
                break
            end
        end
    end

    parallel.waitForAny(fill_buffers, _play_media, _hotkey_handler, _remote_key_handler)

    -- Always restore idle state when playback ends (even if interrupted by skip/restart)
    yc_paused = false -- reset pause state for next media item
    yc_state = "idle"
    yc_currentTitle = ""
    yc_stateChanged()

    if data.playlist_videos then
        return data.playlist_videos
    end
end

local function shuffle_playlist(playlist)
    local shuffled = {}
    for i = 1, #queue do
        local pos = math.random(1, #shuffled + 1)
        shuffled[pos] = queue[i]
    end
    return shuffled
end

local function play_playlist(playlist)
    queue = playlist
    if args.shuffle then
        queue = shuffle_playlist(queue)
    end
    while #queue ~= 0 do
        local pl = table.remove(queue)

        local function handle_back_hotkey()
            while true do
                local _, key = os.pullEvent("key")
                if key == back_key then
                    queue[#queue + 1] = pl --add the current song to upcoming
                    local prev = table.remove(back_buffer)
                    if prev then --nil/false check
                        queue[#queue + 1] = prev --add previous song to upcoming
                    end
                    if not args.no_video then
                        libs.youcubeapi.reset_term()
                    end
                    break
                end
            end
        end

        parallel.waitForAny(handle_back_hotkey, function()
            play(pl) --play the url
        end)
    end
end

-- Settings + hooks for the smart-TV screens
local yc_ui_ctx = {
    theater = yc_theater, history = yc_history, network = yc_network,
    get = function(key)
        if key == "name" then return yc_theater.name
        elseif key == "rs_side" then return yc_theater.settings.rs_side or "off"
        elseif key == "rs_when" then return yc_theater.settings.rs_when or "playing" end
    end,
    set = function(key, value)
        if key == "name" then yc_theater:set_name(value)
        elseif key == "rs_side" or key == "rs_when" then
            yc_theater:set_setting(key, value)
            yc_applyRedstone()
        elseif key == "unpair" then yc_theater:unpair("Unpaired")
        elseif key == "newcode" then
            yc_theater:new_code()
            yc_theater:broadcast_status()
        end
    end,
}

-- Plays one thing from the home screen. Errors (bad link, server down ...) come
-- back to the home screen as a toast instead of killing the program.
local function run_media(url)
    args.URL = url
    libs.ycui.loading("Loading...")
    local ok, result = pcall(play, url)
    if not ok then
        if tostring(result):find("Terminated") then error(result, 0) end
        yc_paused, yc_state, yc_currentTitle = false, "idle", ""
        yc_stateChanged()
        libs.youcubeapi.reset_term()
        libs.ycui.toast(tostring(result):gsub("^.-:%d+: ", ""), "bad", 6)
        return
    end
    local playlist_videos = result

    if args.loop == true then
        while true do
            play(url)
        end
    end
    if playlist_videos then
        if args.loop_playlist == true then
            while true do
                if playlist_videos then
                    play_playlist(playlist_videos)
                end
            end
        end
        play_playlist(playlist_videos)
    end

    while restart do
        play(url)
    end
end

local function main()
    yc_stateChanged() -- nothing plays yet: relay ON, redstone idle state
    youcubeapi:detect_bestest_server(args.server, args.verbose)
    pcall(update_checker)

    local first = args.URL
    while true do
        local url
        if first then
            url, first = first, nil
        else
            libs.youcubeapi.reset_term()
            local action, value = libs.ycui.home(yc_ui_ctx)
            if action ~= "play" then break end
            url = value
        end
        yc_history:note(url)
        run_media(url)
    end

    youcubeapi.websocket.close()

    if not args.no_video then
        libs.youcubeapi.reset_term()
    end

    -- Powering off: release the redstone output
    if yc_rs_active_side then pcall(redstone.setOutput, yc_rs_active_side, false) end

    os.queueEvent("youcube:playback_ended")
end

parallel.waitForAny(main, function() yc_theater:run() end, libs.ycui.toast_thread)
