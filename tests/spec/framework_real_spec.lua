--- Tests against frameworks that are really installed.
---
--- The rest of the suite deliberately uses hand-written stand-in servers so it
--- runs offline in a second. That leaves one thing unverified: whether the argv
--- we construct is actually accepted by the real CLI. Flags get renamed
--- between major versions, and a stand-in server will never notice.
---
--- Skipped unless `LIVE_SERVER_TEST_FRAMEWORKS` points at a directory holding
--- pre-installed fixtures; CI scaffolds them.

local t = require("harness")
local config = require("live_server.config")
local framework = require("live_server.framework")
local manager = require("live_server.manager")
local net = require("live_server.net")
local project_mod = require("live_server.project")
local util = require("live_server.util")

local fixtures = vim.env.LIVE_SERVER_TEST_FRAMEWORKS

if not fixtures or not util.is_dir(fixtures) then
  t.describe("real frameworks", function()
    t.skip("real framework startup", "set LIVE_SERVER_TEST_FRAMEWORKS to a fixtures directory")
  end)
  return
end

---@param name string
---@return string?
local function fixture(name)
  local dir = util.normalize(fixtures .. "/" .. name)
  if util.is_dir(dir) and util.is_file(dir .. "/package.json") then
    return dir
  end
  return nil
end

---@param root string
---@param expected_framework string
---@param port_range integer[]
local function starts_and_serves(root, expected_framework, port_range)
  config.did_setup = false
  config.setup({
    browser = { auto_open = false },
    detect_orphans = false,
    restart = { on_crash = false },
    project = { trust = "allow" },
    port = { strategy = "scan", range = port_range, remember = false },
    -- Real installs compile; give them the room a cold start needs.
    ready = { timeout = 120000 },
  })
  framework.invalidate()
  project_mod.invalidate()
  require("live_server.discover").invalidate()

  local detected = framework.detect(root)
  t.truthy(detected, "nothing detected in " .. root)
  t.eq(detected.name, expected_framework)

  local started, failure = nil, nil
  manager.start({ dir = root }, function(server, err)
    started, failure = server, err
  end)
  t.truthy(
    vim.wait(180000, function()
      return started ~= nil or failure ~= nil
    end, 250),
    "start never completed"
  )
  t.truthy(started, ("%s failed to start: %s"):format(expected_framework, tostring(failure)))
  t.eq(started.status, "running")

  if util.executable("curl") then
    local code = vim.trim(vim.fn.system({
      "curl",
      "-fsS",
      "-o",
      "/dev/null",
      "-w",
      "%{http_code}",
      "--max-time",
      "20",
      started:url(),
    }))
    t.eq(code, "200", "the real server did not answer on the port we assigned")
  end

  local port = started.port
  manager.stop(started)
  t.truthy(
    vim.wait(20000, function()
      return not started:is_active()
    end, 100),
    "the server never stopped"
  )
  t.truthy(
    vim.wait(20000, function()
      return net.is_free("127.0.0.1", port)
    end, 200),
    "the port was not released"
  )
  manager.prune()
  config.did_setup = false
  config.setup({})
end

t.describe("real frameworks", function()
  local vite = fixture("vite-app")
  if vite then
    t.it("starts a real Vite app on the port we chose", function()
      -- Proves `--port`, `--host` and `--strictPort` are still the flags Vite
      -- accepts, which a stand-in server can never tell us.
      starts_and_serves(vite, "vite", { 6700, 6740 })
    end)
  else
    t.skip("real Vite app", "no vite-app fixture")
  end

  local express = fixture("express-app")
  if express then
    t.it("starts a real Express app from its PORT variable", function()
      starts_and_serves(express, "node_server", { 6750, 6790 })
    end)
  else
    t.skip("real Express app", "no express-app fixture")
  end
end)
