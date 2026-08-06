--- End-to-end tests against a real server process.
---
--- These are the tests that would have caught every historical bug worth
--- catching: the process really spawns, the port really answers, and stopping
--- really releases it.

local t = require("harness")
local adapters = require("live_server.adapters")
local config = require("live_server.config")
local manager = require("live_server.manager")
local net = require("live_server.net")
local util = require("live_server.util")

---@return string root
local function fixture()
  local root = util.normalize(vim.fn.tempname())
  vim.fn.mkdir(root, "p")
  util.write_file(root .. "/index.html", "<!doctype html><title>fixture</title><h1>fixture</h1>")
  util.write_file(root .. "/.git/HEAD", "ref: refs/heads/main")
  return root
end

---@param server live_server.Server
---@param timeout? integer
---@return boolean
local function wait_until_stopped(server, timeout)
  return vim.wait(timeout or 5000, function()
    return not server:is_active()
  end, 50)
end

local backend = nil
for _, candidate in ipairs({ "live_server", "python", "serve", "browser_sync" }) do
  if adapters.available(candidate) then
    backend = candidate
    break
  end
end

if not backend then
  t.describe("integration", function()
    t.skip("server lifecycle", "no dev server backend installed")
  end)
  return
end

t.describe("integration (" .. backend .. ")", function()
  config.did_setup = false
  config.setup({
    server = backend,
    browser = { auto_open = false },
    detect_orphans = false,
    port = { strategy = "scan", range = { 5700, 5760 }, remember = false },
    ready = { timeout = 20000 },
  })

  local root = fixture()

  t.it("starts, answers HTTP, and stops", function()
    local started, failure = nil, nil
    manager.start({ dir = root }, function(server, err)
      started, failure = server, err
    end)
    t.truthy(
      vim.wait(25000, function()
        return started ~= nil or failure ~= nil
      end, 50),
      "start callback never fired"
    )
    t.truthy(started, "server failed to start: " .. tostring(failure))
    t.eq(started.status, "running")
    t.truthy(net.is_listening("127.0.0.1", started.port, 1000), "port is not accepting connections")

    if util.executable("curl") then
      local code, exit_code, stderr = t.http_status(started:url())
      t.eq(exit_code, 0, "curl failed: " .. stderr)
      t.eq(code, "200", "the server did not serve the fixture")
    end

    local port = started.port
    manager.stop(started)
    t.truthy(wait_until_stopped(started), "server did not stop")

    t.truthy(
      vim.wait(5000, function()
        return net.is_free("127.0.0.1", port)
      end, 100),
      "the port was not released after stopping"
    )
  end)

  t.it("refuses to start a second server for the same project and backend", function()
    local first = nil
    manager.start({ dir = root }, function(server)
      first = server
    end)
    t.truthy(vim.wait(25000, function()
      return first ~= nil
    end, 50))

    local second = nil
    manager.start({ dir = root }, function(server)
      second = server
    end)
    t.truthy(vim.wait(3000, function()
      return second ~= nil
    end, 50))
    t.truthy(rawequal(first, second), "starting twice must return the existing server, not a duplicate")
    t.eq(#manager.for_project(root, { active_only = true }), 1)

    manager.stop(first)
    wait_until_stopped(first)
    manager.prune()
  end)

  t.it("picks a different port when the preferred one is taken", function()
    local uv = vim.uv or vim.loop
    local blocker = uv.new_tcp()
    blocker:bind("127.0.0.1", 5700)
    blocker:listen(1, function() end)

    local started = nil
    manager.start({ dir = root }, function(server)
      started = server
    end)
    t.truthy(
      vim.wait(25000, function()
        return started ~= nil
      end, 50),
      "server never started around the blocked port"
    )
    t.neq(started.port, 5700, "the occupied port must be skipped")

    manager.stop(started)
    wait_until_stopped(started)
    blocker:close()
    manager.prune()
  end)

  t.it("emits lifecycle events", function()
    local seen = {}
    local unsubscribe = require("live_server.event").on("*", function(payload)
      seen[payload.event] = true
    end)

    local started = nil
    manager.start({ dir = root }, function(server)
      started = server
    end)
    t.truthy(vim.wait(25000, function()
      return started ~= nil
    end, 50))
    t.truthy(seen.starting, "no `starting` event")
    t.truthy(seen.ready, "no `ready` event")

    manager.stop(started)
    wait_until_stopped(started)
    t.truthy(seen.stopped, "no `stopped` event")
    unsubscribe()
    manager.prune()
  end)

  t.it("stop_all leaves nothing running", function()
    local started = nil
    manager.start({ dir = root }, function(server)
      started = server
    end)
    t.truthy(vim.wait(25000, function()
      return started ~= nil
    end, 50))

    t.truthy(manager.stop_all() >= 1)
    t.truthy(
      vim.wait(5000, function()
        return manager.count_active() == 0
      end, 50),
      "servers still active after stop_all"
    )
    manager.prune()
  end)

  t.it("moves a running server to a new port and frees the old one", function()
    local started = nil
    manager.start({ dir = root }, function(server)
      started = server
    end)
    t.truthy(vim.wait(25000, function()
      return started ~= nil
    end, 50))

    local old_port = started.port
    local new_port = old_port + 11
    if not net.is_free("127.0.0.1", new_port) then
      new_port = new_port + 1
    end

    local moved = nil
    manager.change_port(started, new_port, function(ok)
      moved = ok
    end)
    t.truthy(
      vim.wait(25000, function()
        return moved ~= nil
      end, 50),
      "change_port never completed"
    )
    t.truthy(moved, "change_port failed")
    t.eq(started.port, new_port)
    t.truthy(net.is_listening("127.0.0.1", new_port, 1000), "the new port is not answering")
    t.truthy(
      vim.wait(5000, function()
        return net.is_free("127.0.0.1", old_port)
      end, 100),
      "the old port was not released"
    )

    manager.stop(started)
    wait_until_stopped(started)
    manager.prune()
  end)

  t.it("detects a process that exits immediately as a crash", function()
    -- A backend that always fails, so the failure path is exercised without
    -- depending on how any real server behaves when it cannot bind.
    require("live_server.adapters").register({
      name = "always_fails",
      display = "always-fails",
      bin = "sh",
      install = "",
      live_reload = false,
      build = function()
        return { "sh", "-c", "echo 'cannot bind: permission denied' >&2; exit 1" }
      end,
    })

    config.did_setup = false
    config.setup({
      server = "always_fails",
      browser = { auto_open = false },
      detect_orphans = false,
      restart = { on_crash = false },
      ready = { timeout = 3000 },
      port = { strategy = "scan", range = { 5770, 5790 }, remember = false },
    })

    local crashed = false
    local unsubscribe = require("live_server.event").on("crashed", function()
      crashed = true
    end)

    local failure = nil
    manager.start({ dir = root, adapter = "always_fails" }, function(_, err)
      failure = err or "failed"
    end)

    t.truthy(
      vim.wait(8000, function()
        return crashed
      end, 50),
      "a process that exits non-zero must be reported as crashed"
    )

    t.truthy(
      vim.wait(3000, function()
        return failure ~= nil
      end, 50),
      "the start callback must report the failure, not hang"
    )

    local server = manager.servers()[#manager.servers()]
    t.eq(server.status, "crashed")
    t.contains(server:last_error() or "", "permission denied", "stderr must be captured for diagnosis")

    unsubscribe()
    manager.prune()

    config.did_setup = false
    config.setup({
      server = backend,
      browser = { auto_open = false },
      detect_orphans = false,
      port = { strategy = "scan", range = { 5700, 5760 }, remember = false },
      ready = { timeout = 20000 },
    })
  end)

  t.it("reports a helpful error for an unusable port", function()
    local failure = nil
    manager.start({ dir = root, port = 80 }, function(_, err)
      failure = err
    end)
    t.truthy(
      vim.wait(3000, function()
        return failure ~= nil
      end, 50),
      "no error reported for a privileged port"
    )
    t.contains(failure, "privileged")
  end)

  config.did_setup = false
  config.setup({})
end)
