APP_NAME    := MacMusicPlayer
BUNDLE_ID   := com.local.macmusicplayer
VERSION     := 1.0.0
CONFIG      := release
BUILD_DIR   := $(shell swift build -c $(CONFIG) --show-bin-path 2>/dev/null)
APP_BUNDLE  := build/$(APP_NAME).app
DMG_STAGING := build/dmg-staging
DMG_PATH    := build/$(APP_NAME)-$(VERSION).dmg

.PHONY: all build test app run dmg clean

all: app

build:
	swift build -c $(CONFIG)

test:
	swift test

## 打包成可双击运行的 .app（无需 Xcode 工程文件）
app: build
	@rm -rf "$(APP_BUNDLE)"
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp "$(BUILD_DIR)/$(APP_NAME)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'  <key>CFBundleName</key><string>$(APP_NAME)</string>' \
		'  <key>CFBundleDisplayName</key><string>音乐播放器</string>' \
		'  <key>CFBundleIdentifier</key><string>$(BUNDLE_ID)</string>' \
		'  <key>CFBundleExecutable</key><string>$(APP_NAME)</string>' \
		'  <key>CFBundlePackageType</key><string>APPL</string>' \
		'  <key>CFBundleShortVersionString</key><string>$(VERSION)</string>' \
		'  <key>CFBundleVersion</key><string>$(VERSION)</string>' \
		'  <key>LSMinimumSystemVersion</key><string>14.0</string>' \
		'  <key>NSHighResolutionCapable</key><true/>' \
		'  <key>NSPrincipalClass</key><string>NSApplication</string>' \
		'</dict>' \
		'</plist>' > "$(APP_BUNDLE)/Contents/Info.plist"
	@codesign --force --sign - "$(APP_BUNDLE)" 2>/dev/null || \
		echo "（跳过 ad-hoc 签名，不影响本机运行）"
	@echo "已生成 $(APP_BUNDLE)"

run: app
	open "$(APP_BUNDLE)"

## 打包成 .dmg：装载后是「App 图标 + /Applications 快捷方式」的经典拖拽安装界面
dmg: app
	@rm -rf "$(DMG_STAGING)" "$(DMG_PATH)"
	@mkdir -p "$(DMG_STAGING)"
	@cp -R "$(APP_BUNDLE)" "$(DMG_STAGING)/"
	@ln -s /Applications "$(DMG_STAGING)/Applications"
	@hdiutil create \
		-volname "$(APP_NAME)" \
		-srcfolder "$(DMG_STAGING)" \
		-fs HFS+ \
		-format UDZO \
		-ov \
		"$(DMG_PATH)" >/dev/null
	@rm -rf "$(DMG_STAGING)"
	@echo "已生成 $(DMG_PATH)"
	@echo "注意：未经开发者证书签名与公证，别的 Mac 打开时会被 Gatekeeper 拦截，"
	@echo "      对方需执行：xattr -dr com.apple.quarantine /Applications/$(APP_NAME).app"

clean:
	swift package clean
	rm -rf build .build $(DMG_STAGING)
