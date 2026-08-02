local t = require("harness")
local adapters = require("live_server.adapters")
local config = require("live_server.config")

---@return live_server.SpawnContext
local function context(overrides)
  local cfg = config.get()
  return vim.tbl_extend("force", {
    host = "127.0.0.1",
    port = 5500,
    serve_dir = "/tmp/project/public",
    project = { root = "/tmp/project", name = "project", serve_dir = "/tmp/project/public", config = {} },
    config = cfg,
    entry_file = nil,
    ignore = { "node_modules", ".git" },
    extensions = { "html", "css", "js" },
    delay = 100,
    extra = {},
  }, overrides or {})
end

---@param argv string[]
---@param flag string
---@return string?
local function value_of(argv, flag)
  for index, arg in ipairs(argv) do
    local inline = arg:match("^" .. vim.pesc(flag) .. "=(.*)$")
    if inline then
      return inline
    end
    if arg == flag then
      return argv[index + 1]
    end
  end
  return nil
end

t.describe("adapter registry", function()
  t.it("registers every built-in", function()
    local names = adapters.names()
    for _, expected in ipairs({ "live_server", "browser_sync", "serve", "python" }) do
      t.includes(names, expected)
    end
  end)

  t.it("returns nil for an unknown adapter", function()
    t.eq(adapters.get("definitely_not_real"), nil)
  end)

  t.it("explains an unknown adapter on resolve", function()
    local spec, err = adapters.resolve("definitely_not_real")
    t.eq(spec, nil)
    t.contains(err, "unknown server")
  end)

  t.it("accepts a user adapter defined with a command template", function()
    config.did_setup = false
    config.setup({
      adapters = {
        my_static = { display = "my-static", bin = "sh", command = { "sh", "-c", "serve {dir} {port} {host}" } },
      },
    })
    local spec = adapters.get("my_static")
    t.truthy(spec)
    local argv = spec.build(context())
    t.eq(argv[3], "serve /tmp/project/public 5500 127.0.0.1")
    config.did_setup = false
    config.setup({})
  end)

  t.it("accepts a user adapter with a build function", function()
    config.did_setup = false
    config.setup({
      adapters = {
        scripted = {
          display = "scripted",
          bin = "sh",
          build = function(ctx)
            return { "sh", "-c", "port=" .. ctx.port }
          end,
        },
      },
    })
    t.eq(adapters.get("scripted").build(context()), { "sh", "-c", "port=5500" })
    config.did_setup = false
    config.setup({})
  end)
end)

t.describe("live-server argv", function()
  local spec = adapters.get("live_server")

  t.it("passes host, port and directory", function()
    local argv = spec.build(context())
    t.eq(argv[1], "live-server")
    t.eq(value_of(argv, "--port"), "5500")
    t.eq(value_of(argv, "--host"), "127.0.0.1")
    t.eq(argv[#argv], "/tmp/project/public", "the directory must be the last argument")
  end)

  t.it("never opens a browser itself", function()
    t.includes(spec.build(context()), "--no-browser")
  end)

  t.it("passes the reload delay", function()
    t.eq(value_of(spec.build(context({ delay = 250 })), "--wait"), "250")
  end)

  t.it("adds an SPA entry file only when configured", function()
    t.eq(value_of(spec.build(context()), "--entry-file"), nil)
    t.eq(value_of(spec.build(context({ entry_file = "index.html" })), "--entry-file"), "index.html")
  end)

  t.it("joins ignore patterns", function()
    t.eq(value_of(spec.build(context()), "--ignore"), "node_modules,.git")
  end)

  t.it("keeps the directory last even with extra arguments", function()
    local argv = spec.build(context({ extra = { "--cors" } }))
    t.includes(argv, "--cors")
    t.eq(argv[#argv], "/tmp/project/public")
  end)

  t.it("keeps shell metacharacters intact as a single argument", function()
    local argv = spec.build(context({ serve_dir = "/tmp/we ird; rm -rf x/dir" }))
    t.eq(argv[#argv], "/tmp/we ird; rm -rf x/dir", "argv entries are passed verbatim, never through a shell")
  end)
end)

t.describe("browser-sync argv", function()
  local spec = adapters.get("browser_sync")

  t.it("serves the right directory on the right port", function()
    local argv = spec.build(context())
    t.eq(argv[1], "browser-sync")
    t.eq(argv[2], "start")
    t.eq(value_of(argv, "--server"), "/tmp/project/public")
    t.eq(value_of(argv, "--port"), "5500")
    t.eq(value_of(argv, "--host"), "127.0.0.1")
  end)

  t.it("disables the extra UI port so accounting stays honest", function()
    t.includes(spec.build(context()), "--no-ui")
  end)

  t.it("does not open a browser or notify", function()
    local argv = spec.build(context())
    t.includes(argv, "--no-open")
    t.includes(argv, "--no-notify")
  end)

  t.it("builds watch globs from the extension list", function()
    local argv = spec.build(context({ extensions = { "html", "css" } }))
    t.eq(value_of(argv, "--files"), "**/*.html,**/*.css")
  end)

  t.it("enables single-page mode for an SPA", function()
    t.falsy(vim.tbl_contains(spec.build(context()), "--single"))
    t.includes(spec.build(context({ entry_file = "index.html" })), "--single")
  end)
end)

t.describe("serve argv", function()
  local spec = adapters.get("serve")

  t.it("binds host and port through a tcp url", function()
    local argv = spec.build(context())
    t.eq(value_of(argv, "--listen"), "tcp://127.0.0.1:5500")
    t.eq(argv[#argv], "/tmp/project/public")
  end)

  t.it("is marked as having no live reload", function()
    t.falsy(spec.live_reload, "callers must be able to warn the user about this")
  end)
end)

t.describe("python argv", function()
  local spec = adapters.get("python")

  t.it("uses the http.server module with an explicit directory", function()
    local argv = spec.build(context())
    t.eq(argv[2], "-m")
    t.eq(argv[3], "http.server")
    t.eq(argv[4], "5500")
    t.eq(value_of(argv, "--bind"), "127.0.0.1")
    t.eq(value_of(argv, "--directory"), "/tmp/project/public")
  end)

  t.it("is marked as having no live reload", function()
    t.falsy(spec.live_reload)
  end)
end)

t.describe("adapter argv safety", function()
  t.it("produces list arguments for every adapter", function()
    for _, name in ipairs({ "live_server", "browser_sync", "serve", "python" }) do
      local argv = adapters.get(name).build(context())
      t.truthy(vim.islist and vim.islist(argv) or vim.tbl_islist(argv), name .. " must return a list")
      for _, arg in ipairs(argv) do
        t.eq(type(arg), "string", name .. " produced a non-string argument")
      end
    end
  end)

  t.it("never emits an empty argument", function()
    for _, name in ipairs({ "live_server", "browser_sync", "serve", "python" }) do
      for _, arg in ipairs(adapters.get(name).build(context())) do
        t.neq(arg, "", name .. " emitted an empty argument")
      end
    end
  end)
end)
