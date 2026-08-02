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

-- Neovim's Lua is not concerned with 120-column purity, but runaway lines hurt
-- review diffs more than they help.
max_line_length = 120

exclude_files = {
  ".test-home/",
}

files["tests/"] = {
  -- The harness deliberately mutates module tables to stub things out.
  ignore = { "122" },
}
