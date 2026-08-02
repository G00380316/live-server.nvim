local t = require("harness")
local util = require("live_server.util")

t.describe("util.ring", function()
  t.it("keeps insertion order", function()
    local ring = util.ring(5)
    for i = 1, 3 do
      ring:push(i)
    end
    t.eq(ring:list(), { 1, 2, 3 })
    t.eq(ring:size(), 3)
  end)

  t.it("drops the oldest item once full", function()
    local ring = util.ring(3)
    for i = 1, 5 do
      ring:push(i)
    end
    t.eq(ring:list(), { 3, 4, 5 })
    t.eq(ring:size(), 3)
  end)

  t.it("returns only the newest N when limited", function()
    local ring = util.ring(10)
    for i = 1, 6 do
      ring:push(i)
    end
    t.eq(ring:list(2), { 5, 6 })
  end)

  t.it("survives many wraps without growing", function()
    local ring = util.ring(4)
    for i = 1, 1000 do
      ring:push(i)
    end
    t.eq(ring:list(), { 997, 998, 999, 1000 })
    t.eq(ring:size(), 4)
  end)

  t.it("clears", function()
    local ring = util.ring(3)
    ring:push("a")
    ring:clear()
    t.eq(ring:list(), {})
    t.eq(ring:size(), 0)
  end)
end)

t.describe("util paths", function()
  -- Built from a canonical base so the assertions hold on systems where the
  -- temp directory is itself a symlink (macOS `/tmp` -> `/private/tmp`).
  local base = util.normalize(vim.fn.tempname())

  t.it("normalises trailing separators and ~", function()
    t.eq(util.normalize(base .. "/foo/"), base .. "/foo")
    t.eq(util.normalize(base .. "/foo//"), base .. "/foo")
    t.eq(util.normalize("~"), util.normalize(vim.env.HOME))
  end)

  t.it("is idempotent", function()
    local once = util.normalize(base .. "/a/b")
    t.eq(util.normalize(once), once)
  end)

  t.it("does not glob special characters", function()
    t.truthy(util.normalize(base .. "/a*b"):find("/a%*b$"), "`*` must not be expanded")
    t.truthy(util.normalize(base .. "/a[1]"):find("/a%[1%]$"), "`[` must not be expanded")
  end)

  t.it("resolves symlinks so one directory has one name", function()
    local real = util.normalize(vim.fn.tempname())
    vim.fn.mkdir(real .. "/site", "p")
    local link = real .. "/link"
    if vim.uv.fs_symlink(real .. "/site", link) then
      t.eq(util.normalize(link), util.normalize(real .. "/site"))
      t.truthy(util.is_within(real .. "/site", link .. "/index.html"))
    else
      t.skip("symlink resolution", "could not create a symlink here")
    end
  end)

  t.it("detects containment", function()
    t.truthy(util.is_within(base .. "/project", base .. "/project"))
    t.truthy(util.is_within(base .. "/project", base .. "/project/src"))
    t.falsy(util.is_within(base .. "/project", base .. "/project-other"))
    t.falsy(util.is_within(base .. "/project", base))
  end)

  t.it("rejects traversal that escapes the parent", function()
    t.falsy(util.is_within(base .. "/project", base .. "/project/../secrets"))
    t.falsy(util.is_within(base .. "/project", base .. "/project/../../etc"))
    t.truthy(util.is_within(base .. "/project", base .. "/project/a/../b"))
  end)

  t.it("computes relative paths", function()
    t.eq(util.relative(base .. "/project", base .. "/project/src/index.html"), "src/index.html")
    t.eq(util.relative(base .. "/project", base .. "/project"), "")
    t.eq(util.relative(base .. "/project", base .. "/other"), nil)
  end)
end)

t.describe("util formatting", function()
  t.it("formats durations", function()
    t.eq(util.duration(0), "0s")
    t.eq(util.duration(999), "0s")
    t.eq(util.duration(5000), "5s")
    t.eq(util.duration(90 * 1000), "1m")
    t.eq(util.duration(3600 * 1000), "1h")
    t.eq(util.duration(3900 * 1000), "1h5m")
    t.eq(util.duration(25 * 3600 * 1000), "1d1h")
  end)

  t.it("truncates to a display width", function()
    t.eq(util.truncate("hello", 10), "hello")
    t.eq(util.truncate("hello world", 8), "hello w…")
    t.eq(util.width(util.truncate("hello world", 8)), 8)
    t.eq(util.truncate("hello", 0), "")
  end)

  t.it("pads to a display width", function()
    t.eq(util.pad("ab", 5), "ab   ")
    t.eq(util.pad("ab", 5, "right"), "   ab")
    t.eq(util.pad("abcdef", 3), "abcdef")
  end)

  t.it("strips ANSI sequences", function()
    t.eq(util.strip_ansi("\27[32mgreen\27[0m"), "green")
    t.eq(util.strip_ansi("plain\r"), "plain")
  end)

  t.it("quotes only what needs quoting", function()
    t.eq(util.quote("simple"), "simple")
    t.eq(util.quote("/path/to/file.html"), "/path/to/file.html")
    t.contains(util.quote("with space"), "'with space'")
    t.contains(util.quote("rm -rf ~; echo"), "'")
  end)
end)

t.describe("util.hash", function()
  t.it("is deterministic", function()
    t.eq(util.hash("/tmp/project::live_server"), util.hash("/tmp/project::live_server"))
  end)

  t.it("separates different inputs", function()
    t.neq(util.hash("/tmp/a"), util.hash("/tmp/b"))
    t.neq(util.hash("project::live_server"), util.hash("project::browser_sync"))
  end)

  t.it("stays inside 32 bits", function()
    for _, input in ipairs({ "", "a", string.rep("x", 500), "/very/long/path/name/here" }) do
      local value = util.hash(input)
      t.truthy(value >= 0 and value < 2 ^ 32, "hash out of range for " .. #input .. " bytes")
      t.eq(value, math.floor(value), "hash must be an integer")
    end
  end)
end)

t.describe("util json", function()
  t.it("round-trips", function()
    local encoded = util.json_encode({ port = 5500, name = "site" })
    local decoded = util.json_decode(encoded)
    t.eq(decoded.port, 5500)
    t.eq(decoded.name, "site")
  end)

  t.it("never throws on malformed input", function()
    local value, err = util.json_decode("{not json")
    t.eq(value, nil)
    t.truthy(err)
    t.eq(util.json_decode(""), nil)
  end)
end)

t.describe("util file io", function()
  t.it("writes atomically and reads back", function()
    local path = vim.fn.tempname() .. "/nested/file.json"
    local ok = util.write_file(path, '{"a":1}')
    t.truthy(ok)
    t.eq(util.read_file(path), '{"a":1}')
    t.truthy(util.is_file(path))
    t.falsy(util.is_dir(path))
  end)

  t.it("leaves no temp file behind", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/state.json"
    util.write_file(path, "{}")
    local entries = vim.fn.readdir(dir)
    t.eq(entries, { "state.json" })
  end)

  t.it("returns nil for a missing file", function()
    t.eq(util.read_file("/definitely/not/here.json"), nil)
  end)
end)

t.describe("util path display", function()
  t.it("truncates from the left, keeping the tail", function()
    t.eq(util.truncate_left("abcdef", 10), "abcdef")
    t.eq(util.truncate_left("abcdefghij", 6), "…fghij")
    t.eq(util.width(util.truncate_left("abcdefghij", 6)), 6)
    t.eq(util.truncate_left("abc", 0), "")
  end)

  t.it("shortens a path on separators", function()
    local shortened = util.shorten_path("/home/u/work/clients/acme/site", 20)
    t.truthy(util.width(shortened) <= 20)
    t.contains(shortened, "site", "the identifying tail must survive")
    -- `…` is three bytes, so this must be a prefix check, not `sub(1, 1)`.
    t.truthy(vim.startswith(shortened, "…"), "expected a leading ellipsis, got " .. shortened)
  end)

  t.it("leaves a short path alone", function()
    t.eq(util.shorten_path("/tmp/site", 40), vim.fn.fnamemodify("/tmp/site", ":~"))
  end)

  t.it("never exceeds the requested width", function()
    for _, width in ipairs({ 5, 8, 12, 20, 40 }) do
      local result = util.shorten_path("/a/very/deeply/nested/project/path/that/keeps/going/site", width)
      t.truthy(
        util.width(result) <= width,
        ("width %d exceeded: %q is %d cells"):format(width, result, util.width(result))
      )
    end
  end)
end)
