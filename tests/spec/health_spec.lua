local t = require("harness")
local config = require("live_server.config")

--- Capture what the health check reports, without a checkhealth buffer.
---@param fn fun()
---@return table<string, string[]>
local function capture(fn)
  local recorded = { ok = {}, info = {}, warn = {}, error = {}, start = {} }
  local names = { start = "start", ok = "ok", info = "info", warn = "warn", error = "error" }
  local saved = {}
  for key, api in pairs(names) do
    saved[api] = vim.health[api]
    vim.health[api] = function(message, ...)
      table.insert(recorded[key], tostring(message))
      return nil, ...
    end
  end

  -- health.lua binds the reporters at require time, so reload it against the
  -- stubs rather than trusting the already-captured upvalues.
  package.loaded["live_server.health"] = nil
  local reloaded = require("live_server.health")
  local ok, err = pcall(fn, reloaded)

  for api, original in pairs(saved) do
    vim.health[api] = original
  end
  package.loaded["live_server.health"] = nil
  require("live_server.health")

  if not ok then
    error(err, 0)
  end
  return recorded
end

---@param lines string[]
---@param needle string
---@return boolean
local function any_match(lines, needle)
  for _, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      return true
    end
  end
  return false
end

t.describe("health check", function()
  t.it("runs end to end without throwing", function()
    local recorded = capture(function(mod)
      mod.check()
      -- Adapter versions resolve asynchronously; let them land.
      vim.wait(5000, function()
        return false
      end, 100)
    end)
    t.truthy(#recorded.start > 0, "no sections were reported")
    t.truthy(any_match(recorded.start, "Server backends"), "backends section missing")
    t.truthy(any_match(recorded.start, "Ports"), "ports section missing")
  end)

  t.it("says so when no dev server is installed", function()
    -- This is the regression that matters: the message lived inside the
    -- "a backend is installed" branch, so the one user who needed it — the
    -- user with nothing installed — was the only user who never saw it.
    local adapters = require("live_server.adapters")
    local saved_available = adapters.available
    adapters.available = function()
      return false
    end

    local recorded = capture(function(mod)
      mod.check()
      vim.wait(2000, function()
        return false
      end, 100)
    end)

    adapters.available = saved_available

    t.truthy(
      any_match(recorded.error, "no dev server is installed"),
      "expected an error naming the missing dependency, got: " .. vim.inspect(recorded.error)
    )
  end)

  t.it("reports configuration problems as errors", function()
    config.did_setup = false
    config.setup({})
    config.options.port.strategy = "bogus"

    local recorded = capture(function(mod)
      mod.check()
      vim.wait(2000, function()
        return false
      end, 100)
    end)

    t.truthy(
      any_match(recorded.error, "port.strategy"),
      "an invalid live config should be reported: " .. vim.inspect(recorded.error)
    )

    config.did_setup = false
    config.setup({})
  end)
end)
