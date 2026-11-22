--[[ ycauth - hashing, signing and pairing helpers shared by the YouCube
     player and the relaycon hub. Game-grade authentication: it keeps stray or
     foreign devices from controlling a theater, it is not meant to stop a
     determined attacker who can sniff the wireless channel. ]]

local M = {}

-- bit ops: CC:Tweaked ships bit32; fall back to the older `bit` API
local band, bor, bxor, bnot, shr, shl
if bit32 then
    band, bor, bxor, bnot, shr, shl = bit32.band, bit32.bor, bit32.bxor, bit32.bnot, bit32.rshift, bit32.lshift
elseif bit then
    local B = bit
    band, bor, bxor, bnot = B.band, B.bor, B.bxor, B.bnot
    shr = function(a, n) return B.blogic_rshift(a, n) end
    shl = function(a, n) return B.blshift(a, n) end
else
    error("ycauth: no bit library available")
end

local function rotr(x, n)
    return bor(shr(x, n), band(shl(x, 32 - n), 0xffffffff))
end

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
}
local H0 = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }

--- SHA-256 of a string, returned as 64 lowercase hex characters.
function M.sha256(msg)
    local len = #msg
    msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64)
    local bits = len * 8
    msg = msg .. string.char(0, 0, 0, 0,
        band(shr(bits, 24), 255), band(shr(bits, 16), 255), band(shr(bits, 8), 255), band(bits, 255))

    local h = { H0[1], H0[2], H0[3], H0[4], H0[5], H0[6], H0[7], H0[8] }
    local w = {}
    for chunk = 1, #msg, 64 do
        for i = 0, 15 do
            local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
            w[i] = a * 16777216 + b * 65536 + c * 256 + d
        end
        for i = 16, 63 do
            local x, y = w[i - 15], w[i - 2]
            local s0 = bxor(rotr(x, 7), rotr(x, 18), shr(x, 3))
            local s1 = bxor(rotr(y, 17), rotr(y, 19), shr(y, 10))
            w[i] = band(w[i - 16] + s0 + w[i - 7] + s1, 0xffffffff)
        end
        local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
        for i = 0, 63 do
            local S1 = bxor(rotr(e, 6), rotr(e, 11), rotr(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local t1 = band(hh + S1 + ch + K[i + 1] + w[i], 0xffffffff)
            local S0 = bxor(rotr(a, 2), rotr(a, 13), rotr(a, 22))
            local maj = bxor(band(a, b), band(a, c), band(b, c))
            local t2 = band(S0 + maj, 0xffffffff)
            hh, g, f, e = g, f, e, band(d + t1, 0xffffffff)
            d, c, b, a = c, b, a, band(t1 + t2, 0xffffffff)
        end
        h[1] = band(h[1] + a, 0xffffffff); h[2] = band(h[2] + b, 0xffffffff)
        h[3] = band(h[3] + c, 0xffffffff); h[4] = band(h[4] + d, 0xffffffff)
        h[5] = band(h[5] + e, 0xffffffff); h[6] = band(h[6] + f, 0xffffffff)
        h[7] = band(h[7] + g, 0xffffffff); h[8] = band(h[8] + hh, 0xffffffff)
    end
    local out = {}
    for i = 1, 8 do out[i] = string.format("%08x", h[i]) end
    return table.concat(out)
end

--- Milliseconds since epoch (real time, so it agrees between computers).
function M.now()
    if os.epoch then return os.epoch("utc") end
    return os.time() * 1000
end

local seeded = false
local function seed()
    if seeded then return end
    seeded = true
    local id = (os.getComputerID and os.getComputerID()) or 0
    math.randomseed(M.now() + id * 7919 + math.floor((os.clock() or 0) * 1000))
    math.random(); math.random()
end

--- `nbytes` random bytes as hex. Whitened through SHA-256 with clock input.
function M.random_hex(nbytes)
    seed()
    local out = ""
    while #out < nbytes * 2 do
        out = out .. M.sha256(math.random(0, 2147483647) .. ":" .. M.now() .. ":" .. (os.clock() or 0) .. ":" .. #out)
    end
    return out:sub(1, nbytes * 2)
end

--- Random six digit pairing code, e.g. "482913".
function M.new_code()
    seed()
    return string.format("%06d", math.random(0, 999999))
end

--- "482913" -> "482-913" for display.
function M.fmt_code(code)
    return code:sub(1, 3) .. "-" .. code:sub(4)
end

--- Strips spaces/dashes so "482-913" and "482913" are the same code.
function M.clean_code(code)
    return (tostring(code or ""):gsub("[^%d]", ""))
end

--- Stable text form of a table of scalars: sorted "k=v" pairs.
function M.canon(t)
    if type(t) ~= "table" then return tostring(t or "") end
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        local v = t[k]
        if v == nil then v = t[tonumber(k)] end
        if type(v) == "table" then v = M.canon(v) end
        parts[#parts + 1] = k .. "=" .. tostring(v)
    end
    return table.concat(parts, ";")
end

--- Signature over any number of parts, keyed with `secret`.
function M.sign(secret, ...)
    local parts = { ... }
    for i = 1, select("#", ...) do parts[i] = tostring(parts[i] == nil and "" or parts[i]) end
    return M.sha256(tostring(secret) .. "\0" .. table.concat(parts, "\0"))
end

--- Comparison that doesn't bail out at the first differing character.
function M.eq(a, b)
    a, b = tostring(a or ""), tostring(b or "")
    local diff = (#a == #b) and 0 or 1
    for i = 1, math.max(#a, #b) do
        if a:byte(i) ~= b:byte(i) then diff = 1 end
    end
    return diff == 0
end

--- XOR two hex strings (result is as long as the shorter one).
function M.xor_hex(a, b)
    local n = math.min(#a, #b)
    local out = {}
    for i = 1, n do
        out[i] = string.format("%x", bxor(tonumber(a:sub(i, i), 16), tonumber(b:sub(i, i), 16)))
    end
    return table.concat(out)
end

-- Pairing: the code never travels in clear text. The hub proves it knows the
-- code (proof) and the new shared secret is masked with a key derived from it.
function M.pair_proof(tid, nonce, code)
    return M.sha256("pair\0" .. tid .. "\0" .. nonce .. "\0" .. M.clean_code(code))
end

function M.pair_mask(tid, nonce, code)
    return M.sha256("mask\0" .. tid .. "\0" .. nonce .. "\0" .. M.clean_code(code))
end

--- Player's confirmation that it now holds `secret` (checked by the hub).
function M.pair_ack(secret, tid, nonce)
    return M.sha256("ack\0" .. secret .. "\0" .. tid .. "\0" .. nonce)
end

return M
