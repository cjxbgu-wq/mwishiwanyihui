#!/bin/bash
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"

say() { echo -e "\033[1;36m>>> $*\033[0m"; }
die() { echo -e "\033[1;31m!!! $*\033[0m" >&2; exit 1; }

[ -n "$THEOS" ] || die "未设置 \$THEOS"

say "清理"
make clean 2>/dev/null || true

say "Theos 编译 (rootless, arm64+arm64e)"
make FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless

FAT=".theos/obj/VcamLite.dylib"
[ -f "$FAT" ] || die "未找到 $FAT"

say "检查 arm64e slice"
lipo -info "$FAT"
lipo -info "$FAT" | grep -q arm64e || die "缺 arm64e slice"

say "检查 dylib 大小"
ls -la "$FAT"
file "$FAT"

mkdir -p artifact
cp -f "$FAT" artifact/VcamLite.dylib

# Theos 已 strip，这里不再 strip -x，避免破坏 dylib
ldid -S artifact/VcamLite.dylib

say "组装 debroot"
DEBROOT="$PWD/.debroot"
rm -rf "$DEBROOT"
mkdir -p "$DEBROOT/DEBIAN"
mkdir -p "$DEBROOT/Library/MobileSubstrate/DynamicLibraries"

cp -f artifact/VcamLite.dylib "$DEBROOT/Library/MobileSubstrate/DynamicLibraries/VcamLite.dylib"
cp -f VcamLite.plist "$DEBROOT/Library/MobileSubstrate/DynamicLibraries/VcamLite.plist"
chmod 0755 "$DEBROOT/Library/MobileSubstrate/DynamicLibraries/VcamLite.dylib"
chmod 0644 "$DEBROOT/Library/MobileSubstrate/DynamicLibraries/VcamLite.plist"
cp -f control "$DEBROOT/DEBIAN/control"
chmod 0644 "$DEBROOT/DEBIAN/control"

say "打包 deb"
fakeroot dpkg-deb -Zgzip -b "$DEBROOT" VcamLite_latest.deb
rm -rf "$DEBROOT"

say "构建完成"
ls -la VcamLite_latest.deb
dpkg-deb -c VcamLite_latest.deb
say "全部完成 ✅"
