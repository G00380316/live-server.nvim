-- luacheck configuration for live-server.nvim

std = "luajit"
cache = true

globals = {
  "vim",
}

read_globals = {
  "vim",
  "bit",
  "unpack",
}

-- Line width is stylua's job (see stylua.toml). Enforcing it here as well means
-- two tools policing one rule with different definitions of "width" — luacheck
-- counts bytes, stylua counts columns — so a line containing an em dash can
-- satisfy the formatter and still fail the linter. Formatting belongs to the
-- formatter; luacheck is here for correctness.
max_line_length = false

exclude_files = {
  ".test-home/",
}

files["tests/"] = {
  -- The harness deliberately mutates module tables to stub things out.
  ignore = { "122" },
}
