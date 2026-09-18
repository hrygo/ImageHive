# Convenience targets. The installers are the source of truth; these just drive them.

SHELL := /bin/bash
LABEL ?= local.sensenova-u1
# The project's own version (cli/lib/common.sh is the single source of truth);
# the upstream git tag is recorded as a build stamp instead, so a tarball is
# never mistaken for an upstream release.
VERSION := $(shell sed -n 's/^SV_VERSION="\(.*\)"/\1/p' cli/lib/common.sh)
REVISION := $(shell git describe --tags --always --dirty 2>/dev/null || echo unknown)
NAME := sensenova-u1-$(VERSION)-macos-arm64

.PHONY: help build install uninstall test test-quick doctor release release-verify clean distclean

help:
	@echo "make build       build both products (release)"
	@echo "make install     build, install, restart the service (keeps existing models)"
	@echo "make test        smoke test: protocol + shared-weights assertions"
	@echo "make test-quick  protocol only, no model needed"
	@echo "make doctor      check the installed service"
	@echo "make release     dist/ tarball a user can install without Xcode"
	@echo "make release-verify  install that tarball into a sandbox HOME and check it"
	@echo "make uninstall   remove the service (keeps models)"
	@echo "make clean       swift package clean"

build:
	swift build -c release --product sensenova-served
	swift build -c release --product sensenova-mcp

install: build
	./install.sh --model none --clients none --yes

uninstall:
	./uninstall.sh

test: build
	./tests/smoke.sh

test-quick: build
	./tests/smoke.sh --quick

doctor:
	./cli/sensenova-u1 doctor

# What a non-developer needs: the two binaries, the MLX bundles, and everything
# the installer and the docs read (cli/ is sourced by install.sh, so a tarball
# with only prebuilt/ is not installable). SHA256SUMS lets the downloader check
# the archive before trusting it.
release: build
	@rm -rf "dist/$(NAME)"
	@mkdir -p "dist/$(NAME)/prebuilt"
	@cp .build/release/sensenova-served .build/release/sensenova-mcp "dist/$(NAME)/prebuilt/"
	@for bundle in .build/release/*.bundle; do cp -R "$$bundle" "dist/$(NAME)/prebuilt/"; done
	@cp install.sh uninstall.sh README.md README.zh-CN.md LICENSE NOTICE CHANGELOG.md "dist/$(NAME)/"
	@cp -R cli Docs "dist/$(NAME)/"
	@rm -rf "dist/$(NAME)/cli/__pycache__" "dist/$(NAME)/cli/lib/__pycache__"
	@printf 'sensenova-u1 %s\nrevision   %s\nbuilt      %s\nbuilt on   macOS %s %s\n' "$(VERSION)" "$(REVISION)" "$$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$$(sw_vers -productVersion)" "$$(uname -m)" > "dist/$(NAME)/BUILD-INFO.txt"
	@( cd "dist/$(NAME)" && find . -type f ! -name 'SHA256SUMS' | LC_ALL=C sort \
	     | xargs shasum -a 256 > SHA256SUMS )
	@tar -C dist -czf "dist/$(NAME).tar.gz" "$(NAME)"
	@( cd dist && shasum -a 256 "$(NAME).tar.gz" > "$(NAME).tar.gz.sha256" )
	@echo "dist/$(NAME).tar.gz"
	@echo "dist/$(NAME).tar.gz.sha256"

release-verify: release
	@bash scripts/verify_release.sh "dist/$(NAME).tar.gz"

clean:
	swift package clean

distclean:
	rm -rf .build dist
