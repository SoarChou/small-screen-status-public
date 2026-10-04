# 小屏工具扩展协议

注册表为 `{"version":1,"widgets":[...]}`。原生应用每 3 秒加载 `~/Library/Application Support/SmallScreenStatus/widgets.json`，首次启动从仓库的 `src/config/widgets.json`（安装包内为应用资源）建立默认注册表。新增现有工具类型无需重编译。工具状态独立保存在同目录的 `tools-state.json`；保持 ID 不变可保留数据。

每个工具需要 `id`、`kind`、`title`，可选 `subtitle` 和 SF Symbols 的 `icon` 名称。ID 使用小写字母、数字、连字符，并且唯一。可选 `monitor: false` 将该工具从任务监测页底部状态栏隐藏；默认展示支持状态摘要的工具。`links` 无状态摘要，空笔记不展示。

| kind | 内容配置 | 用途 |
|---|---|---|
| timer | `presets:[5,25,50]`，单位分钟 | 可暂停／恢复的本地倒计时 |
| note | 无 | 自动保存的多行笔记 |
| checklist | `items:[{"id":"prepare","text":"确认准备工作"}]` | 独立勾选并保存 |
| clock | `zones:[{"title":"本地","timezone":"local"}]` | 本地系统时间或指定时区 |
| links | `links:[{"title":"文档","url":"https://example.com/docs"}]` | 用户点击才打开的入口 |
| readout | `file:"/absolute/path/metrics.json"` | 本地脚本写入的监测读数 |

`readout` 文件格式：`{"label":"任务队列","value":"3 / 8","detail":"正在处理第三项"}`。脚本用临时文件加原子替换写入，原生应用每 3 秒重新读取，任务页与工具页共用读数。应用仅读取注册的文件（最多 1 MiB），不执行命令或连接远端服务。

任务页摘要：计时剩余时间／暂停／完成、清单已勾选数／总项数、非空笔记行数、优先 UTC 的时间、readout 的 value。已删除的清单项目不计入进度。完成计时优先展示并持续高亮，直到重置或重新开始；点击摘要打开对应工具，保留任务的固定监测状态。工具较多时可横向滚动。

```sh
python3 src/cli/widgetctl.py add --id work-notes --kind note --title 任务随手记
python3 src/cli/widgetctl.py add --file /absolute/path/widget.json
python3 src/cli/widgetctl.py update --file /absolute/path/widget.json
python3 src/cli/widgetctl.py validate
```

开发新 kind 时扩展 `src/app/Widgets.swift`、`src/cli/widgetctl.py` 的验证及此协议，再验证真实交互。配色使用 `Theme`，位置快捷键和监测固定属于任务层，不交给工具修改。
