SHELL := /bin/bash
ROOT := $(shell pwd)
CONFIGURATION ?= Debug
APP := $(ROOT)/.build/DerivedData/Build/Products/$(CONFIGURATION)/FileFormatter.app

.PHONY: bootstrap project build test run selftest release clean

bootstrap:
	./scripts/bootstrap.sh

project:
	xcodegen generate

build: project
	./scripts/build.sh $(CONFIGURATION)

test: project
	./scripts/test.sh

run: build
	open "$(APP)"

selftest: build
	./scripts/selftest.sh

release:
	./scripts/build.sh Release
	mkdir -p dist
	ditto -c -k --keepParent "$(ROOT)/.build/DerivedData/Build/Products/Release/FileFormatter.app" \
		"dist/FileFormatter-0.1.0.zip"

clean:
	rm -rf .build dist
	rm -rf rust/target
	rm -rf Packages/FileFormatterCore/.build
