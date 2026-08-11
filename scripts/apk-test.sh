#!/usr/bin/env bash
# 在已启动的 Android 模拟器/设备上安装 APK、启动应用并做冒烟检查。
# 由 .github/workflows/apk-test.yml 在 android-emulator-runner 内部调用，
# 也可以在本地连好模拟器后直接执行：bash scripts/apk-test.sh
set -euo pipefail

APK="${APK:-./apps/caipiao-2.1.apk}"
PKG="${PKG:-com.kaijiang.caipiao}"
ACTIVITY="${ACTIVITY:-com.kaijiang.caipiao/.ui.main.MainActivity}"
RESULTS="${RESULTS:-./results}"
WAIT_SECONDS="${WAIT_SECONDS:-15}"

mkdir -p "$RESULTS"

# 不论成功失败都尽量收集日志与截图，方便 Upload Artifacts 上传
collect_diagnostics() {
  code=$?
  echo "==> collecting diagnostics (exit=$code)"
  adb devices -l > "$RESULTS/devices.txt" 2>&1 || true
  adb logcat -d > "$RESULTS/log.txt" 2>&1 || true
  adb exec-out screencap -p > "$RESULTS/screenshot.png" 2>/dev/null || true
  adb shell dumpsys package "$PKG" > "$RESULTS/package.txt" 2>&1 || true
  exit $code
}
trap collect_diagnostics EXIT

echo "==> devices"
adb devices -l
adb shell getprop ro.build.version.sdk
adb shell getprop ro.product.cpu.abi
adb logcat -c || true

echo "==> installing $APK"
adb install -r "$APK" 2>&1 | tee "$RESULTS/install.txt"
if grep -qi "Failure" "$RESULTS/install.txt"; then
  echo "APK installation failed!"
  exit 1
fi

echo "==> verifying package $PKG"
# 注意：不要写成 `adb shell pm list packages | grep -q ...`，
# grep -q 命中后立即退出会让上游 adb 收到 SIGPIPE，在 pipefail 下整条管道返回 141 造成误判
packages="$(adb shell pm list packages | tr -d '\r')"
printf '%s\n' "$packages" > "$RESULTS/packages.txt"
case "$packages" in
  *"package:$PKG"*) echo "package installed" ;;
  *)
    echo "APK installation failed: Package not found!"
    exit 1
    ;;
esac

echo "==> launching $ACTIVITY"
adb shell am start -W -n "$ACTIVITY" 2>&1 | tee "$RESULTS/launch.txt"
if grep -q "Error:" "$RESULTS/launch.txt"; then
  echo "Failed to launch APK!"
  exit 1
fi

echo "==> waiting ${WAIT_SECONDS}s for the app to settle"
sleep "$WAIT_SECONDS"

echo "==> checking process is alive"
if [ -z "$(adb shell pidof "$PKG" | tr -d '\r')" ]; then
  echo "App is not running after launch!"
  exit 1
fi

echo "==> checking crashes"
adb logcat -d > "$RESULTS/log.txt"
if grep -qE "FATAL EXCEPTION|ANR in $PKG" "$RESULTS/log.txt"; then
  echo "App crashed! Check log.txt for details."
  exit 1
fi

echo "No crashes detected."
