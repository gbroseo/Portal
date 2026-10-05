# 传送门 Portal

Mac 之间的剪贴板同步 + 文件互传，走 Tailscale（异地也能用）。

- 复制文字 / 图片 / 文件，在另一台 Mac 直接 ⌘V
- 大文件拖到屏幕边上的悬浮小球（或菜单栏 ⇄ 图标）发送，落到对方「下载/传送门」
- 同一 Tailscale 账号的设备自动互信；其他情况用配对码
- 命令行：`portal send <文件…>`、`portal text <文字>`、`portal peers`、`portal key`

构建：`./scripts/build.sh && ./scripts/install.sh`（只需 Command Line Tools）
日志：`~/Library/Logs/Portal.log`；配置：`~/Library/Application Support/Portal/config.json`
测试多实例：`PORTAL_HOME=目录 PORTAL_LOG=文件` 可在本机跑多个实例（配置里改 port）
