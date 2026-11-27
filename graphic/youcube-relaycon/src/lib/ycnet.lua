--[[ ycnet - async search + thumbnail client for the relaycon smart-TV gallery.

  Piggybacks on existing public services instead of a custom server:
    * search:     Musiclo's API   <search_url>?search=<query>  -> JSON [meta, {name,artist,id}, ...]
    * thumbnails: imgon-cc (sanjuuni) <imgon>/<WxH>:Dordered/<image url> -> BIMG
  Both URLs are options, so you can point them at anything compatible.

  Everything is non-blocking: call Net:search / Net:thumb with a callback and
  feed every http_success / http_failure event to Net:handle(...).
]]

local Net = {}
Net.__index = Net

local DEFAULTS = {
    search_url = "https://ipod-2to6magyna-uc.a.run.app/",
    imgon = "https://imgon.cyberbit.dev",
    thumb_src = "https://i.ytimg.com/vi/%s/mqdefault.jpg",
    max_parallel = 2,
    cache_max = 48,
    timeout = 25,
}

local function urlencode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

function Net.new(opts)
    local self = setmetatable({}, Net)
    opts = opts or {}
    for k, v in pairs(DEFAULTS) do self[k] = opts[k] or v end
    self.active = {}      -- [url] = { cb = {...}, started = clock, kind = "search"|"thumb", key = ... }
    self.queue = {}       -- pending {url, kind, key}
    self.cache, self.order = {}, {}
    self.failed = {}      -- [key] = clock of last failure (don't hammer)
    self.last_search = {} -- [query] = results
    self.n_active = 0
    return self
end

local function validId(id) return type(id) == "string" and id:match("^[%w_%-]+$") and #id <= 20 end
Net.valid_id = validId

function Net:thumb_url(id, w, h)
    return string.format("%s/%dx%d:Dordered:Fbimg:p/%s", self.imgon, w, h, string.format(self.thumb_src, id))
end

function Net:_start(job)
    self.n_active = self.n_active + 1
    job.started = os.clock()
    self.active[job.url] = job
    local ok = pcall(http.request, { url = job.url, binary = false })
    if not ok then self:_finish(job.url, nil) end
end

function Net:_pump()
    while self.n_active < self.max_parallel and #self.queue > 0 do
        local job = table.remove(self.queue, 1)
        if not self.active[job.url] then self:_start(job) end
    end
end

function Net:_enqueue(job, front)
    -- coalesce identical requests
    local a = self.active[job.url]
    if a then a.cbs[#a.cbs + 1] = job.cb return end
    for _, q in ipairs(self.queue) do
        if q.url == job.url then q.cbs[#q.cbs + 1] = job.cb return end
    end
    job.cbs = { job.cb }
    if front then table.insert(self.queue, 1, job) else self.queue[#self.queue + 1] = job end
    self:_pump()
end

function Net:_finish(url, body)
    local job = self.active[url]
    if not job then return end
    self.active[url] = nil
    self.n_active = math.max(0, self.n_active - 1)
    local result, err
    if body then
        if job.kind == "search" then
            local data = textutils.unserialiseJSON(body)
            if type(data) == "table" then
                local list = {}
                for _, it in ipairs(data) do
                    if type(it) == "table" and validId(it.id) then
                        list[#list + 1] = { id = it.id, name = tostring(it.name or "?"), artist = tostring(it.artist or "") }
                    end
                end
                result = list
                self.last_search[job.key] = list
            else err = "bad response" end
        else
            local img = textutils.unserialise(body)
            if type(img) == "table" and type(img[1]) == "table" then
                result = img
                self:_cache_put(job.key, img)
            else err = "bad image" end
        end
    else err = "request failed" end
    if err then self.failed[job.key] = os.clock() end
    for _, cb in ipairs(job.cbs) do pcall(cb, result, err) end
    self:_pump()
end

function Net:_cache_put(key, v)
    if not self.cache[key] then self.order[#self.order + 1] = key end
    self.cache[key] = v
    while #self.order > self.cache_max do self.cache[table.remove(self.order, 1)] = nil end
end

--- search(query, cb(list|nil, err))
function Net:search(query, cb)
    query = tostring(query or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if query == "" then return cb({}, nil) end
    if self.last_search[query] then return cb(self.last_search[query], nil) end
    -- trailing "&" keeps repeated queries from colliding with in-flight urls only when needed
    self:_enqueue({ url = self.search_url .. "?search=" .. urlencode(query), kind = "search", key = query, cb = cb }, true)
end

--- thumb(id, w, h, cb(img|nil, err)); returns cached image immediately if present.
function Net:thumb(id, w, h, cb)
    if not validId(id) then return cb(nil, "bad id") end
    local key = id .. ":" .. w .. "x" .. h
    if self.cache[key] then return cb(self.cache[key], nil) end
    if self.failed[key] and os.clock() - self.failed[key] < 60 then return cb(nil, "recently failed") end
    self:_enqueue({ url = self:thumb_url(id, w, h), kind = "thumb", key = key, cb = cb })
end

function Net:cached(id, w, h) return self.cache[id .. ":" .. w .. "x" .. h] end

--- Feed http_success / http_failure here. Returns true if the event was ours.
function Net:handle(ev, url, handle)
    if not self.active[url] then return false end
    if ev == "http_success" then
        local body = handle and handle.readAll() or nil
        if handle and handle.close then handle.close() end
        self:_finish(url, body)
    else
        if handle and handle.close then pcall(handle.close) end
        self:_finish(url, nil)
    end
    return true
end

--- Drop requests that never answered (call from a 1 s tick).
function Net:tick()
    local now = os.clock()
    for url, job in pairs(self.active) do
        if now - job.started > self.timeout then self:_finish(url, nil) end
    end
end

--- Draw a BIMG frame (default palette only) at x,y on `t`; maxw/maxh crop.
function Net.draw(t, img, x, y, maxw, maxh)
    local frame = img and img[1]
    if not frame then return 0, 0 end
    local h = math.min(#frame, maxh or #frame)
    local w = 0
    for i = 1, h do
        local row = frame[i]
        local text, fg, bg = row[1], row[2], row[3]
        if maxw and #text > maxw then text, fg, bg = text:sub(1, maxw), fg:sub(1, maxw), bg:sub(1, maxw) end
        w = math.max(w, #text)
        t.setCursorPos(x, y + i - 1)
        t.blit(text, fg, bg)
    end
    return w, h
end

return Net
