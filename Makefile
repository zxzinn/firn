SHELL := /bin/bash
SWIFT_REL_BIN := $(shell swift build -c release --show-bin-path 2>/dev/null || echo .build/out/Products/Release)

.PHONY: all build swift rootfs test clean

all: build

rootfs:
	bash guest/build-rootfs.sh

swift:
	swift build -c release
	mkdir -p build build/Firn.app/Contents/MacOS
	rm -f build/firn build/firnd build/Firn.app/Contents/MacOS/FirnBar
	cp -f "$(SWIFT_REL_BIN)/firn" build/firn
	cp -f "$(SWIFT_REL_BIN)/firnd" build/firnd
	cp -f "$(SWIFT_REL_BIN)/FirnBar" build/Firn.app/Contents/MacOS/FirnBar
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
	  '    <key>CFBundleVersion</key>' \
	  '    <string>0.3.0</string>' \
	  '    <key>LSUIElement</key>' \
	  '    <true/>' \
	  '</dict>' \
	  '</plist>' > build/Firn.app/Contents/Info.plist

build: rootfs swift
	@echo "[firn] build complete."

test:
	cd guest/firn-guestd && mise exec go@1.27.4 -- go test -race -count=1 -v ./...
	cd guest/firn-guestd && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 mise exec go@1.27.4 -- go vet ./...
	swift run FirnCoreCheck

clean:
	rm -rf .build build guest/firn-guestd-bin
