# 开发与发布

## 目录

| 路径 | 内容 |
| --- | --- |
| `src/app/` | SwiftUI 状态窗口、交互和原生行为自检 |
| `src/launcher/` | 随 ChatGPT/Codex 启停的监听器 |
| `src/cli/` | Codex 监测、脚本进度、提问和工具命令 |
| `src/config/` | 首次启动的默认工具注册表 |
| `tests/` | Python 行为测试 |
| `packaging/` | 安装程序、面向用户的说明及 agent skills |
| `scripts/` | 本地构建、发布导出与安装验证 |
| `docs/` | 使用、扩展、隐私和开发文档 |

## 本地验证

在 macOS 13+、Xcode Command Line Tools 和 Python 3.9+ 环境中，从仓库根目录运行：

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
./scripts/build.sh
'build/Small Screen Status.app/Contents/MacOS/SmallScreenStatus' --self-test
'build/Small Screen Status.app/Contents/Resources/Tools/ChatGPTSmallScreenLauncher' --self-test
```

副屏定位、键盘输入和提示动画仍需在连接目标显示屏的 Mac 上实际检查。源码构建输出到 `build/`，不会安装或更改当前用户的应用。

需要让本地源码构建随 ChatGPT/Codex 启停时，可运行 `python3 scripts/install_autostart.py`；`--remove` 取消这项开发环境设置。分享包使用独立的 `packaging/install.py`。

## 导出分享包

```sh
python3 scripts/export_release.py
python3 scripts/verify_release.py
cd dist && shasum -a 256 -c SHA256SUMS.txt
```

回到仓库根目录执行 `python3 scripts/check_privacy.py`，扫描 Git 提交邮箱、跟踪文件和发行 ZIP（包括 ZIP 内嵌套的安装 skill 包）。这个检查覆盖常见用户名路径、邮箱、密钥形态、静态显示规格和误提交的日志/数据库；发布前仍需人工检查截图、设备名称和示例内容。提交使用 GitHub `users.noreply.github.com` 地址，避免在提交元数据中公布个人邮箱。

`export_release.py` 为当前和另一种 Mac 架构构建应用，临时签名，生成应用 ZIP、独立安装 skill ZIP 和校验和。`verify_release.py` 在临时目录验证解压安装、架构、签名、现有 skill 保留、升级备份和损坏包拒绝；测试用 LaunchAgent 有独立名称，不操作正式安装。仅改安装入口或说明、且原生应用已验证时，可以用 `--repack` 复用现有应用。

`build/`、`dist/` 和运行日志不提交到 Git。发布时把 `dist/` 内两个 ZIP 和 `SHA256SUMS.txt` 作为 GitHub Release 附件；tag 指向已验证的源码提交。发布前按 [隐私说明](PRIVACY.md) 检查源码、文档和两个 ZIP；不要把本机应用状态、屏幕信息、测试日志或下载目录放进仓库。
