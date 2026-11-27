--[[ ycui - "smart TV" interface for the YouCube player.

  - Home screen with tiles (Search / Recent / Settings / Power off)
  - Search page with a full on-screen keyboard and history suggestions
  - History of played URLs and search terms (never local files)
  - Settings page (name, redstone output, pairing)
  - Toast overlay (top right) that works on top of everything, video included

  Everything draws on the current `term`, so it works on a redirected monitor.
  Input: touch (monitor_touch / mouse_click), arrow keys + Enter, a real
  keyboard, or keystrokes injected by a paired remote.
]]

local UI = {}

local C = colors
local THEME = {
    bg = C.black, bar = C.gray, barText = C.white, accent = C.cyan,
    text = C.white, dim = C.lightGray,
    tile = C.gray, tileFocus = C.cyan, tileFocusText = C.black,
    key = C.gray, keySpecial = C.lightGray, keyText = C.white, keySpecialText = C.black,
    input = C.white, inputText = C.black,
    ok = C.green, warn = C.orange, bad = C.red, info = C.blue,
}

-- ---------------------------------------------------------------------------
-- Drawing helpers
-- ---------------------------------------------------------------------------

local function setc(fg, bg)
    if fg then term.setTextColor(fg) end
    if bg then term.setBackgroundColor(bg) end
end

local function put(x, y, text, fg, bg)
    if y < 1 then return end
    term.setCursorPos(x, y)
    setc(fg, bg)
    term.write(text)
end

local function fill(x, y, w, h, bg)
    if w <= 0 then return end
    setc(nil, bg)
    local s = string.rep(" ", w)
    for r = 0, h - 1 do
        term.setCursorPos(x, y + r)
        term.write(s)
    end
end

local function clip(s, n)
    s = tostring(s or "")
    if n <= 0 then return "" end
    if #s <= n then return s end
    if n <= 1 then return s:sub(1, n) end
    return s:sub(1, n - 1) .. "~"
end

local function centered(text, w)
    text = clip(text, w)
    local pad = math.floor((w - #text) / 2)
    return string.rep(" ", pad) .. text .. string.rep(" ", w - #text - pad)
end

local function bar(y, w, left, right, bg)
    fill(1, y, w, 1, bg or THEME.bar)
    put(2, y, clip(left, w - 2), THEME.barText, bg or THEME.bar)
    if right and right ~= "" then
        put(math.max(2, w - #right), y, right, THEME.barText, bg or THEME.bar)
    end
end

local function clock_text()
    local ok, t = pcall(function() return textutils.formatTime(os.time(), false) end)
    return ok and t or ""
end

-- ---------------------------------------------------------------------------
-- Input: normalise touch / mouse / keys into a handful of events
-- ---------------------------------------------------------------------------

-- returns: "tap", x, y | "scroll", dir | "key", code | "char", text | "timer", id | "redraw"
local function pull()
    while true do
        local e = table.pack(os.pullEvent())
        local ev = e[1]
        if ev == "monitor_touch" then return "tap", e[3], e[4]
        elseif ev == "mouse_click" then return "tap", e[3], e[4]
        elseif ev == "mouse_scroll" then return "scroll", e[2]
        elseif ev == "key" then return "key", e[2]
        elseif ev == "char" or ev == "paste" then return "char", e[2]
        elseif ev == "timer" then return "timer", e[2]
        elseif ev == "term_resize" or ev == "monitor_resize" or ev == "ycui:redraw" then return "redraw"
        end
    end
end

local function hit(items, x, y)
    for i, it in ipairs(items) do
        if it.focusable ~= false and x >= it.x and x < it.x + it.w and y >= it.y and y < it.y + it.h then
            return i
        end
    end
end

local function nearest(items, cur, dir)
    local c = items[cur]
    if not c then return 1 end
    local cx, cy = c.x + c.w / 2, c.y + c.h / 2
    local best, bestScore
    for i, it in ipairs(items) do
        if i ~= cur and it.focusable ~= false then
            local dx, dy = it.x + it.w / 2 - cx, it.y + it.h / 2 - cy
            local ok, main, cross
            if dir == "up" then ok, main, cross = dy < 0, -dy, math.abs(dx)
            elseif dir == "down" then ok, main, cross = dy > 0, dy, math.abs(dx)
            elseif dir == "left" then ok, main, cross = dx < 0, -dx, math.abs(dy)
            else ok, main, cross = dx > 0, dx, math.abs(dy) end
            if ok then
                local score = main + cross * 2
                if not bestScore or score < bestScore then best, bestScore = i, score end
            end
        end
    end
    return best or cur
end

local ARROWS = { [keys.up] = "up", [keys.down] = "down", [keys.left] = "left", [keys.right] = "right" }

-- ---------------------------------------------------------------------------
-- History (URLs and search terms; never files)
-- ---------------------------------------------------------------------------

local FILE_EXT = { dfpwm = 1, nfp = 1, ["32vid"] = 1, lua = 1, txt = 1, nbs = 1, json = 1, wav = 1,
    mp3 = 1, mp4 = 1, ogg = 1, flac = 1, nft = 1, bimg = 1 }

local function is_file_like(s)
    if s:find("^https?://") then return false end
    if s:find("^[/~]") or s:find("^%.%.?/") or s:find("^%a:\\") then return true end
    local ext = s:match("%.([%w]+)$")
    if ext and FILE_EXT[ext:lower()] and not s:find("%s") then return true end
    if fs and fs.exists and not s:find("%s") and pcall(fs.exists, s) and fs.exists(s) then return true end
    return false
end

local History = {}
History.__index = History

function UI.history_new(path, max)
    local self = setmetatable({ items = {}, path = path or "/youcube_history.json", max = max or 40 }, History)
    if fs.exists(self.path) then
        local f = fs.open(self.path, "r")
        local data = f and textutils.unserializeJSON(f.readAll())
        if f then f.close() end
        if type(data) == "table" then
            for _, e in ipairs(data) do
                if type(e) == "table" and type(e.url) == "string" and not is_file_like(e.url) then
                    self.items[#self.items + 1] = { url = e.url, title = e.title, plays = e.plays or 1 }
                end
            end
        end
    end
    return self
end

function History:save()
    local f = fs.open(self.path, "w")
    if not f then return end
    f.write(textutils.serializeJSON(self.items))
    f.close()
end

--- Remember something the viewer played. Local files are ignored.
function History:note(input, title)
    input = tostring(input or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if input == "" or is_file_like(input) then return false end
    local entry
    for i, e in ipairs(self.items) do
        if e.url == input then entry = table.remove(self.items, i); break end
    end
    entry = entry or { url = input, plays = 0 }
    entry.plays = entry.plays + 1
    if title and title ~= "" then entry.title = tostring(title) end
    table.insert(self.items, 1, entry)
    while #self.items > self.max do table.remove(self.items) end
    self:save()
    return true
end

--- Attach a title to an entry once the server told us what it is.
function History:set_title(input, title)
    for _, e in ipairs(self.items) do
        if e.url == input and title and title ~= "" then
            e.title = tostring(title)
            self:save()
            return
        end
    end
end

function History:title_of(input)
    for _, e in ipairs(self.items) do
        if e.url == input and e.title and e.title ~= "" then return e.title end
    end
    return input
end

function History:remove(i)
    if self.items[i] then table.remove(self.items, i); self:save() end
end

function History:clear()
    self.items = {}
    self:save()
end

local function entry_label(e)
    return (e.title and e.title ~= "") and e.title or e.url
end

local function suggestions_for(hist, text)
    local out, q = {}, tostring(text or ""):lower()
    for _, e in ipairs(hist.items) do
        local label = entry_label(e)
        if q == "" or label:lower():find(q, 1, true) or e.url:lower():find(q, 1, true) then
            out[#out + 1] = { label = label, value = e.url, sub = e.url }
            if #out >= 8 then break end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Toast overlay
-- ---------------------------------------------------------------------------

local toast_state = nil

local function toast_colors(kind)
    if kind == "ok" then return C.white, THEME.ok
    elseif kind == "bad" then return C.white, THEME.bad
    elseif kind == "warn" then return C.black, THEME.warn
    end
    return C.white, THEME.info
end

--- Show a message in the top right corner for a few seconds.
function UI.toast(text, kind, seconds)
    if toast_state and toast_state.saved then
        -- put the old row back before replacing the toast
        pcall(function()
            term.setCursorPos(1, 1)
            term.blit(toast_state.saved[1], toast_state.saved[2], toast_state.saved[3])
        end)
    end
    toast_state = { text = tostring(text), kind = kind or "info", untilT = os.clock() + (seconds or 3.5) }
end

local function toast_draw(t)
    local w = term.getSize()
    local fg, bg = toast_colors(t.kind)
    local label = " \7 " .. clip(t.text, math.max(1, w - 6)) .. " "
    local x = math.max(1, w - #label + 1)
    term.setCursorPos(x, 1)
    term.setTextColor(fg)
    term.setBackgroundColor(bg)
    term.write(label)
end

--- Background thread: run for the whole program, in parallel with everything.
function UI.toast_thread()
    while true do
        sleep(0.15)
        local t = toast_state
        if t then
            if os.clock() < t.untilT then
                if not t.saved then
                    pcall(function()
                        local a, b, c = term.getLine(1)
                        if a then t.saved = { a, b, c } end
                    end)
                end
                toast_draw(t)
            else
                if t.saved then
                    pcall(function()
                        term.setCursorPos(1, 1)
                        term.blit(t.saved[1], t.saved[2], t.saved[3])
                    end)
                end
                toast_state = nil
                os.queueEvent("ycui:redraw")
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- On-screen keyboard
-- ---------------------------------------------------------------------------

local function chars(str, upper)
    local t = {}
    for ch in str:gmatch(".") do
        local v = upper and ch:upper() or ch
        t[#t + 1] = { kind = "char", label = v, value = v, u = 1 }
    end
    return t
end

local function keyboard_rows(layer)
    local rows = {}
    local back = { kind = "back", label = "<-", u = 1.5, special = true }
    local to_sym = { kind = "layer", label = (layer == "sym") and "abc" or "?123",
        value = (layer == "sym") and "lower" or "sym", u = 1.5, special = true }
    local up = (layer == "upper")
    rows[1] = chars("1234567890")
    if layer == "sym" then
        rows[2] = chars("@#%&+=_-~$")
        rows[3] = chars(":/?!;'\"()")
        rows[4] = { { kind = "layer", label = "abc", value = "lower", u = 1.5, special = true } }
        for _, k in ipairs(chars("[]{}<>|")) do rows[4][#rows[4] + 1] = k end
        rows[4][#rows[4] + 1] = back
    else
        rows[2] = chars("qwertyuiop", up)
        rows[3] = chars("asdfghjkl", up)
        rows[4] = { { kind = "shift", label = "Sh", u = 1.5, special = true, active = up } }
        for _, k in ipairs(chars("zxcvbnm", up)) do rows[4][#rows[4] + 1] = k end
        rows[4][#rows[4] + 1] = back
    end
    rows[5] = {
        to_sym,
        { kind = "char", label = "-", value = "-", u = 1 },
        { kind = "space", label = "space", u = 3.5 },
        { kind = "char", label = ".", value = ".", u = 1 },
        { kind = "char", label = "/", value = "/", u = 1 },
        { kind = "enter", label = "Go", u = 2, special = true, go = true },
    }
    return rows
end

local QUICK = {
    { label = "https://", kind = "insert", value = "https://" },
    { label = "www.", kind = "insert", value = "www." },
    { label = ".com", kind = "insert", value = ".com" },
    { label = "<", kind = "left" },
    { label = ">", kind = "right" },
    { label = "Clr", kind = "clear" },
}

-- Lays the keyboard out in the rectangle at the bottom of the screen and
-- returns the list of drawable/clickable keys plus its top row.
local function keyboard_layout(w, h, layer, kh, with_quick)
    local keys_out = {}
    local rows = keyboard_rows(layer)
    local top = h - (#rows * kh + (with_quick and 1 or 0)) + 1
    local uw = w / 10
    local drawn_h = (kh >= 3) and (kh - 1) or kh

    local y = top
    if with_quick then
        local qw = w / #QUICK
        for i, q in ipairs(QUICK) do
            local x1 = math.floor((i - 1) * qw + 0.5) + 1
            local x2 = math.floor(i * qw + 0.5) - 1
            keys_out[#keys_out + 1] = { x = x1, y = y, w = math.max(1, x2 - x1 + 1), h = 1,
                label = q.label, kind = q.kind, value = q.value, special = true }
        end
        y = y + 1
    end
    for _, row in ipairs(rows) do
        local total = 0
        for _, k in ipairs(row) do total = total + k.u end
        local cu = (10 - total) / 2
        for _, k in ipairs(row) do
            local x1 = math.floor(cu * uw + 0.5) + 1
            local x2 = math.floor((cu + k.u) * uw + 0.5) - 1
            local key = { x = x1, y = y, w = math.max(1, x2 - x1 + 1), h = drawn_h }
            for kk, vv in pairs(k) do key[kk] = vv end
            keys_out[#keys_out + 1] = key
            cu = cu + k.u
        end
        y = y + kh
    end
    return keys_out, top
end

local function draw_key(k, focused)
    local bg = k.special and THEME.keySpecial or THEME.key
    local fg = k.special and THEME.keySpecialText or THEME.keyText
    if k.go then bg, fg = THEME.ok, C.white end
    if k.active then bg, fg = THEME.accent, C.black end
    if focused then bg, fg = THEME.tileFocus, THEME.tileFocusText end
    fill(k.x, k.y, k.w, k.h, bg)
    put(k.x, k.y + math.floor((k.h - 1) / 2), centered(k.label, k.w), fg, bg)
end

-- ---------------------------------------------------------------------------
-- Text entry page (search box + suggestions + keyboard)
-- ---------------------------------------------------------------------------

--[[ o.title, o.text, o.hint, o.suggest(text) -> { {label, value, sub} }
  returns "submit", text | "pick", value | nil (cancelled) ]]
function UI.text_entry(o)
    local text = tostring(o.text or "")
    local cur = #text
    local layer = "lower"
    local sug_focus = nil
    local timer = os.startTimer(0.5)

    while true do
        local w, h = term.getSize()
        local kh = (h >= 30) and 3 or ((h >= 20) and 2 or 1)
        local with_quick = h >= 16
        local kb, kb_top = keyboard_layout(w, h, layer, kh, with_quick)
        local sugs = o.suggest and o.suggest(text) or {}
        local sug_rows = math.max(0, kb_top - 5)
        local sug_h = (h >= 24) and 2 or 1
        local max_sugs = math.min(#sugs, math.floor(sug_rows / sug_h))
        if sug_focus and sug_focus > max_sugs then sug_focus = max_sugs > 0 and max_sugs or nil end

        setc(THEME.text, THEME.bg)
        term.clear()
        bar(1, w, o.title or "Search", clock_text())

        -- input box
        local box_w = w - 2
        fill(2, 3, box_w, 1, THEME.input)
        local visible = box_w - 2
        local start = math.max(0, cur - visible + 1)
        local shown = text:sub(start + 1, start + visible)
        put(3, 3, shown, THEME.inputText, THEME.input)
        local cx = 3 + (cur - start)
        if cx <= 2 + box_w - 1 then
            put(cx, 3, (text:sub(cur + 1, cur + 1) ~= "") and text:sub(cur + 1, cur + 1) or " ", C.white, C.black)
        end
        put(2, 4, clip(o.hint or "Enter = go   Esc = back", w - 2), THEME.dim, THEME.bg)

        -- suggestions
        local sug_items = {}
        for i = 1, max_sugs do
            local y = 5 + (i - 1) * sug_h
            local focused = (sug_focus == i)
            local bg = focused and THEME.tileFocus or THEME.bg
            local fg = focused and THEME.tileFocusText or THEME.text
            fill(1, y, w, sug_h, bg)
            put(2, y, clip(sugs[i].label, w - 2), fg, bg)
            if sug_h > 1 and sugs[i].sub and sugs[i].sub ~= sugs[i].label then
                put(3, y + 1, clip(sugs[i].sub, w - 3), focused and fg or THEME.dim, bg)
            end
            sug_items[#sug_items + 1] = { x = 1, y = y, w = w, h = sug_h, value = sugs[i].value }
        end

        for _, k in ipairs(kb) do draw_key(k, false) end

        local ev, a, b = pull()
        local function insert(s)
            text = text:sub(1, cur) .. s .. text:sub(cur + 1)
            cur = cur + #s
        end

        local result_kind, result_val
        if ev == "char" then
            insert(a)
            sug_focus = nil
        elseif ev == "key" then
            if a == keys.enter then
                if sug_focus and sug_items[sug_focus] then
                    result_kind, result_val = "pick", sug_items[sug_focus].value
                elseif text ~= "" then
                    result_kind, result_val = "submit", text
                end
            elseif a == keys.escape then
                return nil
            elseif a == keys.backspace then
                if cur > 0 then text = text:sub(1, cur - 1) .. text:sub(cur + 1); cur = cur - 1 end
            elseif a == keys.delete then
                text = text:sub(1, cur) .. text:sub(cur + 2)
            elseif a == keys.left then cur = math.max(0, cur - 1)
            elseif a == keys.right then cur = math.min(#text, cur + 1)
            elseif a == keys.home then cur = 0
            elseif a == keys["end"] then cur = #text
            elseif a == keys.down then
                if max_sugs > 0 then sug_focus = math.min(max_sugs, (sug_focus or 0) + 1) end
            elseif a == keys.up then
                if sug_focus then sug_focus = (sug_focus > 1) and (sug_focus - 1) or nil end
            end
        elseif ev == "tap" then
            local si = hit(sug_items, a, b)
            if si then
                result_kind, result_val = "pick", sug_items[si].value
            else
                local ki = hit(kb, a, b)
                if ki then
                    local k = kb[ki]
                    if k.kind == "char" then
                        insert(k.value)
                        if layer == "upper" then layer = "lower" end
                    elseif k.kind == "space" then insert(" ")
                    elseif k.kind == "insert" then insert(k.value)
                    elseif k.kind == "back" then
                        if cur > 0 then text = text:sub(1, cur - 1) .. text:sub(cur + 1); cur = cur - 1 end
                    elseif k.kind == "shift" then layer = (layer == "upper") and "lower" or "upper"
                    elseif k.kind == "layer" then layer = k.value
                    elseif k.kind == "left" then cur = math.max(0, cur - 1)
                    elseif k.kind == "right" then cur = math.min(#text, cur + 1)
                    elseif k.kind == "clear" then text, cur = "", 0
                    elseif k.kind == "enter" and text ~= "" then
                        result_kind, result_val = "submit", text
                    end
                elseif b == 1 then
                    return nil -- tapping the title bar goes back
                end
            end
        elseif ev == "timer" and a == timer then
            timer = os.startTimer(0.5)
        end
        if result_kind then return result_kind, result_val end
    end
end

--- Full screen "please wait" splash; leaves the cursor below the message.
function UI.loading(text)
    local w, h = term.getSize()
    setc(THEME.text, THEME.bg)
    term.clear()
    bar(1, w, "YouCube TV", clock_text())
    local y = math.max(3, math.floor(h / 2))
    put(1, y, centered(text, w), THEME.accent, THEME.bg)
    term.setCursorPos(1, y + 2)
    term.setTextColor(THEME.text)
end

-- ---------------------------------------------------------------------------
-- Confirm dialog
-- ---------------------------------------------------------------------------

function UI.confirm(title, message)
    local focus = 2
    while true do
        local w, h = term.getSize()
        setc(THEME.text, THEME.bg)
        term.clear()
        bar(1, w, title, clock_text())
        -- word wrap
        local y, line = 3, ""
        local function flush() put(2, y, line, THEME.text, THEME.bg); y = y + 1; line = "" end
        for word in tostring(message):gmatch("%S+") do
            if #line + #word + 1 > w - 2 and line ~= "" then flush() end
            line = (line == "") and word or (line .. " " .. word)
        end
        if line ~= "" then flush() end
        local by = math.min(h - 1, y + 1)
        local bw = math.max(6, math.floor((w - 6) / 2))
        local items = {
            { x = 2, y = by, w = bw, h = 1, label = "Yes", value = true },
            { x = 4 + bw, y = by, w = bw, h = 1, label = "No", value = false },
        }
        for i, it in ipairs(items) do
            local f = (i == focus)
            fill(it.x, it.y, it.w, 1, f and THEME.tileFocus or THEME.tile)
            put(it.x, it.y, centered(it.label, it.w), f and THEME.tileFocusText or C.white, f and THEME.tileFocus or THEME.tile)
        end
        local ev, a, b = pull()
        if ev == "tap" then
            local i = hit(items, a, b)
            if i then return items[i].value end
        elseif ev == "key" then
            if a == keys.left or a == keys.right or a == keys.tab then focus = 3 - focus
            elseif a == keys.enter or a == keys.space then return items[focus].value
            elseif a == keys.escape or a == keys.n then return false
            elseif a == keys.y then return true end
        end
    end
end

-- ---------------------------------------------------------------------------
-- History page
-- ---------------------------------------------------------------------------

local function page_history(ctx)
    local hist = ctx.history
    local sel, top = 1, 0
    while true do
        local w, h = term.getSize()
        local rows = (h >= 14) and 2 or 1
        local view = math.max(1, math.floor((h - 3) / rows))
        if sel > #hist.items then sel = #hist.items end
        if sel < 1 then sel = 1 end
        if sel - 1 < top then top = sel - 1 end
        if sel > top + view then top = sel - view end
        top = math.max(0, math.min(top, math.max(0, #hist.items - view)))

        setc(THEME.text, THEME.bg)
        term.clear()
        bar(1, w, "Recent", clock_text())
        local items = {}
        if #hist.items == 0 then
            put(2, 3, "Nothing played yet.", THEME.dim, THEME.bg)
        end
        for i = 1, view do
            local idx = top + i
            local e = hist.items[idx]
            if not e then break end
            local y = 2 + (i - 1) * rows
            local focused = (idx == sel)
            local bg = focused and THEME.tileFocus or THEME.bg
            local fg = focused and THEME.tileFocusText or THEME.text
            fill(1, y, w, rows, bg)
            put(2, y, clip(entry_label(e), w - 6), fg, bg)
            if rows > 1 and e.url ~= entry_label(e) then
                put(3, y + 1, clip(e.url, w - 4), focused and fg or THEME.dim, bg)
            end
            put(w - 2, y, "[x]", focused and fg or THEME.bad, bg)
            items[#items + 1] = { x = 1, y = y, w = w - 3, h = rows, idx = idx, kind = "row" }
            items[#items + 1] = { x = w - 2, y = y, w = 3, h = 1, idx = idx, kind = "del" }
        end
        -- footer buttons
        local bw = math.floor((w - 3) / 2)
        local back = { x = 2, y = h, w = bw, h = 1, kind = "back" }
        local clearb = { x = 3 + bw, y = h, w = bw, h = 1, kind = "clear" }
        fill(back.x, back.y, back.w, 1, THEME.tile); put(back.x, back.y, centered("Back", back.w), C.white, THEME.tile)
        fill(clearb.x, clearb.y, clearb.w, 1, THEME.tile); put(clearb.x, clearb.y, centered("Clear all", clearb.w), C.white, THEME.tile)
        items[#items + 1] = back
        items[#items + 1] = clearb

        local ev, a, b = pull()
        if ev == "tap" then
            local i = hit(items, a, b)
            if i then
                local it = items[i]
                if it.kind == "row" then return "play", hist.items[it.idx].url
                elseif it.kind == "del" then hist:remove(it.idx)
                elseif it.kind == "back" then return nil
                elseif it.kind == "clear" then
                    if #hist.items > 0 and UI.confirm("Clear history", "Remove every saved link?") then hist:clear() end
                end
            elseif b == 1 then return nil end
        elseif ev == "scroll" then
            sel = math.max(1, math.min(#hist.items, sel + a))
        elseif ev == "key" then
            if a == keys.up then sel = math.max(1, sel - 1)
            elseif a == keys.down then sel = math.min(#hist.items, sel + 1)
            elseif a == keys.enter or a == keys.space then
                if hist.items[sel] then return "play", hist.items[sel].url end
            elseif a == keys.delete or a == keys.d then hist:remove(sel)
            elseif a == keys.escape or a == keys.backspace then return nil end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Settings page
-- ---------------------------------------------------------------------------

local RS_SIDES = { "off", "top", "bottom", "left", "right", "front", "back" }

local function cycle(list, cur, dir)
    local idx = 1
    for i, v in ipairs(list) do if v == cur then idx = i; break end end
    return list[((idx - 1 + (dir or 1)) % #list) + 1]
end

local function page_settings(ctx)
    local focus = 1
    local timer = os.startTimer(1)
    while true do
        local w, h = term.getSize()
        local t = ctx.theater
        local pair_value
        if t:is_paired() then
            pair_value = "Paired: " .. tostring(t.hub or "hub")
        else
            local info = t:pairing_info()
            pair_value = info and ("Code " .. info.code) or "Not paired"
        end
        local rows = {
            { key = "name", label = "Theater name", value = ctx.get("name") },
            { key = "rs_side", label = "Redstone output side", value = ctx.get("rs_side") },
            { key = "rs_when", label = "Redstone ON while", value = ctx.get("rs_when") },
            { key = "pair", label = "Pairing", value = pair_value },
            { key = "net", label = "Network", value = ctx.network, readonly = true },
        }
        setc(THEME.text, THEME.bg)
        term.clear()
        bar(1, w, "Settings", clock_text())
        local items = {}
        local rh = (h >= 14) and 2 or 1
        for i, r in ipairs(rows) do
            local y = 2 + (i - 1) * rh
            local f = (i == focus)
            local bg = f and THEME.tileFocus or THEME.bg
            local fg = f and THEME.tileFocusText or THEME.text
            fill(1, y, w, rh, bg)
            put(2, y, clip(r.label, math.floor(w / 2) - 1), fg, bg)
            local val = clip(tostring(r.value), w - math.floor(w / 2) - 1)
            put(w - #val, y, val, f and fg or THEME.accent, bg)
            items[#items + 1] = { x = 1, y = y, w = w, h = rh, row = r }
        end
        local back = { x = 2, y = h, w = w - 2, h = 1, back = true }
        fill(back.x, back.y, back.w, 1, THEME.tile)
        put(back.x, back.y, centered("Back", back.w), C.white, THEME.tile)
        items[#items + 1] = back

        local function activate(it)
            if it.back then return true end
            local r = it.row
            if r.readonly then return end
            if r.key == "name" then
                local kind, v = UI.text_entry({ title = "Theater name", text = ctx.get("name"),
                    hint = "Name shown in relaycon. Enter = save" })
                if kind == "submit" then ctx.set("name", v) end
            elseif r.key == "rs_side" then
                ctx.set("rs_side", cycle(RS_SIDES, ctx.get("rs_side"), 1))
            elseif r.key == "rs_when" then
                ctx.set("rs_when", (ctx.get("rs_when") == "playing") and "idle" or "playing")
            elseif r.key == "pair" then
                if t:is_paired() then
                    if UI.confirm("Unpair", "Disconnect this theater from " .. tostring(t.hub or "the hub") .. "?") then
                        ctx.set("unpair")
                    end
                else
                    ctx.set("newcode")
                end
            end
        end

        local ev, a, b = pull()
        if ev == "tap" then
            local i = hit(items, a, b)
            if i then focus = i; if activate(items[i]) then return end
            elseif b == 1 then return end
        elseif ev == "key" then
            if a == keys.up then focus = math.max(1, focus - 1)
            elseif a == keys.down then focus = math.min(#items, focus + 1)
            elseif a == keys.enter or a == keys.space then
                if items[focus] and activate(items[focus]) then return end
            elseif a == keys.escape or a == keys.backspace then return end
        elseif ev == "timer" and a == timer then
            timer = os.startTimer(1)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Home screen
-- ---------------------------------------------------------------------------

local TILES = {
    { label = "Search", icon = "(?)", action = "search" },
    { label = "Recent", icon = "[>]", action = "recent" },
    { label = "Settings", icon = "{*}", action = "settings" },
    { label = "Power off", icon = "(o)", action = "exit" },
}

local function status_line(ctx)
    local t = ctx.theater
    if t:is_paired() then
        if t.hub_connected then
            return "\7 Connected to " .. tostring(t.hub or "hub"), THEME.ok
        end
        return "\7 Waiting for " .. tostring(t.hub or "hub") .. "...", THEME.warn
    end
    local info = t:pairing_info()
    if info then
        return "Pairing code " .. info.code .. " (" .. info.seconds .. "s)  - relaycon > Theaters", THEME.accent
    end
    return "Not paired", THEME.dim
end

local function page_home(ctx)
    local focus = 1
    local timer = os.startTimer(1)
    while true do
        local w, h = term.getSize()
        setc(THEME.text, THEME.bg)
        term.clear()
        bar(1, w, "YouCube TV", clock_text())
        put(2, 2, clip(ctx.get("name"), math.floor(w / 3)), THEME.accent, THEME.bg)
        local sl, sc = status_line(ctx)
        local sx = 2 + math.min(#ctx.get("name"), math.floor(w / 3)) + 2
        put(sx, 2, clip(sl, w - sx), sc, THEME.bg)

        local recent = {}
        local want_recent = (h >= 20) and math.min(#ctx.history.items, 3) or 0
        for i = 1, want_recent do recent[i] = ctx.history.items[i] end
        local reserve = (want_recent > 0) and (want_recent + 1) or 0
        local area_top, area_bot = 4, h - 1 - reserve
        local area_h = area_bot - area_top + 1
        local items = {}

        if area_h >= 7 then
            local tw = math.floor((w - 3) / 2)
            local th = math.min(7, math.floor(area_h / 2))
            for i, tile in ipairs(TILES) do
                local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
                items[#items + 1] = { x = 2 + col * (tw + 1), y = area_top + row * (th + 1), w = tw, h = th, tile = tile }
            end
        else
            local tw = math.floor((w - 1) / 4)
            local th = math.max(1, math.min(area_h, 5))
            for i, tile in ipairs(TILES) do
                items[#items + 1] = { x = 1 + (i - 1) * tw, y = area_top, w = tw - 1, h = th, tile = tile }
            end
        end
        for _, it in ipairs(items) do it.kind = "tile" end
        if focus > #items + want_recent then focus = #items + want_recent end

        for i, it in ipairs(items) do
            local f = (i == focus)
            local bg = f and THEME.tileFocus or THEME.tile
            local fg = f and THEME.tileFocusText or C.white
            fill(it.x, it.y, it.w, it.h, bg)
            local mid = it.y + math.floor((it.h - 1) / 2)
            if it.h >= 3 then
                put(it.x, mid - 1, centered(it.tile.icon, it.w), fg, bg)
                put(it.x, mid + 1, centered(it.tile.label, it.w), fg, bg)
            else
                put(it.x, mid, centered(it.tile.label, it.w), fg, bg)
            end
        end

        if want_recent > 0 then
            local y = h - want_recent
            put(2, y - 1, "Recent", THEME.dim, THEME.bg)
            for i, e in ipairs(recent) do
                local it = { x = 1, y = y + i - 1, w = w, h = 1, kind = "recent", url = e.url }
                local idx = #items + 1
                local f = (focus == idx)
                local bg = f and THEME.tileFocus or THEME.bg
                fill(1, it.y, w, 1, bg)
                put(2, it.y, clip(entry_label(e), w - 2), f and THEME.tileFocusText or THEME.text, bg)
                items[idx] = it
            end
        end

        setc(THEME.dim, THEME.bg)
        put(2, h, clip("Arrows + Enter, or touch", w - 2), THEME.dim, THEME.bg)

        local ev, a, b = pull()
        local function activate(it)
            if it.kind == "tile" then return it.tile.action end
            if it.kind == "recent" then return "play", it.url end
        end
        if ev == "tap" then
            local i = hit(items, a, b)
            if i then focus = i; return activate(items[i]) end
        elseif ev == "key" then
            local dir = ARROWS[a]
            if dir then
                focus = nearest(items, focus, dir)
            elseif a == keys.enter or a == keys.space then
                if items[focus] then return activate(items[focus]) end
            elseif a == keys.tab then focus = (focus % #items) + 1
            elseif a == keys.s then return "search"
            elseif a == keys.r then return "recent" end
        elseif ev == "char" then
            -- typing on a keyboard from the home screen jumps straight into search
            return "search", a
        elseif ev == "timer" and a == timer then
            timer = os.startTimer(1)
        end
    end
end

--[[ Runs the home screen until the viewer picks something.
  ctx = {
    theater = Theater, history = History, network = "default",
    get = function(key) ... end,   -- "name" | "rs_side" | "rs_when"
    set = function(key, value) ... end,  -- also "unpair" | "newcode"
  }
  returns "play", urlOrSearch   |   "exit" ]]
function UI.home(ctx)
    local page, seed = "home", nil
    while true do
        if page == "home" then
            local res, extra = page_home(ctx)
            if res == "play" then return "play", extra
            elseif res == "exit" then return "exit"
            elseif res == "search" then page, seed = "search", extra
            elseif res then page = res end
        elseif page == "search" then
            local kind, v = UI.text_entry({
                title = "Search or paste a link", text = seed or "",
                suggest = function(text) return suggestions_for(ctx.history, text) end,
            })
            seed = nil
            if kind then return "play", v end
            page = "home"
        elseif page == "recent" then
            local act, v = page_history(ctx)
            if act == "play" then return "play", v end
            page = "home"
        elseif page == "settings" then
            page_settings(ctx)
            page = "home"
        end
    end
end

UI.RS_SIDES = RS_SIDES
UI._keyboard_layout = keyboard_layout -- exposed for tests
UI.suggestions_for = suggestions_for
UI.is_file_like = is_file_like
return UI
