#!/bin/zsh
set -eu
release_dir="${0:A:h}"
if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
  print '本应用监测功能需要 Python 3.9+。可先执行 xcode-select --install 安装 Apple Command Line Tools，再重新打开此安装入口。'
  read '?按回车关闭…'
  exit 1
fi
/usr/bin/python3 "$release_dir/install.py"
print '安装结束。若 macOS 阻止首次打开，请按使用说明完成系统确认。'
read '?按回车关闭…'
