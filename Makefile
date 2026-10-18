SHELL := /bin/bash
ROOT := $(shell pwd)
CONFIGURATION ?= Debug
APP := $(ROOT)/.build/DerivedData/Build/Products/$(CONFIGURATION)/FileFormatter.app

.PHONY: bootstrap bootstrap-media bootstrap-model project build test run selftest release clean

bootstrap:
	./scripts/bootstrap.sh

bootstrap-media:
	./scripts/build-ffmpeg.sh

bootstrap-model:
	./scripts/fetch-model.sh

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
	./scripts/package.sh

clean:
	rm -rf .build dist
	rm -rf rust/target
	rm -rf Packages/FileFormatterCore/.build
