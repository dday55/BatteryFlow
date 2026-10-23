#!/bin/bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

echo "==> 正在编译限充 SMC 助手..."
clang -O2 -Wall -Wextra \
  -framework IOKit -framework CoreFoundation \
  Native/batteryflow-smc.c -o batteryflow-smc

echo "==> 正在编译 BatteryFlow (Swift原生极轻量菜单栏应用)..."

CACHE_DIR="${DIR}/.cache"
mkdir -p "$CACHE_DIR"

swiftc -O -swift-version 6 \
  -module-cache-path "$CACHE_DIR" \
  -parse-as-library \
  Sources/BatteryFlow/L10n.swift \
  Sources/BatteryFlow/Models/PowerModels.swift \
  Sources/BatteryFlow/Services/SMCController.swift \
  Sources/BatteryFlow/Services/ChargeLimiter.swift \
  Sources/BatteryFlow/Services/SMCReader.swift \
  Sources/BatteryFlow/Services/PowerManager.swift \
  Sources/BatteryFlow/Views/RollingNumberText.swift \
  Sources/BatteryFlow/Views/DualBranchSankeyView.swift \
  Sources/BatteryFlow/Views/MenuBarView.swift \
  Sources/BatteryFlow/BatteryFlowApp.swift \
  -o BatteryFlow

echo "==> 组装 BatteryFlow.app Bundle..."
mkdir -p BatteryFlow.app/Contents/MacOS
mkdir -p BatteryFlow.app/Contents/Resources
cp BatteryFlow BatteryFlow.app/Contents/MacOS/
cp Resources/Info.plist BatteryFlow.app/Contents/Info.plist
rm -rf BatteryFlow.app/Contents/Resources/*.lproj
rm -f BatteryFlow.app/Contents/Resources/install-helper.sh
cp -R Resources/*.lproj BatteryFlow.app/Contents/Resources/
if [ -f AppIcon.icns ]; then
  cp AppIcon.icns BatteryFlow.app/Contents/Resources/AppIcon.icns
fi
cp batteryflow-smc BatteryFlow.app/Contents/Resources/batteryflow-smc

# Ad-hoc sign the App Bundle to prevent macOS SIGKILL caused by signature mismatch with resources
codesign --force --deep --sign - BatteryFlow.app >/dev/null 2>&1 || true

echo "==> 编译完成！"
echo "二进制大小: $(ls -lh BatteryFlow | awk '{print $5}')"
echo "App 路径: ${DIR}/BatteryFlow.app"
