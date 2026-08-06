---@mod live_server.util Shared helpers
---
--- Small, dependency-free helpers used across the plugin. Everything here must
--- stay side-effect free at require time so the module is cheap to load.

local M = {}

--- libuv handle, compatible with Neovim 0.9 (`vim.loop`) and 0.10+ (`vim.uv`).
M.uv = vim.uv or vim.loop

--- `has("win32")` is true for every Windows build including 64-bit, and is what
--- Neovim itself uses. Parsing `uname` is a guess by comparison.
---@type boolean
M.is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
---@type boolean
M.is_mac = M.uv.os_uname().sysname == "Darwin"
---@type boolean
M.is_wsl = (function()
    if M.is_windows then
        return false
    end
    local release = M.uv.os_uname().release or ""
    return release:lower():find("microsoft") ~= nil
end)()

--- Milliseconds since an arbitrary fixed point. Monotonic: safe for durations.
---@return integer
function M.now()
    return math.floor(M.uv.now())
end

--- Clamp `value` into the inclusive range [`lo`, `hi`].
---@param value number
---@param lo number
---@param hi number
---@return number
function M.clamp(value, lo, hi)
    if value < lo then
        return lo
    elseif value > hi then
        return hi
    end
    return value
end

--- Format a millisecond duration as a compact human string ("3s", "4m", "2h").
---@param ms integer
---@return string
function M.duration(ms)
    if ms < 1000 then
        return "0s"
    end
    local seconds = math.floor(ms / 1000)
    if seconds < 60 then
        return seconds .. "s"
    end
    local minutes = math.floor(seconds / 60)
    if minutes < 60 then
        return minutes .. "m"
    end
    local hours = math.floor(minutes / 60)
    if hours < 24 then
        return hours .. "h" .. (minutes % 60 > 0 and (minutes % 60) .. "m" or "")
    end
    return math.floor(hours / 24) .. "d" .. (hours % 24 > 0 and (hours % 24) .. "h" or "")
end

--- Display width of `str`, accounting for multi-cell characters.
---@param str string
---@return integer
function M.width(str)
    return vim.fn.strdisplaywidth(str)
end

--- Pad `str` with spaces to `width` display cells.
---@param str string
---@param width integer
---@param align? "left"|"right"
---@return string
function M.pad(str, width, align)
    local len = M.width(str)
    if len >= width then
        return str
    end
    local fill = string.rep(" ", width - len)
    if align == "right" then
        return fill .. str
    end
    return str .. fill
end

--- Truncate `str` to `width` display cells, appending an ellipsis when cut.
---@param str string
---@param width integer
---@return string
function M.truncate(str, width)
    if width <= 0 then
        return ""
    end
    if M.width(str) <= width then
        return str
    end
    if width <= 1 then
        return "…"
    end
    local out = str
    while M.width(out) > width - 1 and #out > 0 do
        out = out:sub(1, -2)
    end
    return out .. "…"
end

--- Truncate from the left, keeping the end of the string. For paths the tail is
--- what identifies the thing; the leading directories are noise.
---@param str string
---@param width integer
---@return string
function M.truncate_left(str, width)
    if width <= 0 then
        return ""
    end
    if M.width(str) <= width then
        return str
    end
    if width <= 1 then
        return "…"
    end
    local out = str
    while M.width(out) > width - 1 and #out > 0 do
        out = out:sub(2)
    end
    return "…" .. out
end

--- Shorten a path for display: `~` for home, then drop leading components
--- until it fits, so `…/clients/acme/site` beats `/home/u/work/cli…`.
---@param path string
---@param width integer
---@return string
function M.shorten_path(path, width)
    local display = vim.fn.fnamemodify(path, ":~")
    if M.width(display) <= width then
        return display
    end

    -- Prefer cutting on a separator so the result is still a readable path.
    local parts = vim.split(display, "/", { plain = true, trimempty = true })
    for index = 2, #parts do
        local candidate = "…/" .. table.concat(parts, "/", index)
        if M.width(candidate) <= width then
            return candidate
        end
    end
    return M.truncate_left(display, width)
end

--- Strip ANSI escape sequences and carriage returns from process output.
---@param str string
---@return string
function M.strip_ansi(str)
    local out = str:gsub("\27%[[%d;?]*[A-Za-z]", "")
    out = out:gsub("\27%][^\7\27]*[\7\27]?", "")
    out = out:gsub("\r", "")
    return out
end

--- True when `name` resolves to an executable on `$PATH`.
---@param name string
---@return boolean
function M.executable(name)
    return vim.fn.executable(name) == 1
end

--- Stable short hash of a string. Used for deterministic port assignment and
--- for trust-store keys, never for security decisions on its own.
---@param str string
---@return integer
function M.hash(str)
    -- FNV-1a, 32-bit, implemented with 16-bit halves so it stays exact in the
    -- 53-bit float mantissa LuaJIT uses for numbers.
    local hi, lo = 0x811c, 0x9dc5
    for i = 1, #str do
        lo = bit.bxor(lo, str:byte(i))
        -- multiply by the FNV prime 0x01000193 using 16-bit limbs
        local lo_mul = lo * 0x0193
        local hi_mul = hi * 0x0193 + lo * 0x0100 + math.floor(lo_mul / 0x10000)
        lo = lo_mul % 0x10000
        hi = hi_mul % 0x10000
    end
    return hi * 0x10000 + lo
end

--- SHA-256 of a string, used for content-addressed trust records.
---@param str string
---@return string
function M.sha256(str)
    return vim.fn.sha256(str)
end

--- Return a debounced wrapper: `fn` runs `ms` after the last call.
---@generic F: function
---@param fn F
---@param ms integer
---@return F
function M.debounce(fn, ms)
    local timer = nil
    return function(...)
        local args = { ... }
        if timer then
            timer:stop()
            timer:close()
            timer = nil
        end
        timer = M.uv.new_timer()
        if not timer then
            return fn(unpack(args))
        end
        timer:start(ms, 0, function()
            if timer then
                timer:stop()
                timer:close()
                timer = nil
            end
            vim.schedule(function()
                fn(unpack(args))
            end)
        end)
    end
end

--- Run `fn` on the main loop. No-op wrapper when already scheduled work is safe.
---@param fn function
function M.schedule(fn)
    if vim.in_fast_event() then
        vim.schedule(fn)
    else
        fn()
    end
end

--- Fixed-capacity ring buffer. Push is O(1) and memory never grows past `cap`.
---@class live_server.Ring
---@field private items any[]
---@field private cap integer
---@field private head integer
---@field private len integer
local Ring = {}
Ring.__index = Ring

---@param cap integer
---@return live_server.Ring
function M.ring(cap)
    return setmetatable({ items = {}, cap = math.max(1, cap), head = 0, len = 0 }, Ring)
end

---@param item any
function Ring:push(item)
    self.head = (self.head % self.cap) + 1
    self.items[self.head] = item
    if self.len < self.cap then
        self.len = self.len + 1
    end
end

--- Items in insertion order, oldest first.
---@param limit? integer only return the newest `limit` items
---@return any[]
function Ring:list(limit)
    local out = {}
    local count = self.len
    if limit and limit < count then
        count = limit
    end
    -- index of the oldest item we want to emit
    local start = self.head - count + 1
    for offset = 0, count - 1 do
        local idx = ((start + offset - 1) % self.cap) + 1
        out[#out + 1] = self.items[idx]
    end
    return out
end

---@return integer
function Ring:size()
    return self.len
end

function Ring:clear()
    self.items = {}
    self.head = 0
    self.len = 0
end

---@type table<string, string>
local realpath_cache = {}
---@type integer
local realpath_cache_size = 0

---@param path string
---@return string
local function strip_trailing(path)
    if #path > 1 then
        return (path:gsub("/+$", ""))
    end
    return path
end

--- Resolve an existing path to its canonical target.
---
--- On Windows, libuv may report a successful `fs_realpath` while preserving
--- the spelling of a directory symlink or junction. `resolve()` is therefore
--- also consulted and preferred when it produces a different existing path.
---@param path string
---@return string?
local function existing_realpath(path)
    local uv_real = M.uv.fs_realpath(path)
    local vim_real = vim.fn.resolve(path)

    if vim_real and vim_real ~= "" then
        vim_real = vim.fs.normalize(vim_real)
        local verified = M.uv.fs_realpath(vim_real)
        if verified then
            vim_real = verified
        end
    else
        vim_real = nil
    end

    if vim_real and vim.fs.normalize(vim_real) ~= vim.fs.normalize(path) then
        return vim_real
    end
    return uv_real or vim_real
end

--- Canonical form of a filesystem path: `~` expanded, absolute, no trailing
--- separator, forward slashes, and **symlinks resolved**.
---
--- Resolving symlinks is not cosmetic. Neovim reports buffer names in resolved
--- form, so a project reached through a symlink — `/tmp` on macOS, a work
--- directory linked onto another volume, a dotfiles checkout — would otherwise
--- produce two spellings of the same directory that never compare equal. That
--- breaks page mapping, port pin lookups, and the containment check that stops
--- a project file from serving something outside its own tree.
---@param path string
---@return string
function M.normalize(path)
    if path == nil or path == "" then
        return ""
    end

    -- vim.fs.normalize expands `~` and collapses `..`; it never globs, which
    -- matters because paths can legitimately contain `*` or `[`.
    local normalized = vim.fs.normalize(path)
    if not M.is_absolute(normalized) then
        normalized = vim.fs.normalize(vim.fn.fnamemodify(normalized, ":p"))
    end
    normalized = strip_trailing(normalized)

    local cached = realpath_cache[normalized]
    if cached then
        return cached
    end

    local resolved = existing_realpath(normalized)
    if not resolved then
        -- The path may not exist yet — a port pin for a directory about to be
        -- created, a page not yet written, a sub-project referenced before
        -- checkout. Walk up to the deepest ancestor that *does* exist and
        -- re-append the rest.
        --
        -- Resolving only the immediate parent is not enough: with `/tmp` a symlink,
        -- `/tmp/repo` would canonicalise to `/private/tmp/repo` while
        -- `/tmp/repo/app` stayed as written, and the two would no longer compare as
        -- parent and child. Every containment check downstream depends on this
        -- being consistent at any depth.
        local segments = {}
        local current = normalized
        while true do
            local parent = vim.fs.dirname(current)
            if not parent or parent == current then
                break
            end
            table.insert(segments, 1, vim.fs.basename(current))
            local parent_real = existing_realpath(parent)
            if parent_real then
                resolved = strip_trailing(vim.fs.normalize(parent_real)) .. "/" .. table.concat(segments, "/")
                break
            end
            current = parent
        end
    end

    resolved = strip_trailing(vim.fs.normalize(resolved or normalized))

    -- Bounded so a long session that touches many paths cannot leak memory.
    if realpath_cache_size < 1024 then
        realpath_cache[normalized] = resolved
        realpath_cache_size = realpath_cache_size + 1
    end
    return resolved
end

--- Forget cached symlink resolutions. Only needed if a symlink is repointed
--- while Neovim is running.
function M.invalidate_paths()
    realpath_cache = {}
    realpath_cache_size = 0
end

---@param path string
---@return boolean
function M.is_absolute(path)
    if M.is_windows then
        return path:match("^%a:[/\\]") ~= nil or path:match("^[/\\][/\\]") ~= nil
    end
    return path:sub(1, 1) == "/"
end

--- True when `child` is `parent` or lives inside it. Both are normalised first,
--- so this is safe to use as a containment check against `..` traversal.
---@param parent string
---@param child string
---@return boolean
function M.is_within(parent, child)
    local p, c = M.normalize(parent), M.normalize(child)
    if p == "" or c == "" then
        return false
    end
    if c == p then
        return true
    end
    return c:sub(1, #p + 1) == p .. "/"
end

--- Path of `path` relative to `base`, or nil when it is not contained.
---@param base string
---@param path string
---@return string?
function M.relative(base, path)
    local b, p = M.normalize(base), M.normalize(path)
    if not M.is_within(b, p) then
        return nil
    end
    if b == p then
        return ""
    end
    return p:sub(#b + 2)
end

---@param path string
---@return boolean
function M.is_dir(path)
    local stat = M.uv.fs_stat(path)
    return stat ~= nil and stat.type == "directory"
end

---@param path string
---@return boolean
function M.is_file(path)
    local stat = M.uv.fs_stat(path)
    return stat ~= nil and stat.type == "file"
end

--- Create `path` and any missing parents. Returns false plus a message on error.
---@param path string
---@return boolean ok
---@return string? err
function M.mkdirp(path)
    local ok, err = pcall(vim.fn.mkdir, path, "p")
    if not ok then
        return false, tostring(err)
    end
    return true, nil
end

--- Read a whole file. Returns nil when it does not exist or cannot be read.
---@param path string
---@return string?
function M.read_file(path)
    local fd = M.uv.fs_open(path, "r", 438)
    if not fd then
        return nil
    end
    local stat = M.uv.fs_fstat(fd)
    if not stat then
        M.uv.fs_close(fd)
        return nil
    end
    local data = M.uv.fs_read(fd, stat.size, 0)
    M.uv.fs_close(fd)
    return data
end

--- Write `data` to `path` atomically (write to a temp file, then rename) so a
--- crash mid-write can never leave a truncated state file behind.
---@param path string
---@param data string
---@return boolean ok
---@return string? err
function M.write_file(path, data)
    local dir = vim.fs.dirname(path)
    if dir and not M.is_dir(dir) then
        local ok, err = M.mkdirp(dir)
        if not ok then
            return false, err
        end
    end
    local tmp = path .. ".tmp." .. tostring(M.uv.getpid())
    local fd, open_err = M.uv.fs_open(tmp, "w", 384) -- 0600: state may name private paths
    if not fd then
        return false, tostring(open_err)
    end
    local ok, write_err = pcall(M.uv.fs_write, fd, data, 0)
    M.uv.fs_close(fd)
    if not ok then
        pcall(M.uv.fs_unlink, tmp)
        return false, tostring(write_err)
    end
    local renamed, rename_err = M.uv.fs_rename(tmp, path)
    if not renamed then
        pcall(M.uv.fs_unlink, tmp)
        return false, tostring(rename_err)
    end
    return true, nil
end

--- Decode JSON, never throwing. Returns nil plus a message on malformed input.
---@param str string
---@return any?
---@return string? err
function M.json_decode(str)
    if str == nil or vim.trim(str) == "" then
        return nil, "empty"
    end
    local ok, result = pcall(vim.json.decode, str, { luanil = { object = true, array = true } })
    if not ok then
        return nil, tostring(result)
    end
    return result, nil
end

--- Encode to JSON. Returns nil plus a message when the value is not encodable.
---@param value any
---@return string?
---@return string? err
function M.json_encode(value)
    local ok, result = pcall(vim.json.encode, value)
    if not ok then
        return nil, tostring(result)
    end
    return result, nil
end

--- Sorted keys of a table, for deterministic iteration order in output.
---@param tbl table
---@return string[]
function M.sorted_keys(tbl)
    local keys = {}
    for key in pairs(tbl) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    return keys
end

--- Number of entries in a map-like table.
---@param tbl table
---@return integer
function M.count(tbl)
    local n = 0
    for _ in pairs(tbl) do
        n = n + 1
    end
    return n
end

--- Shell-quote an argument for *display* purposes (copyable commands shown to
--- the user). Process spawning never goes through a shell, so this is not a
--- security boundary.
---@param arg string
---@return string
function M.quote(arg)
    if arg:match("^[%w@%%_%-%+=:,%./]+$") then
        return arg
    end
    return "'" .. arg:gsub("'", [['\'']]) .. "'"
end

---@param argv string[]
---@return string
function M.join_argv(argv)
    local parts = {}
    for _, arg in ipairs(argv) do
        parts[#parts + 1] = M.quote(arg)
    end
    return table.concat(parts, " ")
end

return M
