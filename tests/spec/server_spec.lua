local t = require("harness")
local server_mod = require("live_server.server")
local adapters = require("live_server.adapters")
local event = require("live_server.event")
local config = require("live_server.config")

---@return live_server.Server
local function make(overrides)
  return server_mod.new(vim.tbl_extend("force", {
    adapter = adapters.get("live_server"),
    project = { root = "/tmp/project", name = "project", serve_dir = "/tmp/project", config = {}, privileged = {} },
    host = "127.0.0.1",
    port = 5500,
  }, overrides or {}))
end

t.describe("server url", function()
  t.it("builds a root url", function()
    t.eq(make():url(), "http://127.0.0.1:5500/")
  end)

  t.it("appends a page path", function()
    t.eq(make():url("about.html"), "http://127.0.0.1:5500/about.html")
    t.eq(make():url("/about.html"), "http://127.0.0.1:5500/about.html", "a leading slash is not doubled")
  end)

  t.it("uses the stored open path by default", function()
    t.eq(make({ open_path = "docs/index.html" }):url(), "http://127.0.0.1:5500/docs/index.html")
  end)

  t.it("never shows a wildcard bind as a hostname", function()
    local url = make({ host = "0.0.0.0" }):url()
    t.falsy(url:find("0.0.0.0", 1, true), "0.0.0.0 is not reachable from a browser")
    t.contains(url, ":5500/")
  end)

  t.it("brackets IPv6 addresses", function()
    t.eq(make({ host = "::1" }):url(), "http://[::1]:5500/")
  end)
end)

t.describe("server state", function()
  t.it("starts out inactive", function()
    local server = make()
    t.eq(server.status, "stopped")
    t.falsy(server:is_active())
  end)

  t.it("treats transitional states as active", function()
    local server = make()
    for _, status in ipairs({ "starting", "running", "unhealthy" }) do
      server.status = status
      t.truthy(server:is_active(), status .. " should count as active")
    end
    for _, status in ipairs({ "stopped", "crashed" }) do
      server.status = status
      t.falsy(server:is_active(), status .. " should not count as active")
    end
  end)

  t.it("reports a serialisable snapshot", function()
    local info = make():info()
    t.eq(info.adapter, "live_server")
    t.eq(info.port, 5500)
    t.eq(info.url, "http://127.0.0.1:5500/")
    -- `User` autocommand payloads must survive msgpack.
    for key, value in pairs(info) do
      t.neq(type(value), "function", key .. " must not be a function")
      t.neq(type(value), "userdata", key .. " must not be userdata")
    end
  end)

  t.it("reports zero uptime before starting", function()
    t.eq(make():uptime(), 0)
  end)
end)

t.describe("server logs", function()
  t.it("records output", function()
    local server = make()
    server:append_log("stdout", "listening on 5500")
    server:append_log("stderr", "a warning")
    local lines = server:log_lines()
    t.eq(#lines, 2)
    t.eq(lines[1].text, "listening on 5500")
    t.eq(lines[2].stream, "stderr")
  end)

  t.it("ignores blank lines", function()
    local server = make()
    server:append_log("stdout", "")
    server:append_log("stdout", "   ")
    t.eq(#server:log_lines(), 0)
  end)

  t.it("strips ANSI colour", function()
    local server = make()
    server:append_log("stdout", "\27[32mready\27[0m")
    t.eq(server:log_lines()[1].text, "ready")
  end)

  t.it("caps memory at the configured size", function()
    config.did_setup = false
    config.setup({ log = { max_lines = 10 } })
    local server = make()
    for index = 1, 100 do
      server:append_log("stdout", "line " .. index)
    end
    t.eq(#server:log_lines(), 10)
    t.eq(server:log_lines()[10].text, "line 100")
    config.did_setup = false
    config.setup({})
  end)

  t.it("surfaces the most recent error line", function()
    local server = make()
    server:append_log("stdout", "starting")
    server:append_log("stderr", "EADDRINUSE")
    server:append_log("stdout", "noise")
    t.eq(server:last_error(), "EADDRINUSE")
  end)
end)

t.describe("server argv", function()
  t.it("delegates to the adapter", function()
    local server = make()
    local argv = server:build_argv()
    t.eq(argv[1], "live-server")
    t.includes(argv, "--port=5500")
  end)

  t.it("uses a trusted custom command instead of the adapter", function()
    local server = make({ command = { "npx", "vite", "dev" } })
    t.eq(server:build_argv(), { "npx", "vite", "dev" })
  end)

  t.it("appends extra arguments to a custom command", function()
    local server = make({ command = { "npx", "vite" }, extra = { "--force" } })
    t.eq(server:build_argv(), { "npx", "vite", "--force" })
  end)

  t.it("appends configured extra_args", function()
    config.did_setup = false
    config.setup({ extra_args = { live_server = { "--cors" } } })
    t.includes(make():build_argv(), "--cors")
    config.did_setup = false
    config.setup({})
  end)
end)

t.describe("events", function()
  t.it("delivers to subscribers", function()
    local seen = {}
    local unsubscribe = event.on("ready", function(payload)
      seen[#seen + 1] = payload.event
    end)
    event.emit("ready", {})
    t.eq(seen, { "ready" })
    unsubscribe()
    event.emit("ready", {})
    t.eq(seen, { "ready" }, "unsubscribing must take effect")
  end)

  t.it("mirrors specific events onto `changed`", function()
    local count = 0
    local unsubscribe = event.on("changed", function()
      count = count + 1
    end)
    event.emit("stopped", {})
    t.eq(count, 1)
    unsubscribe()
  end)

  t.it("does not double-fire `changed` on itself", function()
    local count = 0
    local unsubscribe = event.on("changed", function()
      count = count + 1
    end)
    event.emit("changed", {})
    t.eq(count, 1)
    unsubscribe()
  end)

  t.it("survives a throwing handler", function()
    local reached = false
    local first = event.on("ready", function()
      error("boom")
    end)
    local second = event.on("ready", function()
      reached = true
    end)
    event.emit("ready", {})
    t.truthy(reached, "one bad handler must not stop the others")
    first()
    second()
  end)

  t.it("bumps the version counter for statusline caching", function()
    local before = event.version
    event.emit("changed", {})
    t.truthy(event.version > before)
  end)

  t.it("allows a handler to unsubscribe itself while dispatching", function()
    local calls = 0
    local unsubscribe
    unsubscribe = event.on("ready", function()
      calls = calls + 1
      unsubscribe()
    end)
    event.emit("ready", {})
    event.emit("ready", {})
    t.eq(calls, 1)
  end)
end)
