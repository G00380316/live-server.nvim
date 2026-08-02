.PHONY: test test-unit lint format format-check docs clean help

NVIM ?= nvim
TEST_HOME := $(CURDIR)/.test-home

help:
	@echo "make test         run the full suite (spawns real servers)"
	@echo "make test-unit    run everything except the integration specs"
	@echo "make lint         luacheck (if installed)"
	@echo "make format       stylua --check, then write"
	@echo "make docs         regenerate helptags"

# XDG overrides keep port pins, trust records and logs out of the real
# ~/.local directories, so a test run can never clobber a developer's state.
define run_tests
	@mkdir -p $(TEST_HOME)
	@LIVE_SERVER_TEST_HOME=$(TEST_HOME) \
	 XDG_DATA_HOME=$(TEST_HOME)/data \
	 XDG_STATE_HOME=$(TEST_HOME)/state \
	 XDG_CACHE_HOME=$(TEST_HOME)/cache \
	 XDG_CONFIG_HOME=$(TEST_HOME)/config \
	 $(1) $(NVIM) --headless -u NONE -l tests/run.lua
endef

test:
	$(call run_tests,)

test-unit:
	$(call run_tests,LIVE_SERVER_TEST_PATTERN='^(util|config|net_port|project|adapters|server|trust|ui)')

lint:
	@command -v luacheck >/dev/null 2>&1 && luacheck lua plugin tests || echo "luacheck not installed, skipping"

format-check:
	@command -v stylua >/dev/null 2>&1 && stylua --check lua plugin tests || echo "stylua not installed, skipping"

format:
	@command -v stylua >/dev/null 2>&1 && stylua lua plugin tests || echo "stylua not installed, skipping"

docs:
	@$(NVIM) --headless -c "helptags doc" -c "qa" && echo "helptags written"

clean:
	@rm -rf $(TEST_HOME)
	@echo "removed $(TEST_HOME)"
