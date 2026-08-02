---@mod live_server.adapters.live_server The `live-server` npm package
---
--- The default for plain HTML/CSS/JS work: it injects CSS without a full page
--- reload, needs no build step and no configuration file.

---@type live_server.AdapterSpec
return {
  name = "live_server",
  display = "live-server",
  bin = "live-server",
  install = "npm install -g live-server",
  live_reload = true,
  supports = {
    host = true,
    entry_file = true,
    ignore = true,
    delay = true,
    css_inject = true,
  },

  ---@param ctx live_server.SpawnContext
  ---@return string[]
  build = function(ctx)
    local argv = {
      "live-server",
      "--port=" .. ctx.port,
      "--host=" .. ctx.host,
      -- We open the browser ourselves, only once the port is confirmed live,
      -- and at the page matching the current buffer.
      "--no-browser",
      "--wait=" .. ctx.delay,
    }

    if ctx.entry_file then
      argv[#argv + 1] = "--entry-file=" .. ctx.entry_file
    end

    local ignore = ctx.ignore
    if #ignore > 0 then
      argv[#argv + 1] = "--ignore=" .. table.concat(ignore, ",")
    end

    for _, arg in ipairs(ctx.extra) do
      argv[#argv + 1] = arg
    end

    -- Positional: the directory to serve. Always last so a user-supplied flag
    -- can never swallow it.
    argv[#argv + 1] = ctx.serve_dir
    return argv
  end,
}
