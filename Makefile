APP_NAME    = Radio
BUNDLE_ID   = ro.pom.radio
BUILD_DIR   = .build/release
APP_BUNDLE  = build/$(APP_NAME).app
CONTENTS    = $(APP_BUNDLE)/Contents
INSTALL_DIR = /Applications

.PHONY: build install setup clean run

build:
	swift build -c release
	@mkdir -p $(CONTENTS)/MacOS
	@mkdir -p $(CONTENTS)/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(CONTENTS)/MacOS/
	cp Info.plist $(CONTENTS)/
	cp Resources/menubar.png $(CONTENTS)/Resources/
	cp Resources/menubar@2x.png $(CONTENTS)/Resources/
	cp Resources/Assets.car $(CONTENTS)/Resources/
	cp Resources/AppIcon.icns $(CONTENTS)/Resources/
	@mkdir -p $(CONTENTS)/Resources/Metadata.appintents
	cp Resources/Metadata.appintents/* $(CONTENTS)/Resources/Metadata.appintents/
	@# Bundle browser extension inside app (pem kept outside extension dir)
	@mkdir -p $(CONTENTS)/Resources/extension
	cp -R extension/* $(CONTENTS)/Resources/extension/
	@if [ -f radio.pem ]; then cp radio.pem $(CONTENTS)/Resources/radio.pem; fi
	@# Ad-hoc code sign for local development
	codesign --force --sign - --deep $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE)"

install: build
	@echo "Installing to $(INSTALL_DIR)..."
	cp -R $(APP_BUNDLE) $(INSTALL_DIR)/
	@mkdir -p $(HOME)/.config/radio
	@if [ -f config/streams.json ] && [ ! -f $(HOME)/.config/radio/streams.json ]; then \
		cp config/streams.json $(HOME)/.config/radio/streams.json; \
		echo "Copied default streams config"; \
	fi
	@echo "Installed $(APP_NAME).app"

setup:
	brew install ffmpeg yt-dlp streamlink
	@echo "Dependencies installed."

run: build
	open $(APP_BUNDLE)

clean:
	rm -rf build .build
