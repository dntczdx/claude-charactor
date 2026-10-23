# 克劳德大小姐 · macOS 桌宠通知器

一只住在 macOS 桌面上的「克劳德大小姐」，替你盯着 **Claude 桌面版** 里的所有对话：
有对话在生成时她敲小键盘；某条对话回复完成，她星星眼跳两下，头顶弹出漫画气泡，
里面是这轮的结论和要点；Claude 需要你拿主意时，气泡里直接给选项或输入框，点一下就回答；
点「打开对话」跳回 Claude 桌面版里那条对话。

界面设计稿（可交互）：<https://claude.ai/artifact/TMKzSBHL3VZKzr6Lqp4GA9>

> 角色形象与动画来自网友共创的开源项目 [Claude-girl](https://github.com/wangxianda941030/Claude-girl)
> （美术素材 CC BY-NC 4.0：需署名，不可商用）。本项目不自带素材，第一次运行时由脚本下载并拆帧。

## 它由三部分组成

```
Claude 桌面版 ──(stdio MCP)──▶ mcp/server/index.js ──(HTTP 127.0.0.1:47333)──▶ ClaudeGirl.app
      ▲                               │  notify / wait                             │
      └────── 辅助功能 API：切对话、填答案、看「停止生成」按钮 ◀────────────────────┘
```

| 部分 | 位置 | 作用 |
|---|---|---|
| 桌宠本体（Swift + AppKit） | `Sources/ClaudeGirl/` | 透明置顶窗口、动画、气泡、菜单栏、对话面板、本地事件服务器、辅助功能桥接 |
| MCP 服务器（Node） | `mcp/` | 给 Claude 一个 `notify` 工具；带问题时长轮询等你在气泡里的回答 |
| 脚本 | `scripts/` | 下载并拆帧素材、编译打包 app、把 MCP 写进 Claude 桌面版配置 |

## 在 Mac mini 上部署

前置条件：macOS 13+，Xcode 命令行工具，Homebrew 的 ffmpeg 与 Node 18+。

```bash
xcode-select --install          # 已装可跳过
brew install ffmpeg node

git clone https://github.com/dntczdx/claude-charactor.git
cd claude-charactor

# 1. 下载原项目的动画片段并拆成带透明通道的帧（约 12 段，几十 MB）
scripts/prepare-assets.sh

# 2. 编译并打包成 build/ClaudeGirl.app
scripts/build-app.sh
open build/ClaudeGirl.app        # 想常驻就 cp -R build/ClaudeGirl.app /Applications/

# 3. 把 MCP 服务器装进 Claude 桌面版（写 claude_desktop_config.json）
scripts/install-mcp.sh
```

然后：

1. **授权辅助功能**：第一次启动会弹系统提示；或在菜单栏的茶杯图标里点「授权辅助功能」。
   系统设置 → 隐私与安全性 → 辅助功能 里勾上「克劳德大小姐」。
   没有这个权限也能收通知，只是不能跳转对话、不能替你把答案填进输入框、看不到「正在生成」状态。
2. **完全退出并重开 Claude 桌面版**（⌘Q），设置 → 开发者 里应看到 `claude-girl` 已连接。
3. 把 [`mcp/CLAUDE_PREFERENCES.md`](mcp/CLAUDE_PREFERENCES.md) 里那段话贴进 Claude 桌面版
   **设置 → 个人偏好**。这一步决定 Claude 会不会在每轮回复结束时调用 `notify`。
4. 菜单栏茶杯图标 → 「测试一下气泡」，看一眼效果。

> 每次重新编译后签名会变，辅助功能权限需要在系统设置里重新勾一次。

## 平时怎么用

- **空闲**：原地喝茶、翻书，不会乱动；可以拖到任意位置。菜单里打开「允许到处走」后会一蹦一蹦地沿屏幕底边挪（原项目没有走路动画）。
- **有对话在生成**：敲小键盘，头顶一行灰色小字「xxx · 正在写…」，不打扰。
- **回复完成**：跳两下，漫画气泡弹出：对话主题徽标、一句结论、最多三条要点、「打开对话」「回一句…」「知道了」。20 秒后自动收起，面板里仍可回看。
- **Claude 提问**：气泡里直接是选项按钮和输入框。点选项或回车发送：
  - Claude 的工具调用还挂着（约 48 秒内）→ 答案作为工具结果直接回到那条对话，Claude 接着做；
  - 超时之后 → 大小姐通过辅助功能切到那条对话，把答案填进输入框替你发送。
- **多条同时完成**：按「出错 > 等你回答 > 完成」排队，点掉一条露出下一条。
- **点大小姐**：弹出对话面板，列出所有对话和状态，点一行跳过去。
- **菜单栏茶杯**：同样的对话列表，外加「显示大小姐 / 安静模式 / 允许到处走」。

## 工作原理

1. Claude 桌面版每轮回复结束调用 `notify(topic, headline, points, question?, options?, kind?)`。
2. MCP 服务器 `POST /notify` 给 app；app 以 `topic` 为 key 更新对话状态表，决定姿态和气泡。
3. 若带问题，MCP 服务器 `GET /wait?id=…` 长轮询最多 48 秒（Claude 桌面版约 60 秒会掐断工具调用）。
   你在气泡里的回答会作为工具结果返回；等不到则返回「用户稍后回答」，Claude 结束本轮。
4. 之后你再回答时，app 用辅助功能 API：激活 Claude → 在侧栏按标题找到那条对话 → 聚焦输入框 → 粘贴 → 回车。
5. 与此同时，app 每 1.5 秒看一眼 Claude 窗口里有没有「停止生成」按钮，有就是正在生成（敲键盘姿态）；
   生成结束 4 秒内没收到 `notify`，就用兜底的「这条回复写完了」气泡提醒你。

本地接口（只监听 127.0.0.1，端口 47333）：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 存活、版本、是否已授权辅助功能 |
| POST | `/notify` | `{topic, headline, points[], question?, options[]?, needs_input?, kind?}` → `{id}` |
| GET | `/wait?id=&timeout=` | 长轮询等回答 → `{answered, answer?}` |
| POST | `/status` | `{topic?, state: working\|thinking\|idle}` 只改姿态 |

## 开发

```bash
scripts/prepare-assets.sh
swift run            # 直接跑，自动找源码目录下的 Assets/clips
```

- 动画帧目录：`Assets/clips/<片段代号>/001.png…`，也可用环境变量 `CLAUDEGIRL_ASSETS` 指定。
- 姿态 ↔ 片段映射在 `ClipLibrary.swift` 的 `ClipName.candidates(for:)`，想换动作改那里。
- 设计稿源文件在 `design/`（设计画布的画板）。

## 已知限制 / 排查

- **Claude 桌面版是单窗口**，界面上看不到后台对话的进度，所以「哪条对话完成了」只能靠 Claude 调用 `notify`。
  个人偏好那段话没贴、或 Claude 偶尔忘了调用，就只有兜底提醒（当前可见对话生成结束时）。
- 「打开对话」靠侧栏标题模糊匹配 `topic`；Claude 自动起的标题和 `topic` 差太多时会匹配不到，此时只激活 Claude 窗口。
- 替你填答案依赖 Claude 桌面版的输入框可被辅助功能聚焦；若失败，答案会复制到剪贴板并提示。
- 看不到小人：菜单栏茶杯 → 「显示大小姐」；没有素材时会显示一个橙色占位块并提示运行 `prepare-assets.sh`。
- MCP 没连上：检查 `~/Library/Application Support/Claude/claude_desktop_config.json` 里 `claude-girl` 的 `command` 是绝对路径的 node；
  `curl 127.0.0.1:47333/health` 看 app 是否在跑。

## 致谢与许可

- 角色「克劳德大小姐」及动画、表情包：[Claude-girl](https://github.com/wangxianda941030/Claude-girl)，由百度贴吧网友共创，
  美术素材 [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/)。使用时请署名「克劳德大小姐 · Claude-girl」并附仓库链接，不可商用。
- 本仓库代码：MIT。
