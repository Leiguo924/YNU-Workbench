#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
output="${1:-$PWD/build}"
mkdir -p "$output"
output=$(cd "$output" && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
stage="$scratch/release"
app="$stage/云大工作台.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
c=(/usr/bin/clang -arch arm64 -mmacosx-version-min=13.0 -Wall -Wextra -Werror)
"${c[@]}" -c DPUtun.c -o "$scratch/DPUtun.o"
"${c[@]}" -c DPHelper.c -o "$scratch/DPHelper.o"
"${c[@]}" -DDP_HELPER_SERVER DPHelper.c DPUtun.c -o "$stage/ynu-vpn-helper"
/usr/bin/swiftc -parse-as-library -swift-version 5 -warnings-as-errors -target arm64-apple-macosx13.0 \
    -module-cache-path "$scratch/modules" -import-objc-header DPNativeBridge.h \
    "$scratch/DPUtun.o" "$scratch/DPHelper.o" -o "$app/Contents/MacOS/CampusVPN" \
    DPControl.swift DPCampusPolicy.swift DPKernelSession.swift DPMenuApp.swift NetworkReport.swift CampusNotices.swift CampusOffice.swift CampusOfficeDirectory.swift DesktopAgenda.swift ReminderExport.swift YNUStudy.swift YNUWeek.swift \
    YNUBrowserBridge.swift DPTCPTransport.swift DPIcmpProbe.swift DPPacketCodec.swift DPUdpProtocol.swift \
    DPUdpTransport.swift DPVirtualInterface.swift
cp Info.plist "$app/Contents/"
cp Workbench.icns "$app/Contents/Resources/"
cp install-helper.command README.md "$stage/"
chmod 755 "$stage/install-helper.command"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
archive="$output/YNU-Workbench-$version-macOS-arm64.zip"
ditto -c -k --norsrc "$stage" "$scratch/release.zip"
unzip -tq "$scratch/release.zip"
mv "$scratch/release.zip" "$archive"
echo "$archive"
