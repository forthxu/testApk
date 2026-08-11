#!/usr/bin/env bash
# 在已启动的 Android 模拟器/设备上安装 APK、启动应用并做冒烟检查。
# 由 .github/workflows/apk-test.yml 在 android-emulator-runner 内部调用，
# 也可以在本地连好模拟器后直接执行：bash scripts/apk-test.sh
set -euo pipefail

APK="${APK:-./apps/caipiao-2.1.apk}"
# PKG / ACTIVITY 留空时会在安装后自动识别（支持 APP_URL 下载的新版包）
PKG="${PKG:-}"
ACTIVITY="${ACTIVITY:-}"
DEFAULT_PKG="com.kaijiang.caipiao"
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
  if [ -n "$PKG" ]; then
    adb shell dumpsys package "$PKG" > "$RESULTS/package.txt" 2>&1 || true
  fi
  exit $code
}
trap collect_diagnostics EXIT

echo "==> devices"
adb devices -l
adb shell getprop ro.build.version.sdk
adb shell getprop ro.product.cpu.abi
adb logcat -c || true

# 注意：不要写成 `adb shell pm list packages | grep -q ...`，
# grep -q 命中后立即退出会让上游 adb 收到 SIGPIPE，在 pipefail 下整条管道返回 141 造成误判
packages_before="$(adb shell pm list packages | tr -d '\r' | sort)"

echo "==> installing $APK"
adb install -r "$APK" 2>&1 | tee "$RESULTS/install.txt"
if grep -qi "Failure" "$RESULTS/install.txt"; then
  echo "APK installation failed!"
  exit 1
fi

packages="$(adb shell pm list packages | tr -d '\r' | sort)"
printf '%s\n' "$packages" > "$RESULTS/packages.txt"

# 没有显式指定包名时，用「安装前后包列表的差集」识别本次装上的包
if [ -z "$PKG" ]; then
  PKG="$(comm -13 <(printf '%s\n' "$packages_before") <(printf '%s\n' "$packages") | sed -n 's/^package://p' | head -n1)"
  [ -n "$PKG" ] || PKG="$DEFAULT_PKG"  # 覆盖安装（包已存在）时差集为空，回退到默认包名
  echo "detected package: $PKG"
fi

echo "==> verifying package $PKG"
case "$packages" in
  *"package:$PKG"*) echo "package installed" ;;
  *)
    echo "APK installation failed: Package not found!"
    exit 1
    ;;
esac

# 记录本次被测包的版本信息
adb shell dumpsys package "$PKG" | tr -d '\r' | grep -E "versionName|versionCode" | head -n2 > "$RESULTS/version.txt" || true
cat "$RESULTS/version.txt" || true

# 没有显式指定启动 Activity 时，让 PackageManager 解析 LAUNCHER 入口
if [ -z "$ACTIVITY" ]; then
  ACTIVITY="$(adb shell cmd package resolve-activity --brief "$PKG" 2>/dev/null | tr -d '\r' | tail -n1)"
  case "$ACTIVITY" in
    "$PKG/"*) echo "detected launcher activity: $ACTIVITY" ;;
    *)
      echo "Cannot resolve launcher activity for $PKG!"
      exit 1
      ;;
  esac
fi

{
  echo "apk: $APK"
  echo "package: $PKG"
  echo "activity: $ACTIVITY"
} > "$RESULTS/target.txt"

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
