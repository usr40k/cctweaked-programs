--[[ ycbig - large block-art numbers, percent and progress bars for the TV loader. ]]

local Big = {}

local FONT = {
    ["0"] = { "111", "101", "101", "101", "111" },
    ["1"] = { "010", "110", "010", "010", "111" },
    ["2"] = { "111", "001", "111", "100", "111" },
    ["3"] = { "111", "001", "111", "001", "111" },
    ["4"] = { "101", "101", "111", "001", "001" },
    ["5"] = { "111", "100", "111", "001", "111" },
    ["6"] = { "111", "100", "111", "101", "111" },
    ["7"] = { "111", "001", "010", "010", "010" },
    ["8"] = { "111", "101", "111", "101", "111" },
    ["9"] = { "111", "101", "111", "001", "111" },
    ["%"] = { "101", "001", "010", "100", "101" },
    ["."] = { "0", "0", "0", "0", "1" },
    ["-"] = { "000", "000", "111", "000", "000" },
    [" "] = { "00", "00", "00", "00", "00" },
}

-- each font pixel is `sx` cells wide and 1 tall (cells are ~1:2, so sx=2 looks square)
function Big.width(str, sx)
    sx = sx or 2
    local w = 0
    for i = 1, #str do
        local g = FONT[str:sub(i, i)] or FONT[" "]
        w = w + #g[1] * sx + (i < #str and sx or 0)
    end
    return w
end
Big.height = 5

function Big.text(t, x, y, str, color, sx, bg)
    sx = sx or 2
    local cx = x
    for i = 1, #str do
        local g = FONT[str:sub(i, i)] or FONT[" "]
        for r = 1, 5 do
            local row = g[r]
            for c = 1, #row do
                if row:sub(c, c) == "1" then
                    t.setCursorPos(cx + (c - 1) * sx, y + r - 1)
                    t.setBackgroundColor(color)
                    t.write((" "):rep(sx))
                end
            end
        end
        cx = cx + #g[1] * sx + sx
    end
end

--- Thick progress bar (3 rows). pct 0..100, or nil for an indeterminate sweep (use `phase`).
function Big.bar(t, x, y, w, pct, fg, bg, phase)
    for r = 0, 2 do
        t.setCursorPos(x, y + r)
        t.setBackgroundColor(bg)
        t.setTextColor(fg)
        t.write((" "):rep(w))
    end
    local filled
    if pct then
        filled = math.max(0, math.min(100, pct)) / 100 * w
        local full = math.floor(filled)
        local half = (filled - full) >= 0.5
        for r = 0, 2 do
            t.setCursorPos(x, y + r)
            t.setBackgroundColor(fg)
            t.write((" "):rep(full))
            if half and full < w then
                t.setBackgroundColor(bg)
                t.setTextColor(fg)
                t.write("\x95")
            end
        end
    else
        local seg = math.max(4, math.floor(w / 5))
        local pos = math.floor(((phase or 0) % 1) * (w + seg)) - seg
        local a, b = math.max(0, pos), math.min(w, pos + seg)
        if b > a then
            for r = 0, 2 do
                t.setCursorPos(x + a, y + r)
                t.setBackgroundColor(fg)
                t.write((" "):rep(b - a))
            end
        end
    end
end

--- Pull a percentage out of a server status line ("Downloading 45.3%").
function Big.parse_pct(msg)
    if type(msg) ~= "string" then return nil end
    local n = msg:match("(%d+%.?%d*)%s*%%")
    n = tonumber(n)
    if n and n >= 0 and n <= 100 then return n end
    return nil
end

--[[ Full loader screen.
  s = { title, status, pct (nil = indeterminate), phase (0..1 animation), step = "Searching", steps = {..}, thumb = bimg,
        draw_thumb = function(t, img, x, y, w, h) }
]]
function Big.screen(t, s, theme)
    local w, h = t.getSize()
    theme = theme or { bg = colors.black, fg = colors.cyan, dim = colors.lightGray, text = colors.white, track = colors.gray }
    t.setBackgroundColor(theme.bg)
    t.setTextColor(theme.text)
    t.clear()

    local top = 2
    if s.thumb and s.draw_thumb and h >= 22 then
        local tw = s.draw_thumb(t, s.thumb, 1, 1, w, 9) or 0
        top = 11
        if tw == 0 then top = 2 end
    end

    local title = tostring(s.title or "")
    if #title > w - 2 then title = title:sub(1, w - 5) .. "..." end
    t.setCursorPos(math.max(1, math.floor((w - #title) / 2) + 1), top)
    t.setTextColor(theme.text)
    t.write(title)

    local label = s.pct and string.format("%d%%", math.floor(s.pct + 0.5)) or ""
    local sx = (Big.width(label, 2) + 2 <= w) and 2 or 1
    local bh = 5
    local free = h - top - 6
    local y = top + 2 + math.max(0, math.floor((free - bh - 4) / 2))
    if label ~= "" and y + bh + 4 <= h then
        local lw = Big.width(label, sx)
        Big.text(t, math.floor((w - lw) / 2) + 1, y, label, theme.fg, sx)
    else
        label = ""
    end
    local by = (label ~= "") and (y + bh + 1) or y + 1
    local bw = math.max(10, w - 6)
    if by + 2 <= h then
        Big.bar(t, math.floor((w - bw) / 2) + 1, by, bw, s.pct, theme.fg, theme.track, s.phase)
    end

    t.setBackgroundColor(theme.bg)
    local st = tostring(s.status or "")
    if #st > w - 2 then st = st:sub(1, w - 2) end
    if by + 4 <= h then
        t.setCursorPos(math.max(1, math.floor((w - #st) / 2) + 1), by + 4)
        t.setTextColor(theme.dim)
        t.write(st)
    end
    t.setTextColor(theme.text)
end

return Big
