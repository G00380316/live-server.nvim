local t = require("harness")
local config = require("live_server.config")

local function fresh(opts)
  config.did_setup = false
  return config.setup(opts or {})
end

t.describe("config.validate", function()
  t.it("accepts the defaults", function()
    local issues = config.validate(config.defaults())
    t.eq(issues, {})
  end)

  t.it("flags unknown options", function()
    local issues = config.validate({ hostt = "127.0.0.1" })
    t.eq(#issues, 1)
    t.contains(issues[1], "hostt")
  end)

  t.it("flags unknown nested options", function()
    local issues = config.validate({ port = { strategey = "pin" } })
    t.eq(#issues, 1)
    t.contains(issues[1], "port.strategey")
  end)

  t.it("does not descend into free-form tables", function()
    local issues = config.validate({
      adapters = { my_thing = { command = { "x" } } },
      extra_args = { live_server = { "--cors" } },
      ui = { highlights = { LiveServerRunning = { fg = "#fff" } }, keys = { whatever = "z" } },
      port = { defaults = { my_thing = 1234 } },
    })
    t.eq(issues, {})
  end)

  t.it("reports wrong types", function()
    local issues = config.validate({ host = 123 })
    t.eq(#issues, 1)
    t.contains(issues[1], "expected string")
  end)

  t.it("reports values outside an enum", function()
    local issues = config.validate({ port = { strategy = "nope" } })
    t.eq(#issues, 1)
    t.contains(issues[1], "expected one of")
  end)

  t.it("validates the port range", function()
    t.eq(#config.validate({ port = { range = { 6000, 5000 } } }), 1)
    t.eq(#config.validate({ port = { range = { 100, 70000 } } }), 1)
    t.eq(#config.validate({ port = { range = { "a", 5000 } } }), 1)
    t.eq(#config.validate({ port = { range = { 5000, 6000 } } }), 0)
  end)

  t.it("validates the host format", function()
    t.eq(#config.validate({ host = "127.0.0.1" }), 0)
    t.eq(#config.validate({ host = "0.0.0.0" }), 0)
    t.eq(#config.validate({ host = "my-host.local" }), 0)
    t.eq(#config.validate({ host = "not a host" }), 1)
  end)

  t.it("accepts every documented expose value", function()
    for _, value in ipairs({ true, false, "ask" }) do
      t.eq(#config.validate({ expose = value }), 0, "expose = " .. tostring(value))
    end
    t.eq(#config.validate({ expose = "sometimes" }), 1)
  end)

  t.it("reports several problems at once", function()
    local issues = config.validate({ host = 1, unknown_key = true, ui = { icons = "sparkles" } })
    t.eq(#issues, 3)
  end)
end)

t.describe("config.setup", function()
  t.it("merges over the defaults", function()
    local options = fresh({ host = "0.0.0.0", ui = { compact = true } })
    t.eq(options.host, "0.0.0.0")
    t.eq(options.ui.compact, true)
    t.eq(options.ui.border, "rounded", "untouched keys keep their default")
  end)

  t.it("discards invalid values instead of failing", function()
    local options = fresh({ host = 12345, ui = { compact = true } })
    t.eq(options.host, "127.0.0.1", "invalid host falls back to the default")
    t.eq(options.ui.compact, true, "valid siblings still apply")
  end)

  t.it("replaces list options rather than merging them", function()
    local options = fresh({ watch = { ignore = { "only_this" } } })
    t.eq(options.watch.ignore, { "only_this" })

    options = fresh({ adapter_priority = { "python" } })
    t.eq(options.adapter_priority, { "python" })

    options = fresh({ root = { patterns = { ".git" } } })
    t.eq(options.root.patterns, { ".git" })
  end)

  t.it("deep-merges map options", function()
    local options = fresh({ port = { defaults = { live_server = 4000 } } })
    t.eq(options.port.defaults.live_server, 4000)
    t.eq(options.port.defaults.browser_sync, 3000, "other adapters keep their defaults")
  end)

  t.it("auto-initialises on first get()", function()
    config.did_setup = false
    local options = config.get()
    t.truthy(config.did_setup)
    t.eq(options.host, "127.0.0.1")
  end)

  t.it("does not let one setup leak into the next", function()
    fresh({ watch = { ignore = { "a" } } })
    local options = fresh({})
    t.includes(options.watch.ignore, "node_modules")
  end)

  t.it("keeps defaults immutable", function()
    local options = fresh({})
    table.insert(options.watch.ignore, "mutated")
    t.falsy(vim.tbl_contains(config.defaults().watch.ignore, "mutated"))
  end)
end)
