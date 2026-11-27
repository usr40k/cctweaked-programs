--[[ ycgallery - YouTube-TV style browsing: shelves, search results and a detail page, with thumbnails.

  Gallery.use(helpers)   -- helpers come from ycui (UI._h)
  Gallery.shelves(ctx)   -> "play", url | "queue" handled via ctx.enqueue | "back" | "search", seed
  Gallery.results(ctx, query) -> "play", url | "back" | "fallback"   (fallback = service unreachable)

  ctx = { net = ycnet instance, shelves = {"query", ...}, history = History, enqueue = function(url,title) | nil,
          toast = function(text, kind) | nil }
]]

local H
local Gallery = {}
function Gallery.use(helpers) H = helpers return Gallery end

local function watch_url(id) return "https://www.youtube.com/watch?v=" .. id end
Gallery.watch_url = watch_url

local function yt_id(url)
    if type(url) ~= "string" then return nil end
    local id = url:match("[?&]v=([%w_%-]+)") or url:match("youtu%.be/([%w_%-]+)")
    return id
end
Gallery.yt_id = yt_id

local function geometry(w, h)
    local cols = (w >= 50) and 3 or ((w >= 34) and 2 or 1)
    local cw = math.floor((w - 1 - cols) / cols)       -- card width (1 col gutters)
    local th = (h >= 20 and cw >= 12) and math.max(3, math.min(6, math.floor((cw * 2 * 9 / 16) / 3 + 0.5))) or 0
    local ch = th + 2                                    -- thumb + title + artist
    return cols, cw, th, ch
end

-- ---------------------------------------------------------------------------
-- Generic section grid
-- ---------------------------------------------------------------------------

local function layout(sections, cols, ch)
    local cards, y = {}, 1
    for si, s in ipairs(sections) do
        s.y = y
        y = y + 1
        if s.items and #s.items > 0 then
            for i, it in ipairs(s.items) do
                local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
                cards[#cards + 1] = { s = si, i = i, it = it, col = col, vy = y + row * (ch + 1) }
            end
            y = y + math.ceil(#s.items / cols) * (ch + 1)
        else
            y = y + 2
        end
    end
    return cards, y
end

local function grid(ctx, title, sections, opts)
    local net = ctx.net
    local focus, scroll = 1, 0
    local timer = os.startTimer(1)
    local th_req = {}
    -- kick off section loads
    for _, s in ipairs(sections) do
        if s.query and not s.items and not s.err then
            net:search(s.query, function(list, err)
                if list then
                    local n = {}
                    for i = 1, math.min(#list, s.limit or 12) do n[i] = list[i] end
                    s.items = n
                    if #n == 0 then s.err = "No results" end
                else
                    s.err = err or "failed"
                end
            end)
        end
    end
    while true do
        if opts.fallback_on_error and sections[1].err and not sections[1].items then return "fallback" end
        local w, h = term.getSize()
        local cols, cw, th, ch = geometry(w, h)
        local top, bot = 2, h - 1
        local cards, total = layout(sections, cols, ch)
        if focus > #cards then focus = math.max(1, #cards) end
        local f = cards[focus]
        if f then
            local area = bot - top + 1
            local need_top = f.vy - 1
            if f.vy - scroll < 1 + (opts.header_rows or 1) then scroll = math.max(0, f.vy - 2) end
            if f.vy - scroll + ch > area then scroll = f.vy + ch - area end
            if scroll < 0 then scroll = 0 end
            -- keep section header visible when the focus is its first row
            local sec = sections[f.s]
            if f.vy - scroll - 1 < 1 and sec then scroll = math.max(0, sec.y - 1) end
            local _ = need_top
        end

        H.setc(H.THEME.text, H.THEME.bg)
        term.clear()
        H.bar(1, w, title, H.clock_text())

        local hits = {}
        for si, s in ipairs(sections) do
            local sy = top + (s.y - 1) - scroll
            if sy >= top and sy <= bot then
                H.put(2, sy, H.clip(s.title or s.query or "", w - 3), H.THEME.accent, H.THEME.bg)
            end
            if not s.items then
                local my = sy + 1
                if my >= top and my <= bot then
                    H.put(2, my, s.err and ("(" .. s.err .. ")") or "Loading ...", H.THEME.dim, H.THEME.bg)
                end
            end
        end
        for ci, c in ipairs(cards) do
            local x = 2 + c.col * (cw + 1)
            local y = top + (c.vy - 1) - scroll
            if y >= top and y + ch - 1 <= bot then
                local focused = (ci == focus)
                local bg = focused and H.THEME.tileFocus or H.THEME.bg
                local tfg = focused and H.THEME.tileFocusText or H.THEME.text
                if th > 0 then
                    local img = net:cached(c.it.id, cw * 2, th * 3)
                    if img then
                        H.setc(nil, H.THEME.bg)
                        H.fill(x, y, cw, th, H.THEME.tile)
                        H.net.draw(term, img, x, y, cw, th)
                    else
                        H.fill(x, y, cw, th, H.THEME.tile)
                        H.put(x, y + math.floor(th / 2), H.centered("...", cw), H.THEME.dim, H.THEME.tile)
                        local key = c.it.id .. ci
                        if not th_req[key] then
                            th_req[key] = true
                            net:thumb(c.it.id, cw * 2, th * 3, function() end)
                        end
                    end
                    if focused then
                        -- focus frame: bright bar above and below the thumbnail
                        H.fill(x, y + th, cw, 1, bg)
                    end
                end
                H.fill(x, y + th, cw, 2, bg)
                H.put(x, y + th, H.clip(c.it.name, cw), tfg, bg)
                H.put(x, y + th + 1, H.clip(c.it.artist, cw), focused and tfg or H.THEME.dim, bg)
                hits[#hits + 1] = { x = x, y = y, w = cw, h = ch, idx = ci }
            end
        end
        H.put(1, h, H.clip(opts.hint or "Arrows+Enter  Esc back", w), H.THEME.dim, H.THEME.bg)

        local ev, a, b = H.pull()
        if ev == "tap" then
            if b == h and opts.back_on_footer then return "back" end
            for _, r in ipairs(hits) do
                if a >= r.x and a < r.x + r.w and b >= r.y and b < r.y + r.h then
                    if focus == r.idx then return "open", cards[r.idx].it, cards[r.idx] end
                    focus = r.idx
                    break
                end
            end
            -- tapping a section header opens it fully
            for si, s in ipairs(sections) do
                if b == top + (s.y - 1) - scroll and s.query and opts.open_section then
                    return "section", s
                end
            end
        elseif ev == "scroll" then
            focus = math.max(1, math.min(#cards, focus + a * cols))
        elseif ev == "key" then
            local dir = H.ARROWS[a]
            if dir and #cards > 0 then
                local cur = cards[focus]
                local best
                for ci, c in ipairs(cards) do
                    local dc, dv = c.col - cur.col, c.vy - cur.vy
                    local ok, main, cross
                    if dir == "left" then ok, main, cross = (dv == 0 and dc < 0), -dc, 0
                    elseif dir == "right" then ok, main, cross = (dv == 0 and dc > 0), dc, 0
                    elseif dir == "up" then ok, main, cross = dv < 0, -dv, math.abs(dc)
                    else ok, main, cross = dv > 0, dv, math.abs(dc) end
                    if ok then
                        local score = main * 10 + cross
                        if not best or score < best.score then best = { ci = ci, score = score } end
                    end
                end
                if best then focus = best.ci end
            elseif (a == keys.enter or a == keys.space) and cards[focus] then
                return "open", cards[focus].it, cards[focus]
            elseif a == keys.backspace or a == keys.escape or a == keys.q then
                return "back"
            elseif a == keys.s then
                return "search"
            elseif a == keys.tab and #cards > 0 then
                focus = (focus % #cards) + 1
            elseif a == keys.m and opts.open_section and cards[focus] then
                return "section", sections[cards[focus].s]
            end
        elseif ev == "char" then
            return "search", a
        elseif ev == "timer" and a == timer then
            net:tick()
            timer = os.startTimer(1)
        end
        -- "net" / "redraw" just loop and repaint
    end
end

-- ---------------------------------------------------------------------------
-- Detail page
-- ---------------------------------------------------------------------------

function Gallery.detail(ctx, it)
    local net = ctx.net
    local focus = 1
    local timer = os.startTimer(1)
    local asked = false
    while true do
        local w, h = term.getSize()
        local cwid = math.min(w - 2, 40)
        local pxw = cwid * 2
        local rows = math.floor(pxw * 9 / 16 / 3 + 0.5)
        if h < 20 then rows = 0 end
        rows = math.min(rows, h - 9)
        H.setc(H.THEME.text, H.THEME.bg)
        term.clear()
        H.bar(1, w, "Video", H.clock_text())
        local y = 3
        if rows >= 3 then
            local img = net:cached(it.id, pxw, rows * 3)
            local x = math.floor((w - cwid) / 2) + 1
            if img then
                H.net.draw(term, img, x, y, cwid, rows)
            else
                H.fill(x, y, cwid, rows, H.THEME.tile)
                H.put(x, y + math.floor(rows / 2), H.centered("loading cover ...", cwid), H.THEME.dim, H.THEME.tile)
                if not asked then asked = true; net:thumb(it.id, pxw, rows * 3, function() end) end
            end
            y = y + rows + 1
        end
        H.put(2, y, H.clip(it.name, w - 2), H.THEME.text, H.THEME.bg)
        H.put(2, y + 1, H.clip(it.artist, w - 2), H.THEME.dim, H.THEME.bg)
        local btns = { { label = "Play", act = "play" } }
        if ctx.enqueue then btns[#btns + 1] = { label = "Add to queue", act = "queue" } end
        btns[#btns + 1] = { label = "Back", act = "back" }
        local bx, by, hits = 2, y + 3, {}
        for i, b in ipairs(btns) do
            local bw = #b.label + 4
            if bx + bw > w then bx, by = 2, by + 2 end
            local f = (i == focus)
            H.fill(bx, by, bw, 1, f and H.THEME.tileFocus or H.THEME.tile)
            H.put(bx + 2, by, b.label, f and H.THEME.tileFocusText or H.THEME.text, f and H.THEME.tileFocus or H.THEME.tile)
            hits[i] = { x = bx, y = by, w = bw, h = 1 }
            bx = bx + bw + 1
        end
        local ev, a, b = H.pull()
        local chosen
        if ev == "tap" then
            for i, r in ipairs(hits) do
                if a >= r.x and a < r.x + r.w and b == r.y then focus = i; chosen = btns[i].act end
            end
        elseif ev == "key" then
            if a == keys.left then focus = math.max(1, focus - 1)
            elseif a == keys.right or a == keys.tab then focus = (focus % #btns) + 1
            elseif a == keys.enter or a == keys.space then chosen = btns[focus].act
            elseif a == keys.backspace or a == keys.escape then chosen = "back" end
        elseif ev == "timer" and a == timer then
            net:tick()
            timer = os.startTimer(1)
        end
        if chosen == "play" then return "play", watch_url(it.id)
        elseif chosen == "queue" then
            ctx.enqueue(watch_url(it.id), it.name)
            if ctx.toast then ctx.toast("Queued: " .. H.clip(it.name, 24), "ok") end
        elseif chosen == "back" then return "back" end
    end
end

-- ---------------------------------------------------------------------------
-- Entry points
-- ---------------------------------------------------------------------------

local function open_item(ctx, it)
    local act, url = Gallery.detail(ctx, it)
    if act == "play" then return "play", url end
end

--- Search results as a thumbnail grid. Returns "play", url | "back" | "fallback".
function Gallery.results(ctx, query)
    local sec = { title = 'Results for "' .. tostring(query) .. '"', query = query, limit = 24 }
    -- fail fast to the old direct-search path when the search service is down
    while true do
        local res, it, card = grid(ctx, "Search", { sec }, { hint = "Enter opens  Esc back  S new search", fallback_on_error = true })
        if res == "fallback" then return "fallback" end
        if res == "open" then
            local act, url = open_item(ctx, it)
            if act == "play" then return "play", url end
        elseif res == "back" then
            return "back"
        elseif res == "search" then
            return "search", it
        end
    end
end

--- Home-style shelves. Returns "play", url | "back" | "search", seed.
function Gallery.shelves(ctx)
    local sections = {}
    local recent = {}
    for _, e in ipairs(ctx.history and ctx.history.items or {}) do
        local id = yt_id(e.url)
        if id and #recent < 6 then recent[#recent + 1] = { id = id, name = e.title or e.url, artist = "Recently played" } end
    end
    if #recent > 0 then sections[#sections + 1] = { title = "Recently played", items = recent } end
    for _, q in ipairs(ctx.shelves or {}) do
        sections[#sections + 1] = { title = q, query = q, limit = 6 }
    end
    while true do
        local res, it = grid(ctx, "Gallery", sections, { hint = "Enter opens  M more  S search  Esc back", open_section = true })
        if res == "open" then
            local act, url = open_item(ctx, it)
            if act == "play" then return "play", url end
        elseif res == "section" and it and it.query then
            local r, v = Gallery.results(ctx, it.query)
            if r == "play" then return "play", v
            elseif r == "search" then return "search", v end
        elseif res == "back" then
            return "back"
        elseif res == "search" then
            return "search", it
        end
    end
end

return Gallery
