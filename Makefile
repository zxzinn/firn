SHELL := /bin/bash
SWIFT_BUILD_FLAGS ?=
SWIFT_REL_BIN := $(shell swift build $(SWIFT_BUILD_FLAGS) -c release --show-bin-path 2>/dev/null || echo .build/out/Products/Release)
GO ?= $(shell if go version >/dev/null 2>&1; then echo go; else echo "mise exec go@1.27.4 -- go"; fi)

.PHONY: all build hostnet swift rootfs test e2e clean

all: build

rootfs:
	bash guest/build-rootfs.sh

hostnet:
	mkdir -p build build/Firn.app/Contents/MacOS
	cd host/firn-hostnet && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 $(GO) build -ldflags="-s -w" -o ../../build/firn-hostnet .
	chmod 755 build/firn-hostnet

swift:
	swift build $(SWIFT_BUILD_FLAGS) -c release
	mkdir -p build build/Firn.app/Contents/MacOS
	rm -f build/firn build/firnd build/Firn.app/Contents/MacOS/FirnBar
	cp -f "$(SWIFT_REL_BIN)/firn" build/firn
	cp -f "$(SWIFT_REL_BIN)/firnd" build/firnd
	cp -f "$(SWIFT_REL_BIN)/FirnBar" build/Firn.app/Contents/MacOS/FirnBar
	cp -f entitlements.plist build/entitlements.plist
	chmod 755 build/firn build/firnd build/Firn.app/Contents/MacOS/FirnBar
	codesign --entitlements entitlements.plist --force -s - build/firnd
	printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0">' \
	  '<dict>' \
	  '    <key>CFBundleExecutable</key>' \
	  '    <string>FirnBar</string>' \
	  '    <key>CFBundleIdentifier</key>' \
	  '    <string>dev.firn.app</string>' \
	  '    <key>CFBundleName</key>' \
	  '    <string>Firn</string>' \
	  '    <key>CFBundleShortVersionString</key>' \
	  '    <string>0.6.1</string>' \
	  '    <key>CFBundleVersion</key>' \
	  '    <string>0.6.1</string>' \
	  '    <key>LSUIElement</key>' \
	  '    <true/>' \
	  '</dict>' \
	  '</plist>' > build/Firn.app/Contents/Info.plist

build: rootfs hostnet swift
	@echo "[firn] build complete."

test:
	cd host/firn-hostnet && $(GO) test -race -count=1 -v ./...
	cd host/firn-hostnet && $(GO) vet ./...
	cd guest/firn-guestd && $(GO) test -race -count=1 -v ./...
	cd guest/firn-guestd && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 $(GO) vet ./...
	swift run $(SWIFT_BUILD_FLAGS) FirnCoreCheck

e2e:
	bash scripts/e2e.sh

clean:
	rm -rf .build build guest/firn-guestd-bin
