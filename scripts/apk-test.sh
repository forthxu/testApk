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
# adb install 失败时先把输出留下来再判断，否则 set -e 会让下面的诊断分支跑不到
install_rc=0
adb install -r "$APK" 2>&1 | tee "$RESULTS/install.txt" || install_rc=$?
if [ "$install_rc" -ne 0 ] || grep -qi "Failure" "$RESULTS/install.txt"; then
  echo "APK installation failed!"
  if grep -q "NO_MATCHING_ABIS" "$RESULTS/install.txt"; then
    echo "APK 的 native lib 与模拟器 ABI 不匹配：$(adb shell getprop ro.product.cpu.abi | tr -d '\r')"
    echo "请改用带 ARM 转译层的 google_apis x86_64 镜像，或换成匹配 ABI 的模拟器"
  fi
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

# 崩溃时打印关键堆栈，并识别「加固壳与模拟器 ABI 不匹配」这类环境问题
explain_crash() {
  adb logcat -d > "$RESULTS/log.txt" 2>&1 || true
  grep -m1 -A 12 "FATAL EXCEPTION" "$RESULTS/log.txt" || true
  if grep -qE "dlopen failed: .* is for EM_" "$RESULTS/log.txt"; then
    echo "-----"
    echo "崩溃原因是 native 库与模拟器 ABI 不匹配（常见于 360 加固包）："
    echo "APK 只带 arm 库时会跑在 x86_64 镜像的 ARM 转译层上，而加固壳按设备 ABI 列表"
    echo "释放了 x86_64 版 libjiagu，dlopen 架构不符导致启动即崩。"
    echo "请把 vars.APP_URL 指向包含 x86_64 的 CI 专用构建（或未加固包）。"
  fi
}

echo "==> checking process is alive"
if [ -z "$(adb shell pidof "$PKG" | tr -d '\r')" ]; then
  echo "App is not running after launch!"
  explain_crash
  exit 1
fi

echo "==> checking crashes"
adb logcat -d > "$RESULTS/log.txt"
if grep -qE "FATAL EXCEPTION|ANR in $PKG" "$RESULTS/log.txt"; then
  echo "App crashed! Check log.txt for details."
  explain_crash
  exit 1
fi

echo "No crashes detected."
