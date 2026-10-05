#!/bin/bash
# 安装 / 更新传送门，可选设置配对码，并把诊断信息发给另一台电脑。
# 用法：curl -fsSL https://raw.githubusercontent.com/gbroseo/Portal/main/scripts/setup.sh -o /tmp/s.sh && bash /tmp/s.sh [配对码] [对方IP]
KEY="${1:-}"
PEER="${2:-}"
APP="/Applications/传送门.app"
P="$APP/Contents/MacOS/Portal"

echo "==> 下载最新版传送门"
curl -fsSL -o /tmp/Portal.dmg https://github.com/gbroseo/Portal/releases/latest/download/Portal.dmg || { echo "下载失败"; exit 1; }
hdiutil detach -quiet /tmp/portal-mnt 2>/dev/null
hdiutil attach -nobrowse -quiet /tmp/Portal.dmg -mountpoint /tmp/portal-mnt || { echo "打开安装包失败"; exit 1; }
osascript -e 'quit app id "com.gbroseo.portal"' >/dev/null 2>&1
pkill -x Portal 2>/dev/null
sleep 1
rm -rf "$APP"
cp -R "/tmp/portal-mnt/传送门.app" /Applications/
hdiutil detach -quiet /tmp/portal-mnt
xattr -cr "$APP"
if [ -n "$KEY" ]; then "$P" key "$KEY" >/dev/null && echo "==> 配对码已设为 $KEY"; fi
open "$APP"
sleep 3

echo "==> 诊断"
"$P" diag 2>&1 | tee /tmp/portal-diag.txt
tail -20 "$HOME/Library/Logs/Portal.log" >> /tmp/portal-diag.txt 2>/dev/null
if [ -n "$PEER" ]; then
  echo "==> 把诊断信息发到 $PEER"
  "$P" send /tmp/portal-diag.txt --host "$PEER"
fi
echo "==> 完成"
