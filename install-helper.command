#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
label=local.ynu.native-vpn-helper
target=/Library/PrivilegedHelperTools/$label
plist=/Library/LaunchDaemons/$label.plist
uid=$(/usr/bin/id -u)
temp=$(/usr/bin/mktemp -t ynu-vpn-helper)
trap '/bin/rm -f "$temp"' EXIT
cat > "$temp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>$target</string><string>$uid</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
</dict></plist>
PLIST
echo '校园 VPN 需要一次 macOS 管理员授权，用于创建虚拟网卡和校园主机路由。'
/usr/bin/sudo -v
/usr/bin/sudo /bin/mkdir -p /Library/PrivilegedHelperTools
if /usr/bin/sudo /bin/launchctl print "system/$label" >/dev/null 2>&1; then
    /usr/bin/sudo /bin/launchctl bootout "system/$label"
fi
/usr/bin/sudo /usr/bin/install -o root -g wheel -m 0755 ./ynu-vpn-helper "$target"
/usr/bin/sudo /usr/bin/install -o root -g wheel -m 0644 "$temp" "$plist"
/usr/bin/sudo /bin/launchctl bootstrap system "$plist"
for attempt in {1..20}; do
    if [[ -S /var/run/ynu-native-vpn.sock ]]; then
        echo '校园 VPN 路由组件已安装。'
        exit 0
    fi
    /bin/sleep 0.25
done
echo '路由组件未就绪。' >&2
exit 1
