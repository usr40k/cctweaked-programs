--[[ yctheater - player side of the relaycon "theater" protocol.

  A theater is one YouCube player (one screen + speakers). Each theater has a
  persistent id and name, and gets paired to a relaycon hub (the base station):

    1. Unpaired, the theater shows a 6 digit code and broadcasts `yc_beacon`.
    2. In relaycon: More > Theaters > pick the new theater > type the code.
    3. The hub proves it knows the code, hands over a fresh shared secret
       (masked with a key derived from the code) and the theater saves it.
    4. From then on every command is signed with that secret, carries a
       timestamp + unique id, and unsigned/unknown commands are ignored.

  The theater reports `yc_status` every few seconds, and tracks whether the hub
  and any pocket "remotes" are connected so the UI can toast changes.
]]

local auth -- the ycauth library, injected with Theater.use(ycauth)

local Theater = {}
Theater.__index = Theater

function Theater.use(ycauth)
    auth = ycauth
    return Theater
end

local STATUS_EVERY = 3        -- seconds between status broadcasts
local BEACON_EVERY = 2        -- seconds between pairing beacons
local HUB_TIMEOUT = 12        -- seconds of silence before the hub counts as gone
local SESSION_TIMEOUT = 10    -- seconds before an idle pocket remote counts as gone
local CODE_LIFETIME = 120     -- seconds a pairing code stays valid
local MAX_PAIR_FAILS = 5
local CLOCK_SKEW = 30000      -- ms allowed between sender and receiver clocks

local function readJSON(path)
    if not (fs and fs.exists(path)) then return nil end
    local f = fs.open(path, "r")
    if not f then return nil end
    local data = textutils.unserializeJSON(f.readAll())
    f.close()
    return type(data) == "table" and data or nil
end

local function writeJSON(path, tbl)
    local f = fs.open(path, "w")
    if not f then return false end
    f.write(textutils.serializeJSON(tbl))
    f.close()
    return true
end

--[[ Creates a theater.
  opts.path        state file (default "/youcube_theater.json")
  opts.network     network name (secret is dropped if it was paired on another)
  opts.name        initial name (only used the first time)
  opts.transmit    function(msg) that broadcasts on the network channel
  opts.toast       function(text, kind)   kind: "ok" | "warn" | "bad" | "info"
  opts.status      function() -> { title, state, paused, volume, captured }
  opts.command     function(action, params) for player actions (pause, skip ...)
  opts.on_paired / opts.on_unpaired / opts.on_change   optional callbacks
]]
function Theater.new(opts)
    local self = setmetatable({}, Theater)
    self.path = opts.path or "/youcube_theater.json"
    self.network = opts.network or "default"
    self.transmit = opts.transmit
    self.toast = opts.toast or function() end
    self.status_fn = opts.status or function() return {} end
    self.command = opts.command or function() end
    self.on_paired = opts.on_paired
    self.on_unpaired = opts.on_unpaired
    self.on_change = opts.on_change

    local saved = readJSON(self.path) or {}
    self.tid = saved.tid or auth.random_hex(8)
    self.name = saved.name or opts.name or ("Theater " .. tostring(os.getComputerID and os.getComputerID() or "?"))
    self.settings = saved.settings or {}
    if saved.secret and saved.network == self.network then
        self.secret = saved.secret
        self.hub = saved.hub
    end
    if opts.name_override then self.name = opts.name_override end

    self.seen, self.seen_order = {}, {}
    self.hub_connected = false
    self.hub_seen = nil
    self.sessions = {}      -- [who] = os.clock() of last sign of life
    self.last_status = 0
    self.last_beacon = 0
    self.pair_fails = 0
    if not self.secret then self:new_code() end
    self:save()
    return self
end

function Theater:save()
    writeJSON(self.path, {
        tid = self.tid, name = self.name, network = self.network,
        secret = self.secret, hub = self.hub, settings = self.settings,
    })
end

function Theater:is_paired() return self.secret ~= nil end

function Theater:new_code()
    self.code = auth.new_code()
    self.nonce = auth.random_hex(8)
    self.code_expires = os.clock() + CODE_LIFETIME
    self.pair_fails = 0
end

--- For the screen: { code = "482-913", seconds = 97 } or nil when paired.
function Theater:pairing_info()
    if self.secret then return nil end
    return {
        code = auth.fmt_code(self.code),
        seconds = math.max(0, math.floor(self.code_expires - os.clock())),
    }
end

function Theater:set_name(name)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return end
    self.name = name:sub(1, 24)
    self:save()
    self:broadcast_status()
end

function Theater:set_setting(key, value)
    self.settings[key] = value
    self:save()
end

function Theater:unpair(reason)
    if not self.secret then return end
    self.secret, self.hub = nil, nil
    self.hub_connected, self.hub_seen = false, nil
    self:new_code()
    self:save()
    self.toast(reason or "Unpaired from hub", "warn")
    if self.on_unpaired then self.on_unpaired() end
    self:broadcast_status()
end

-- ---------------------------------------------------------------------------
-- Outgoing
-- ---------------------------------------------------------------------------

function Theater:broadcast_status()
    if not self.transmit then return end
    self.last_status = os.clock()
    if not self.secret then
        self.last_beacon = os.clock()
        self.transmit({ cmd = "yc_beacon", tid = self.tid, name = self.name, nonce = self.nonce })
        return
    end
    local st = self.status_fn() or {}
    local body = {
        title = tostring(st.title or ""), state = tostring(st.state or "idle"),
        paused = st.paused and true or false, volume = tonumber(st.volume) or 100,
        captured = st.captured and true or false, name = self.name,
    }
    local ts = auth.now()
    self.transmit({
        cmd = "yc_status", tid = self.tid, ts = ts, st = body,
        sig = auth.sign(self.secret, self.tid, ts, auth.canon(body)),
    })
end

--- Signed request to the hub (e.g. relay control). Returns false if unpaired.
function Theater:send_signed(cmd, params)
    if not (self.secret and self.transmit) then return false end
    local ts, rid = auth.now(), auth.random_hex(6)
    params = params or {}
    self.transmit({
        cmd = cmd, tid = self.tid, ts = ts, rid = rid, p = params,
        sig = auth.sign(self.secret, self.tid, ts, rid, cmd, auth.canon(params)),
    })
    return true
end

-- ---------------------------------------------------------------------------
-- Incoming
-- ---------------------------------------------------------------------------

function Theater:remember(rid)
    if self.seen[rid] then return false end
    self.seen[rid] = true
    self.seen_order[#self.seen_order + 1] = rid
    if #self.seen_order > 128 then self.seen[table.remove(self.seen_order, 1)] = nil end
    return true
end

function Theater:hub_alive()
    if not self.hub_connected then
        self.hub_connected = true
        self.toast("Remote connected" .. (self.hub and (": " .. self.hub) or ""), "ok")
        if self.on_change then self.on_change() end
    end
    self.hub_seen = os.clock()
end

function Theater:handle_pair(msg)
    local function result(ok, reason)
        self.transmit({ cmd = "yc_pair_result", tid = self.tid, ok = ok, reason = reason, name = self.name,
            ack = ok and auth.pair_ack(self.secret, self.tid, self.nonce) or nil })
    end
    if self.secret then return result(false, "already paired") end
    if os.clock() > self.code_expires then
        self:new_code()
        self:broadcast_status()
        return result(false, "code expired")
    end
    local expect = auth.pair_proof(self.tid, self.nonce, self.code)
    if not (type(msg.proof) == "string" and auth.eq(msg.proof, expect)) then
        self.pair_fails = self.pair_fails + 1
        if self.pair_fails >= MAX_PAIR_FAILS then
            self:new_code()
            self:broadcast_status()
            self.toast("Too many wrong codes - new code", "warn")
        end
        return result(false, "wrong code")
    end
    if type(msg.enc) ~= "string" then return result(false, "bad request") end
    self.secret = auth.xor_hex(msg.enc, auth.pair_mask(self.tid, self.nonce, self.code))
    self.hub = tostring(msg.hub or "hub"):sub(1, 24)
    result(true)
    self.code = nil
    self:save()
    self.toast("Paired with " .. self.hub, "ok")
    self:hub_alive()
    if self.on_paired then self.on_paired() end
    self:broadcast_status()
end

function Theater:handle_cmd(msg)
    if not self.secret or msg.tid ~= self.tid then return end
    local ts, rid, action, p = tonumber(msg.ts), msg.rid, msg.action, msg.p or {}
    if not (ts and type(rid) == "string" and type(action) == "string" and type(p) == "table") then return end
    if math.abs(auth.now() - ts) > CLOCK_SKEW then return end
    local expect = auth.sign(self.secret, self.tid, ts, rid, action, auth.canon(p))
    if not (type(msg.sig) == "string" and auth.eq(msg.sig, expect)) then return end
    if not self:remember(rid) then return end

    self:hub_alive()
    if action == "ping" then
        return
    elseif action == "session" then
        local who = tostring(p.who or "remote"):sub(1, 20)
        if p.open == false then
            if self.sessions[who] then
                self.sessions[who] = nil
                self.toast("Remote disconnected: " .. who, "warn")
            end
        else
            if not self.sessions[who] then self.toast("Remote connected: " .. who, "ok") end
            self.sessions[who] = os.clock()
        end
    elseif action == "unpair" then
        self:unpair("Unpaired by hub")
        return
    elseif action == "rename" then
        self:set_name(p.name)
    elseif action == "status_request" then
        -- answered by the broadcast below
    else
        self.command(action, p)
    end
    self:broadcast_status()
end

--- Feed every modem_message payload here.
function Theater:handle(msg)
    if type(msg) ~= "table" then return end
    if msg.cmd == "yc_cmd" then
        self:handle_cmd(msg)
    elseif msg.cmd == "yc_pair" and msg.tid == self.tid then
        self:handle_pair(msg)
    end
end

--- Call about once a second.
function Theater:tick()
    local now = os.clock()
    if not self.secret then
        if now > self.code_expires then
            self:new_code()
        end
        if now - self.last_beacon >= BEACON_EVERY then self:broadcast_status() end
        return
    end
    if now - self.last_status >= STATUS_EVERY then self:broadcast_status() end
    if self.hub_connected and self.hub_seen and now - self.hub_seen > HUB_TIMEOUT then
        self.hub_connected = false
        self.toast("Remote disconnected", "bad")
        if self.on_change then self.on_change() end
    end
    for who, t in pairs(self.sessions) do
        if now - t > SESSION_TIMEOUT then
            self.sessions[who] = nil
            self.toast("Remote disconnected: " .. who, "warn")
        end
    end
end

--- Background thread: run it for the whole program in parallel with the UI.
function Theater:run()
    self:broadcast_status()
    local timer = os.startTimer(1)
    while true do
        local ev, p1, p2, p3, p4 = os.pullEvent()
        if ev == "modem_message" then
            self:handle(p4)
        elseif ev == "timer" and p1 == timer then
            self:tick()
            timer = os.startTimer(1)
        end
    end
end

return Theater
