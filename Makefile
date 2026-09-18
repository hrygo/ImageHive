# Convenience targets. The installers are the source of truth; these just drive them.

SHELL := /bin/bash
LABEL ?= local.sensenova-u1

.PHONY: help build install uninstall test test-quick doctor release clean distclean

help:
	@echo "make build       build both products (release)"
	@echo "make install     build, install, restart the service (keeps existing models)"
	@echo "make test        smoke test: protocol + shared-weights assertions"
	@echo "make test-quick  protocol only, no model needed"
	@echo "make doctor      check the installed service"
	@echo "make release     dist/ tarball with prebuilt binaries"
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

# Prebuilt binaries for binary-only installs: ./install.sh --skip-build
release: build
	@mkdir -p dist
	@rm -rf dist/prebuilt && mkdir -p dist/prebuilt
	@cp .build/release/sensenova-served .build/release/sensenova-mcp dist/prebuilt/
	@for bundle in .build/release/*.bundle; do cp -R "$$bundle" dist/prebuilt/; done
	@tar -C dist -czf "dist/sensenova-u1-$$(git describe --tags --always)-macos-arm64.tar.gz" prebuilt
	@echo "dist/$$(ls dist | tail -1)"

clean:
	swift package clean

distclean:
	rm -rf .build dist
