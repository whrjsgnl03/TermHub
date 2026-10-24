#!/bin/bash
# TermHub.app 을 만들고 ~/Applications 에 설치한다.
#   --dev : 테스트용 "TermHub Dev.app" 을 build.noindex/ 에만 만든다 (설치 안 함, 저장 파일도 따로)
# build.noindex 폴더는 Spotlight가 무시하므로 검색에 앱이 여러 개 뜨지 않는다.
set -euo pipefail
cd "$(dirname "$0")/.."

DEV=0
[ "${1:-}" = "--dev" ] && DEV=1
NAME=TermHub; BUNDLE_ID=com.chogunhwy.TermHub
if [ $DEV = 1 ]; then NAME="TermHub Dev"; BUNDLE_ID=com.chogunhwy.TermHub.dev; fi

swift build -c release

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
APP="build.noindex/$NAME.app"
mkdir -p build.noindex
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TermHub "$APP/Contents/MacOS/TermHub"

if [ ! -f Resources/AppIcon.icns ]; then
  ICONSET=$(mktemp -d)/AppIcon.iconset
  mkdir -p "$ICONSET"
  swift scripts/make-icon.swift "$ICONSET/base.png"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICONSET/base.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$ICONSET/base.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  rm "$ICONSET/base.png"
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>TermHub</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP"

if [ $DEV = 1 ]; then
  echo "테스트용 빌드 완료: $APP"
  exit 0
fi

mkdir -p ~/Applications
rm -rf ~/Applications/TermHub.app
cp -R "$APP" ~/Applications/
# 중간 결과물은 지워서 설치본 하나만 남긴다
"$LSREGISTER" -u "$APP" 2>/dev/null || true
rm -rf "$APP"
echo "설치 완료: ~/Applications/TermHub.app (실행 중인 TermHub는 다시 켜야 새 버전이 적용돼요)"
