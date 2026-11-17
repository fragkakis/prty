NAME := PRty Time
EXE := PRtyTime
APP := .build/$(NAME).app
ZIP := .build/PRty-Time.zip
# Notification Center only shows icons of apps in /Applications, not ~/Applications.
DEST := /Applications
ARCHS := --arch arm64 --arch x86_64

.PHONY: build test bundle package zip install run logs clean icon

build:
	swift build -c release

test:
	swift test

bundle: build
	$(MAKE) package BIN="$$(swift build -c release --show-bin-path)/$(EXE)"

# Assembles and ad-hoc signs $(APP) from the binary at $(BIN).
# VERSION=x.y.z overrides the version in Info.plist.
package:
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BIN)" "$(APP)/Contents/MacOS/$(EXE)"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	$(if $(VERSION),plutil -replace CFBundleShortVersionString -string $(VERSION) "$(APP)/Contents/Info.plist")
	$(if $(VERSION),plutil -replace CFBundleVersion -string $(VERSION) "$(APP)/Contents/Info.plist")
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	codesign --force --sign - "$(APP)"

# Universal (Apple Silicon + Intel) app, zipped for a GitHub release.
zip:
	swift build -c release $(ARCHS)
	$(MAKE) package BIN="$$(swift build -c release $(ARCHS) --show-bin-path)/$(EXE)"
	rm -f "$(ZIP)"
	ditto -c -k --keepParent "$(APP)" "$(ZIP)"

install: bundle
	pkill -x $(EXE) || true
	mkdir -p "$(DEST)"
	rm -rf "$(DEST)/$(NAME).app"
	cp -R "$(APP)" "$(DEST)/$(NAME).app"
	open "$(DEST)/$(NAME).app"

run: bundle
	pkill -x $(EXE) || true
	open "$(APP)"

# Redraws Resources/AppIcon.icns from Scripts/icon.swift.
icon:
	rm -rf .build/AppIcon.iconset
	swift Scripts/icon.swift .build/AppIcon.iconset
	iconutil -c icns .build/AppIcon.iconset -o Resources/AppIcon.icns

logs:
	log stream --level info --predicate 'subsystem == "com.fragkakis.prty"'

clean:
	rm -rf .build
