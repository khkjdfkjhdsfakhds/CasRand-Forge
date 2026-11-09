# Agent 控制（MCP / REST）

CasRand Forge 桌面版（macOS、Windows）内置一个只监听本机的控制接口。Claude Code、Codex 等 Agent 可以通过它在后台修改配置、开始或停止生成、取回结果，不需要操作界面，也不会把窗口切到前台。

## 开启

1. 打开 **设置 → Agent 控制 → 允许 Agent 控制**。默认关闭。
2. 开启后，软件会在 Application Support 目录写入连接信息文件 `agent-control.json`，内容包括地址、访问口令和接入命令。关闭开关或退出软件时会删除这个文件。

| 平台 | 连接信息文件位置 |
|---|---|
| macOS | `~/Library/Application Support/io.github.khkjdfkjhdsfakhds.casrandforge.beta/agent-control.json` |
| Windows | `%APPDATA%\<公司名>\<应用名>\agent-control.json`（具体路径显示在设置页） |

### 接入 Claude Code

在设置页点击“复制 Claude Code 接入命令”，然后在终端运行一次。命令格式如下：

```bash
claude mcp add --transport http --scope user casrand http://127.0.0.1:47823/mcp --header "Authorization: Bearer <口令>"
```

也可以直接让 Agent 读取 `agent-control.json` 并按其中的 `claude_code_command` 完成配置。

### 其他客户端

- **MCP**：Streamable HTTP 传输，地址为 `http://127.0.0.1:<端口>/mcp`，请求头需要带 `Authorization: Bearer <口令>`。
- **REST**：同一端口下的 `/api/v1/`：
  - `GET /api/v1/tools`：列出所有工具及其参数格式
  - `POST /api/v1/tools/<工具名>`：请求体为 JSON 参数，返回 `{"result": ...}`
  - `GET /api/v1/status`：当前状态
  - `GET /api/v1/results/<id>/image`：结果原图（加 `?size=preview` 取缩略图）
- `GET /health` 不需要口令，只用于确认服务在线。

```bash
curl -s -H "Authorization: Bearer <口令>" http://127.0.0.1:47823/api/v1/status
```

## 能做什么

界面上能修改的内容，Agent 基本都能修改：

| 工具 | 作用 |
|---|---|
| `get_status` | 生成状态、进度、当前配置、模型和参考图状态 |
| `get_config` / `update_config` | 读取或修改整份配置，包括提示词、角色、模型、尺寸、步数、CFG、采样器、种子、数量、提示词模式、输出文件夹和保存格式等。修改方式为 JSON Merge Patch 或按 JSON Pointer 修改 |
| `get_prompt_tree` / `set_prompt_node` | 列出级联提示词节点，并按注释路径（例如 `测试用/画师`）修改单个节点 |
| `list_prompt_schemes` / `switch_prompt_scheme` / `create_prompt_scheme` / `rename_prompt_scheme` / `move_prompt_scheme` / `delete_prompt_scheme` | 管理当前配置的随机提示词方案。`get_config`、`get_prompt_tree` 的顶层内容就是当前方案，其他方案在 `/prompt_schemes/<序号>` 下 |
| `list_configs` / `switch_config` / `save_config_as` / `rename_config` / `delete_config` | 管理已保存的配置 |
| `export_config` / `import_config` | 整体导出或导入配置 |
| `add_reference_image` / `clear_reference_images` / `set_reference_feature` / `list_reference_images` | 按文件路径加载图生图原图、Vibe Transfer 和 Precise Reference 参考图，或开关这些功能 |
| `start_generation` / `stop_generation` / `wait_for_generation` | 开始生成（可指定张数，并等待结束）、停止生成 |
| `list_results` / `get_result_image` | 结果列表（含保存路径、提示词和参数），以及结果缩略图或原图 |

修改会和手动操作走同一套保存流程，界面会立即刷新。每次修改或生成，界面底部都会提示“Agent 操作：……”。

## 安全边界

- 只监听 `127.0.0.1`，局域网中的其他设备无法连接。
- 除 `/health` 外，所有请求都需要访问口令。口令可以在设置页重新生成，旧口令会立即失效。
- 拒绝来自非本机网页的请求（检查 Origin 和 Host），防止网页通过浏览器调用接口。
- 任何接口都不会返回 NovelAI Token。API Token、API 地址和代理只能在软件中修改，防止凭据被发送到其他地址。
- 生成进行中，Agent 不能修改配置，需要先停止生成。
- 生成会照常消耗 NovelAI 账号的 Anlas，与手动点击“生成”相同。
