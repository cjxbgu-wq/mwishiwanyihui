#!/bin/bash
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"

say() { echo -e "\033[1;36m>>> $*\033[0m"; }
die() { echo -e "\033[1;31m!!! $*\033[0m" >&2; exit 1; }

[ -n "$THEOS" ] || die "未设置 \$THEOS"

make clean 2>/dev/null || true
make FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless

FAT=".theos/obj/VcamLite.dylib"
[ -f "$FAT" ] || die "未找到 $FAT"
lipo -info "$FAT" | grep -q arm64e || die "缺 arm64e slice"

mkdir -p artifact
cp -f "$FAT" artifact/VcamLite.dylib
strip -x artifact/VcamLite.dylib 2>/dev/null || true
ldid -S artifact/VcamLite.dylib

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

fakeroot dpkg-deb -Zgzip -b "$DEBROOT" VcamLite_latest.deb
rm -rf "$DEBROOT"
say "完成: VcamLite_latest.deb"
