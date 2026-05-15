APP_NAME = Mist
INSTALL_DIR = $(HOME)/Applications
APP_BUNDLE = $(INSTALL_DIR)/$(APP_NAME).app
BUILD_DIR = .build/release
BIN = $(BUILD_DIR)/BloomDictate

.PHONY: build app install clean run

build:
	swift build -c release

# Wrap the SwiftPM binary into a proper macOS .app bundle so TCC reads our
# Info.plist (NSMicrophoneUsageDescription, NSSpeechRecognitionUsageDescription)
# and shows the right consent prompts.
app: build
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(BIN)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@cp Resources/Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	@touch "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	# Force the codesign identifier to match the bundle ID so TCC keys
	# grants by bundle ID (stable across rebuilds), not the SwiftPM-default
	# binary-name identifier that ad-hoc would pick.
	@codesign --sign - --force --deep \
		--identifier com.bloom.mist \
		"$(APP_BUNDLE)" >/dev/null 2>&1 || true
	@echo "wrote $(APP_BUNDLE) (ad-hoc signed with stable identifier)"

run: app
	"$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"

clean:
	swift package clean
	rm -rf "$(APP_BUNDLE)"
