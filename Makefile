APP := .build/Prty.app
DEST := $(HOME)/Applications

.PHONY: build test bundle install run logs clean icon

build:
	swift build -c release

test:
	swift test

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/release/Prty $(APP)/Contents/MacOS/Prty
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	codesign --force --sign - $(APP)

install: bundle
	pkill -x Prty || true
	mkdir -p $(DEST)
	rm -rf $(DEST)/Prty.app
	cp -R $(APP) $(DEST)/Prty.app
	open $(DEST)/Prty.app

run: bundle
	pkill -x Prty || true
	open $(APP)

# Redraws Resources/AppIcon.icns from Scripts/icon.swift.
icon:
	rm -rf .build/AppIcon.iconset
	swift Scripts/icon.swift .build/AppIcon.iconset
	iconutil -c icns .build/AppIcon.iconset -o Resources/AppIcon.icns

logs:
	log stream --level info --predicate 'subsystem == "com.fragkakis.prty"'

clean:
	rm -rf .build
