# Live-server.nvim

A modern, feature-rich live server plugin for Neovim with UI enhancements, state management, and automatic browser opening.
##  ✨ Features

* Toggle Servers: Start and stop live-server and browser-sync with a single command.

* State Management: Reliably tracks running servers to prevent duplicates and ensure clean shutdowns.

* UI Lister & Prompts: Use :LiveServerList to view active servers in a floating window, or :LiveServerPrompt to enter a port manually.

* Auto-Open Browser: Automatically opens your default browser to the correct page when a server starts (this can be disabled).

* Smart Directory Detection: Intelligently runs in your project root (if a .git folder exists) or defaults to the current file's directory.

* Automatic Cleanup: Kills all running server instances automatically when you exit Neovim.

* Statusline Integration: Provides a simple component for lualine and other statusline plugins.

##  📦 Installation (Lazy.nvim)
```lua
{
  'G00380316/live-server.nvim',
  lazy = false, -- Recommended to ensure VimLeave cleanup always runs
  config = function()
    require("live_server").setup({
      -- your custom options here
    })
  end,
}
```
##  🚀 Usage

* :LiveServerToggle [port] – Toggles the live-server on or off.

* :BrowserSyncToggle [port] – Toggles the browser-sync server on or off.

* :LiveServerList – Opens a floating window showing all running server instances.

* :LiveServerPrompt – Opens a UI prompt to enter a port before starting live-server.

* :LiveServerOpen – Opens the URL for the running live-server in your browser.

##  Configuration

You can pass a configuration table to the setup() function. The following are the default values:
``` lua
require("live_server").setup({
  browser_sync_port = 3000,
  live_server_port = 8080,
  files_to_watch = '"*.html, *.css, *.js"',
  auto_open_browser = true, -- Set to false to disable
})
```

##  ⌨️ Keymaps

For the best experience, it is highly recommended to set keymaps for the most common commands. You can add these directly to your lazy.nvim plugin spec.

-- In your lazy.nvim spec:
```lua
keys = {
  {
    "<leader>sl",
    function() require("live_server.core").toggle_live_server() end,
    desc = "Toggle Live Server"
  },
  {
    "<leader>sb",
    function() require("live_server.core").toggle_browser_sync() end,
    desc = "Toggle BrowserSync"
  },
  {
    "<leader>sL",
    function() require("live_server.ui").list_servers() end,
    desc = "List Live Servers"
  },
}
```

##  📌 Notes

* This plugin requires live-server and browser-sync to be installed globally via npm. You can install them by running: npm install -g live-server browser-sync.

* The plugin also requires pgrep and pkill to be available on your system for some fallback cleanup operations. These are standard on macOS and most Linux distributions.

Feel free to contribute or submit issues at github.com/G00380316/live-server.nvim
