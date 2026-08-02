local t = require("harness")
local net = require("live_server.net")
local port_mod = require("live_server.port")
local config = require("live_server.config")
local uv = vim.uv or vim.loop

t.describe("net.valid_port", function()
  t.it("accepts unprivileged ports", function()
    t.truthy(net.valid_port(5500))
    t.truthy(net.valid_port("8080"))
    t.truthy(net.valid_port(65535))
  end)

  t.it("rejects non-numbers", function()
    t.falsy(net.valid_port("http"))
    t.falsy(net.valid_port(nil))
    t.falsy(net.valid_port(5500.5))
  end)

  t.it("rejects out-of-range ports", function()
    t.falsy(net.valid_port(0))
    t.falsy(net.valid_port(70000))
    t.falsy(net.valid_port(-1))
  end)

  t.it("explains why privileged ports are rejected", function()
    local ok, err = net.valid_port(80)
    t.falsy(ok)
    t.contains(err, "privileged")
  end)
end)

t.describe("net.resolve", function()
  t.it("maps localhost to loopback", function()
    t.eq(net.resolve("localhost"), "127.0.0.1")
  end)

  t.it("passes numeric addresses through", function()
    t.eq(net.resolve("127.0.0.1"), "127.0.0.1")
    t.eq(net.resolve("0.0.0.0"), "0.0.0.0")
    t.eq(net.resolve("::1"), "::1")
  end)

  t.it("defaults empty input to loopback", function()
    t.eq(net.resolve(""), "127.0.0.1")
    t.eq(net.resolve(nil), "127.0.0.1")
  end)
end)

t.describe("net port availability", function()
  --- Bind a real socket so the tests assert against the operating system
  --- rather than against the plugin's own bookkeeping.
  ---@return integer port, userdata socket
  local function occupy()
    local socket = uv.new_tcp()
    socket:bind("127.0.0.1", 0)
    socket:listen(1, function() end)
    local address = socket:getsockname()
    return address.port, socket
  end

  t.it("reports an occupied port as unavailable", function()
    local port, socket = occupy()
    t.falsy(net.bindable("127.0.0.1", port))
    t.falsy(net.is_free("127.0.0.1", port))
    socket:close()
  end)

  t.it("reports a released port as available again", function()
    local port, socket = occupy()
    socket:close()
    vim.wait(100, function()
      return net.is_free("127.0.0.1", port)
    end, 10)
    t.truthy(net.is_free("127.0.0.1", port))
  end)

  t.it("detects a listener with a connect probe", function()
    local port, socket = occupy()
    t.truthy(net.is_listening("127.0.0.1", port, 500))
    socket:close()
  end)

  t.it("returns quickly when nothing is listening", function()
    local port, socket = occupy()
    socket:close()
    local started = uv.now()
    net.is_listening("127.0.0.1", port, 2000)
    uv.update_time()
    t.truthy(uv.now() - started < 1500, "a refused connection must not wait for the timeout")
  end)

  t.it("skips an occupied port when scanning", function()
    local port, socket = occupy()
    local found = net.find_free("127.0.0.1", port, { port, port + 20 }, 25)
    t.truthy(found)
    t.neq(found, port)
    socket:close()
  end)

  t.it("honours the exclusion set", function()
    local found = net.find_free("127.0.0.1", 5500, { 5500, 5520 }, 25, { [5500] = true, [5501] = true })
    t.truthy(found)
    t.truthy(found ~= 5500 and found ~= 5501)
  end)

  t.it("returns nil when the range is exhausted", function()
    local port, socket = occupy()
    t.eq(net.find_free("127.0.0.1", port, { port, port }, 5), nil)
    socket:close()
  end)
end)

t.describe("port.stable_port", function()
  t.it("is deterministic for a project", function()
    local range = { 5500, 5599 }
    local first = port_mod.stable_port("/tmp/project-a", "live_server", range)
    t.eq(first, port_mod.stable_port("/tmp/project-a", "live_server", range))
  end)

  t.it("stays inside the range", function()
    local range = { 5500, 5510 }
    for index = 1, 50 do
      local port = port_mod.stable_port("/tmp/project-" .. index, "live_server", range)
      t.truthy(port >= 5500 and port <= 5510, "port " .. port .. " escaped the range")
    end
  end)

  t.it("separates projects and adapters", function()
    local range = { 5500, 5599 }
    t.neq(
      port_mod.stable_port("/tmp/project-a", "live_server", range),
      port_mod.stable_port("/tmp/project-b", "live_server", range)
    )
    t.neq(
      port_mod.stable_port("/tmp/project-a", "live_server", range),
      port_mod.stable_port("/tmp/project-a", "browser_sync", range)
    )
  end)

  t.it("ignores a trailing separator", function()
    local range = { 5500, 5599 }
    t.eq(
      port_mod.stable_port("/tmp/project-a", "live_server", range),
      port_mod.stable_port("/tmp/project-a/", "live_server", range)
    )
  end)
end)

t.describe("port pins", function()
  -- Canonical from the start: pins are keyed by resolved path, so a test that
  -- compared raw strings would pass or fail depending on whether the temp
  -- directory happens to be a symlink.
  local root = require("live_server.util").normalize("/tmp/live-server-test-project")

  t.it("round-trips a pin", function()
    port_mod.pin(root, "live_server", 5511)
    t.eq(port_mod.get_pin(root, "live_server"), 5511)
    t.eq(port_mod.get_pin(root, "browser_sync"), nil)
  end)

  t.it("normalises the project path", function()
    port_mod.pin(root .. "/", "live_server", 5512)
    t.eq(port_mod.get_pin(root, "live_server"), 5512)
  end)

  t.it("lists pins", function()
    port_mod.pin(root, "live_server", 5513)
    local found = false
    for _, pin in ipairs(port_mod.pins()) do
      if pin.root == root and pin.adapter == "live_server" then
        found = true
        t.eq(pin.port, 5513)
      end
    end
    t.truthy(found)
  end)

  t.it("removes a pin", function()
    port_mod.pin(root, "live_server", 5514)
    t.truthy(port_mod.unpin(root, "live_server"))
    t.eq(port_mod.get_pin(root, "live_server"), nil)
    t.falsy(port_mod.unpin(root, "live_server"), "removing twice reports nothing was there")
  end)

  t.it("prunes pins for projects that no longer exist", function()
    port_mod.pin("/tmp/live-server-gone-" .. os.time(), "live_server", 5515)
    local removed = port_mod.prune()
    t.truthy(removed >= 1)
  end)
end)

t.describe("port.resolve", function()
  local root = "/tmp/live-server-resolve-test"

  local function with_config(opts, fn)
    config.did_setup = false
    config.setup(opts)
    local ok, err = pcall(fn)
    config.did_setup = false
    config.setup({})
    if not ok then
      error(err, 0)
    end
  end

  t.it("uses an explicit port", function()
    with_config({}, function()
      local result = port_mod.resolve({ root = root, adapter = "live_server", host = "127.0.0.1", requested = 5555 })
      t.eq(result.port, 5555)
      t.eq(result.source, "explicit")
      port_mod.release(5555)
    end)
  end)

  t.it("rejects an invalid explicit port", function()
    with_config({}, function()
      local result, err = port_mod.resolve({ root = root, adapter = "live_server", host = "127.0.0.1", requested = "80" })
      t.eq(result, nil)
      t.contains(err, "privileged")
    end)
  end)

  t.it("prefers a pin over the adapter default", function()
    with_config({ port = { strategy = "pin" } }, function()
      port_mod.pin(root, "live_server", 5531)
      local result = port_mod.resolve({ root = root, adapter = "live_server", host = "127.0.0.1" })
      t.eq(result.port, 5531)
      t.eq(result.source, "pin")
      port_mod.release(5531)
      port_mod.unpin(root, "live_server")
    end)
  end)

  t.it("falls back to the adapter default with no pin", function()
    with_config({ port = { strategy = "pin", defaults = { live_server = 5541 } } }, function()
      port_mod.unpin(root, "live_server")
      local result = port_mod.resolve({ root = root, adapter = "live_server", host = "127.0.0.1" })
      t.eq(result.port, 5541)
      t.eq(result.source, "default")
      port_mod.release(5541)
    end)
  end)

  t.it("never hands the same port to two callers", function()
    with_config({ port = { strategy = "scan", range = { 5560, 5570 } } }, function()
      local first = port_mod.resolve({ root = root, adapter = "live_server", host = "127.0.0.1" })
      local second = port_mod.resolve({ root = root, adapter = "browser_sync", host = "127.0.0.1" })
      t.neq(first.port, second.port, "a reserved port must not be handed out again")
      port_mod.release(first.port)
      port_mod.release(second.port)
    end)
  end)

  t.it("refuses to move a fixed port", function()
    local socket = uv.new_tcp()
    socket:bind("127.0.0.1", 0)
    socket:listen(1, function() end)
    local busy = socket:getsockname().port

    with_config({ port = { strategy = "fixed", defaults = { live_server = busy } } }, function()
      local result, err = port_mod.resolve({ root = root, adapter = "live_server", host = "127.0.0.1" })
      t.eq(result, nil)
      t.contains(err, "already in use")
    end)
    socket:close()
  end)

  t.it("moves off a busy port for other strategies", function()
    local socket = uv.new_tcp()
    socket:bind("127.0.0.1", 0)
    socket:listen(1, function() end)
    local busy = socket:getsockname().port

    with_config({ port = { strategy = "pin", range = { busy, busy + 20 }, defaults = { live_server = busy } } }, function()
      local result = port_mod.resolve({ root = root, adapter = "live_server", host = "127.0.0.1" })
      t.truthy(result)
      t.truthy(result.fallback)
      t.eq(result.preferred, busy)
      t.neq(result.port, busy)
      port_mod.release(result.port)
    end)
    socket:close()
  end)
end)
