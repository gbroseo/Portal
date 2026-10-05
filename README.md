# 传送门 Portal

Mac 之间的剪贴板同步 + 文件互传，走 Tailscale（异地也能用）。

- 复制文字 / 图片 / 文件，在另一台 Mac 直接 ⌘V
- 大文件拖到屏幕边上的悬浮小球（或菜单栏 ⇄ 图标）发送，落到对方「下载/传送门」
- 同一 Tailscale 账号的设备自动互信；其他情况用配对码
- 命令行：`portal send <文件…>`、`portal text <文字>`、`portal peers`、`portal key`

## 安装（在终端粘贴一行）

```
curl -fsSL -o /tmp/Portal.dmg https://github.com/gbroseo/Portal/releases/latest/download/Portal.dmg && hdiutil attach -nobrowse -quiet /tmp/Portal.dmg -mountpoint /tmp/portal-mnt && (osascript -e 'quit app id "com.gbroseo.portal"'; sleep 1) && rm -rf /Applications/传送门.app && cp -R /tmp/portal-mnt/传送门.app /Applications/ && hdiutil detach -quiet /tmp/portal-mnt && xattr -cr /Applications/传送门.app && open /Applications/传送门.app && echo 安装完成
```

也可以在 [Releases](https://github.com/gbroseo/Portal/releases/latest) 下载 Portal.dmg 手动安装。两台 Mac 都要先装 Tailscale 并登录同一个账号。

## 开发

构建：`./scripts/build.sh && ./scripts/install.sh`（只需 Command Line Tools）
日志：`~/Library/Logs/Portal.log`；配置：`~/Library/Application Support/Portal/config.json`
测试多实例：`PORTAL_HOME=目录 PORTAL_LOG=文件` 可在本机跑多个实例（配置里改 port）
