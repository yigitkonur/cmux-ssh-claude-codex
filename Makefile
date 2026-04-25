SHELL := /bin/bash

PREFIX ?= $(HOME)/.cc-ssh
BIN_DIR := $(PREFIX)/bin
LIB_DIR := $(PREFIX)/lib
SHARE_DIR := $(PREFIX)/share

SH_FILES := $(shell find bin lib -type f \( -name '*.sh' -o -name 'cc-ssh' \) 2>/dev/null)
BATS_FILES := $(shell find tests -name '*.bats' 2>/dev/null)

.PHONY: all test lint install uninstall clean help

all: lint test

help:
	@echo "Targets:"
	@echo "  lint       Run shellcheck on bin/cc-ssh and lib/*.sh"
	@echo "  test       Run bats tests"
	@echo "  install    Install to \$$PREFIX (default: ~/.cc-ssh)"
	@echo "  uninstall  Remove the installed tree (state preserved)"
	@echo "  clean      Remove build artifacts"

lint:
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		echo "shellcheck not found; skipping lint" >&2; \
		exit 0; \
	fi
	shellcheck -x $(SH_FILES)

test: lint
	@if ! command -v bats >/dev/null 2>&1; then \
		echo "bats not found; install with 'brew install bats-core'" >&2; \
		exit 1; \
	fi
	bats tests/

install:
	@install -d $(BIN_DIR) $(LIB_DIR) $(SHARE_DIR)
	@install -m 0755 bin/cc-ssh $(BIN_DIR)/cc-ssh
	@install -m 0644 lib/*.sh $(LIB_DIR)/
	@install -m 0644 share/*.example $(SHARE_DIR)/ 2>/dev/null || true
	@echo "Installed cc-ssh to $(BIN_DIR)/cc-ssh"
	@echo "Add to PATH: export PATH=\"$(BIN_DIR):\$$PATH\""

uninstall:
	@rm -f $(BIN_DIR)/cc-ssh
	@rm -rf $(LIB_DIR)
	@rm -rf $(SHARE_DIR)
	@echo "Uninstalled cc-ssh from $(PREFIX); state preserved at $(PREFIX)/state"

clean:
	@find tests -name '*.tmp' -delete 2>/dev/null || true
	@rm -rf tests/.tmp 2>/dev/null || true
