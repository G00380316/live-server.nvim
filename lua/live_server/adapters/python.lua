---@mod live_server.adapters.python Python's built-in `http.server`
---
--- The zero-install fallback. No live reload and no SPA rewrites, but it is
--- present on virtually every developer machine and on locked-down build hosts
--- where installing npm packages is not an option.

local util = require("live_server.util")

---@return string?
local function interpreter()
  for _, name in ipairs({ "python3", "python" }) do
    if util.executable(name) then
      return name
    end
  end
  return nil
end

---@type live_server.AdapterSpec
return {
  name = "python",
  display = "python http.server",
  bin = "python3",
  install = "install Python 3",
  live_reload = false,
  supports = {
    host = true,
    entry_file = false,
    ignore = false,
    delay = false,
    no_install = true,
  },

  detect = function()
    return interpreter() ~= nil
  end,

  version_args = { "--version" },

  ---@param ctx live_server.SpawnContext
  ---@return string[]
  build = function(ctx)
    local argv = {
      interpreter() or "python3",
      "-m",
      "http.server",
      tostring(ctx.port),
      "--bind",
      ctx.host,
      "--directory",
      ctx.serve_dir,
    }
    for _, arg in ipairs(ctx.extra) do
      argv[#argv + 1] = arg
    end
    return argv
  end,
}
