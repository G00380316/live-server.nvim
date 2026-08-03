---@mod live_server.adapters.node Node and framework dev servers
---
--- Runs the project's *own* dev server — `next dev`, `vite`, `nest start:dev`,
--- whatever `package.json` says — through the package manager the repository
--- actually uses.
---
--- Two things make this adapter different from the static ones:
---
---  * It is only available in projects that look like Node projects, so `auto`
---    does not try to run an npm script in a folder of HTML files.
---  * Starting it executes code the repository controls, so it requires
---    consent (see `live_server.trust`). Cloning a repository and pressing a
---    keymap must never be enough to run its scripts.

local framework_mod = require("live_server.framework")
local util = require("live_server.util")

---@type live_server.AdapterSpec
return {
  name = "node",
  display = "node",
  bin = "node",
  install = "install Node.js (https://nodejs.org)",
  -- Overwritten per project once the framework is known; frameworks that
  -- bundle report true, a plain Express app reports false.
  live_reload = true,
  supports = {
    host = true,
    entry_file = false,
    ignore = false,
    delay = false,
    frameworks = true,
  },

  --- Every path here needs Node on `$PATH`; the package manager is checked
  --- per project because it comes from the lockfile.
  detect = function()
    return util.executable("node")
  end,

  --- Per-project availability.
  ---
  --- Under `auto` this stays conservative: only a *recognised* framework wins,
  --- because "package.json has a start script" is far too weak a signal — a
  --- vanilla JS project with `"start": "node build.js"` is not asking for its
  --- build script to be run as a web server. Asking for `node` explicitly
  --- lifts that restriction.
  ---@param project live_server.Project
  ---@param opts? { explicit?: boolean }
  ---@return boolean
  ---@return string? reason
  detect_project = function(project, opts)
    local framework, reason = framework_mod.detect(project.workdir or project.root)
    if not framework then
      return false, reason
    end
    if not util.executable(framework.package_manager.bin) then
      return false, ("%s is not installed"):format(framework.package_manager.bin)
    end
    if not framework.recognised and not (opts and opts.explicit) then
      return false,
        ("no recognised framework; `:LiveServer start node` runs the `%s` script anyway"):format(framework.script)
    end
    return true
  end,

  --- Label shown in the dashboard: "Next.js", "Vite", … rather than "node".
  ---@param project live_server.Project
  ---@return string?
  describe_project = function(project)
    local framework = framework_mod.detect(project.workdir or project.root)
    return framework and framework.display or nil
  end,

  --- Running a repository's scripts is code execution, so it goes through the
  --- same consent gate as a project file that sets `command`.
  ---
  --- Consent is keyed on the *script body*, not the whole `package.json`: a
  --- dependency bump should not re-prompt, but changing what `dev` runs must.
  ---@param project live_server.Project
  ---@return { path: string, content: string, describe: string[], label: string }?
  requires_consent = function(project)
    local framework = framework_mod.detect(project.workdir or project.root)
    if not framework then
      return nil
    end
    return {
      path = framework.package_json or ((project.workdir or project.root) .. "/package.json"),
      content = ("%s\0%s\0%s"):format(framework.script, framework.script_body, framework.package_manager.name),
      describe = framework_mod.describe(framework),
      label = ("%s dev server"):format(framework.display),
    }
  end,

  --- Whether changes reach the browser on their own. Vite and Next have HMR;
  --- a bare Express app does not, and saying otherwise would be a lie the
  --- dashboard repeats.
  ---@param project live_server.Project
  ---@return boolean
  live_reload_for = function(project)
    local framework = framework_mod.detect(project.workdir or project.root)
    return framework ~= nil and framework.live_reload
  end,

  --- Frameworks compile before they listen; a Next.js cold start can take well
  --- over a minute on a large app.
  ---@param project live_server.Project
  ---@return integer?
  ready_timeout = function(project)
    local framework = framework_mod.detect(project.workdir or project.root)
    return framework and framework.ready_timeout or nil
  end,

  --- A socket server listens on a port but serves no page, so there is nothing
  --- to open a browser at.
  ---@param project live_server.Project
  ---@return boolean
  serves_pages = function(project)
    local framework = framework_mod.detect(project.workdir or project.root)
    return not (framework and framework.realtime)
  end,

  --- Dev servers announce the address they actually bound. When that disagrees
  --- with what we asked for — an Express app with a hard-coded `listen(4000)`,
  --- or a framework that walked to the next free port — believe the process,
  --- not our intent.
  ---
  --- A printed URL is unambiguous. A bare "port 5000" is not — it appears just
  --- as often in "port 5000 is in use" — so it is treated as a weaker signal
  --- and only acted on when our own port is not answering.
  url_pattern = "https?://[%w%.%-%[%]]+:(%d+)",
  port_pattern = "[Pp]ort%s*:?%s+(%d+)",

  ---@param ctx live_server.SpawnContext
  ---@return { argv: string[], env: table<string, string> }
  build = function(ctx)
    local framework, reason = framework_mod.detect(ctx.project.workdir or ctx.project.root)
    if not framework then
      error(("this is not a runnable Node project (%s)"):format(reason or "no dev script"), 0)
    end

    local argv, env = framework_mod.command(framework, {
      host = ctx.host,
      port = ctx.port,
      extra = ctx.extra,
    })

    return { argv = argv, env = env }
  end,
}
