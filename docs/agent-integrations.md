# Agent 接入安装与移除

通用页提供 Test 与 Install／Remove。Install／Remove 配置当前用户的 AgentPet 接入，不安装或卸载 Agent 客户端，不下载模型。Codex／agy／OpenCode／Pi 管理各自全局位置；DSH 的“Manage”仅打开所选 DSH，独立插件的安装、更新和移除由 DSH 原生插件管理器负责。先安装并正常配置所用客户端，再运行 AgentPet Lite。操作只由用户点击触发；应用启动不自动修改接入配置。

各来源行的ⓘ提供安装、信任、版本兼容和重新加载说明；DSH 的ⓘ同时管理目标位置。通用页与首次引导收起常驻长说明，配置冲突和版本检测失败通过ⓘ显示原因，并停用不安全的配置操作。

## 范围与路径

| 来源 | 本批边界 | 管理位置 |
| --- | --- | --- |
| Codex | 维护；当前 CLI 0.160.0 做原生配置发现与移除检查 | `$CODEX_HOME/hooks.json`，默认 `~/.codex/hooks.json` |
| agy | 维护；当前 CLI 1.3.5 做配置、helper 与移除检查 | `~/.gemini/config/hooks.json` |
| OpenCode | 维护 V1／V2 独立插件，Install 前检测本机 CLI 版本 | V1／旧 V2：`$XDG_CONFIG_HOME/opencode/plugin/agentpet.js`；V2 ≥2.2.2：`$XDG_CONFIG_HOME/opencode/plugins/agentpet-lite/` |
| DSH | 独立插件 `@agentpet-lite/dsh-bridge`，应用消费版本化协议 | Test 核实实际协议／能力；管理入口打开DSH，安装／更新由宿主完成 |
| Pi | 维护原生扩展、生命周期与通用接入；基线 Pi 1.3.0，AionUI 专用组合停止维护 | `~/.pi/agent/extensions/agentpet.ts` |
| Claude Code | 保留兼容入口，暂不维护或专项验收 | 原生适配路径保持兼容 |

Pi 扩展依赖 0.80.4 起提供的 `agent_settled`，更早版本不支持；Pi 1.3.0 是当前适配基线，原生扩展后续由本项目维护。安装位置为 `~/.pi/agent/extensions/agentpet.ts`，自定义 `PI_CODING_AGENT_DIR` 暂需手动管理。自动重试或续跑期间不报完成；取消、错误或未知结果不报成功。安装、更新或移除后需重开实际 Pi 进程。历史 AionUI 2.2.2／pi-acp 0.0.33 的 Pi 跳转实现使用只读 `~/.pi/pi-acp/session-map.json`，将会话文件精确关联到原生 ID，再匹配 AionUi 的 Pi 会话；缺失或歧义不按文件名、标题或项目猜测。独立终端 Pi 沿用终端定位。

Pi 的正常运行／完成气泡与历史 AionUI 精确跳转曾获使用确认；AionUI／AionUI Team 专用适配现已停止维护，后续不跟进其版本兼容或专用问题。气泡页 → 高级筛选需允许显示 Pi；该开关与通用页的接入注册独立。人工输入／权限交互、团队并发和长期恢复需按宿主单独验收。

桌面应用与终端未必继承相同环境变量。使用自定义 CODEX_HOME／XDG_CONFIG_HOME 时，请确认两端指向相同目录。CODEX_HOME 须为绝对路径。OpenCode 的 OPENCODE_CONFIG_DIR 自定义配置根暂不由按钮管理，检测到会提示人工确认，避免写到错误位置。

Codex／agy／OpenCode／Pi 按钮只管理上述全局位置；项目内、第三方插件内或自行改名的接入由对应项目／插件管理。DSH Profile、独立 bridge 及旧 toolkit 的管理均在 DSH 原生管理器中完成；应用只消费协议并提供只读诊断。遇额外已知全局配置引用会暂停修改并显示位置，不把它当成已完整移除。

## 状态与连接测试

每个客户端独立卡片显示图标、名称、**已配置／未配置**、ⓘ、**Test**、**Install／Remove**。Test 与配置检测分别工作。中文按钮仍使用 Test、Install、Remove。

- **未配置**：受管理位置没有可识别的 AgentPet 注册，显示 Install。
- **已配置**：存在可识别的 AgentPet 注册，显示 Remove。旧路径、缺失事件或版本不匹配也属于已有注册；ⓘ说明问题，可先安全 Remove 再 Install。该标签不保证当前注册与应用完全匹配、客户端已加载或 Codex 已信任。
- 检测时显示加载反馈；读取失败时保留上次已知结论（首次失败没有状态结论），ⓘ显示原因，禁用配置操作。不会把失败判为未配置。冲突、归属检查、备份和拒绝覆盖继续生效。
- DSH 卡片使用“Manage”打开宿主；旧 toolkit 内的 bridge 和旧名独立包在 DSH 原生管理器中拆分／迁移，不由应用移除整个 toolkit。

Test 按客户端选择测试对象：Codex／OpenCode／Pi 使用临时隔离接口；DSH 检查日常 desktop 接入环境与 bridge。未配置时仍可 Test，不启动真实模型任务：

| 客户端 | Test 路径 | 成功依据／限制 |
| --- | --- | --- |
| Codex | 临时 CODEX_HOME，app-server stdio | initialize 同 ID 返回 userAgent，然后 initialized；不创建 thread／turn，不验证账号或 Hook 信任 |
| OpenCode V2 | 隔离配置，`api --standalone GET /api/info` | 原生 CLI 管理私有服务认证，返回匹配版本和服务 PID；不连接共享服务 |
| OpenCode V1 | 隔离配置，ACP stdio | initialize 同 ID 返回 protocolVersion=1 和 agentInfo；本机仅有 V2 时 V1 的真实接口仍待验证 |
| Pi | 离线 `--mode rpc --no-session`，禁用扩展、MCP、工具及资源发现 | get_state 同 ID 成功返回空闲、零消息；不保存会话或验证模型认证 |
| DSH | 所选DSH实例的版本化桥接协议 | 同UID内核端点与应用祖先校验；空会话健康、协议／事件连接／待办与导航能力分开检查；兼容包版本独立于应用，旧v1使用新鲜观察回退 |
| agy | 暂无已核实的公开无推理握手路径 | 显示限制；不发 prompt 或启动 Remote Control 守护进程，不以版本检查冒充成功 |
| Claude Code | 保持兼容入口的维护边界 | 不新增连接测试适配，明确显示限制 |

结果面板显示测试中、成功、失败、超时、取消或不支持及下一步，使用本次请求 ID 关联。重复点击受保护；取消、关闭面板或超时收尾本轮临时进程。Test 不复制客户端令牌、修改真实配置／信任、创建真实任务／历史／养成／阅读回执或更新真实上报时间；成功只覆盖本次所列接口或 bridge 通信，不代表 Hook、气泡、生命周期、模型访问和导航均已通过。气泡页的隔离预览继续保留，其结果不能替代连接测试。

接口依据：[Codex App Server](https://learn.chatgpt.com/docs/app-server)、[OpenCode API](https://opencode.ai/v2/docs/api/)、[V1 ACP](https://opencode.ai/docs/acp/)、[Pi RPC](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md)。

## 安装与使用

1. 在设置 → 通用 → Agent 集成点击“Install”。Codex／agy／OpenCode／Pi 命令固定到当前应用的绝对路径；应用移动后，返回此处先 Remove 再 Install 接入。DSH 使用下节的原生包管理流程。
2. Codex 在 CLI 的 `/hooks` 中审阅 AgentPet 的来源与命令，只信任确认过的项目。新定义或改变后的定义可能再次需要审阅。应用不会代写信任、绕过确认或要求信任其他 Hook。
3. Codex 完成信任后先发起新一轮任务；未生效时，待任务结束后重开正在使用的客户端，无需一律同时重启 CLI 与桌面端。CLI 与桌面应用使用同一配置目录时才能共享相应注册；其他宿主仍需按实际配置检查。其他来源按ⓘ帮助中的步骤重开或重新加载。
4. 正常使用时观察桌面气泡；“已配置”不替代真实场景验收。

维护的新版 Codex 默认启用 hooks。若普通 `[features] hooks = false` 或旧别名明确关闭，安装会提示先在原生配置中确认。应用不会修改共享 config.toml 或管理策略；复杂配置、profile、CLI 覆盖与原生策略由 Codex 自身解析。

以下 AionUI 行为仅解释保留的历史兼容实现，不承诺持续适配。AionUi 为 Codex 会话生成标题时，会启动独立的临时 `aionui-title` 客户端。Hook 执行时，AgentPet 核对 AionUi 原生进程登记中的 `aionui-session-title` 标签、当前祖先进程 PID 及完整内核启动时间；匹配时直接忽略该监控事件。成功的临时进程可能来不及写入 Codex 日志，因此不只依赖日志识别。已有记录仍保留精确会话原生创建日志的兼容检查。未知登记或身份不符时正常上报；不按模型名、无标题或超时过滤正常团队任务，不把辅助请求记为完成，也不修改 AionUi／Codex 配置或会话数据。来源：[AionCore 标题客户端实现](https://github.com/iOfficeAI/AionCore/blob/v0.2.2/crates/aionui-session/src/backend/codex_title.rs)。

agy 仅注册 PreInvocation、PostToolUse、Stop；PreToolUse 属于原生权限门，不为监控接入注册。OpenCode 使用原生事件和工具回调，插件不改变工具权限或审批。

## OpenCode V1／V2

V1 与 V2 的插件 API 不兼容。V1 返回 Hook 对象；V2 使用独立的 `id/setup` 定义及公开事件订阅，不能只改文件名或配置项沿用旧插件。Install 前运行本机 `opencode --version`，选择对应实现；ⓘ帮助显示检测版本与兼容说明。版本升级后点击 Refresh，存在 Update 提示时更新接入。V1 重开客户端；V2 请在当前任务结束后执行 `opencode reload`，再重开所用 TUI 加载导航部分；单独重开终端未必会重载后台服务。仅管理磁盘文件，不主动中断正在运行的会话。

V1 接入最低 1.18.34，已验证原生版本 1.18.34／1.19.0；V2 接入最低 2.0.29，本次验证目标为 2.0.29，不据此承诺所有未来版本。检测优先使用应用 PATH，补充 Homebrew 与常见用户安装目录；不运行登录 shell。桌面应用、终端或 AionUi 指定了不同可执行文件时，请核对各自实际版本。未找到 CLI、版本无法识别、过旧或主版本不支持时停止 Install；仍允许 Remove 已确认属于本项目的插件。

V1 和早期 V2 使用受管理单文件；V2 ≥2.2.2 使用目录插件 `plugins/agentpet-lite/{index.js,tui.js,package.json}`。Update 仅迁移已确认归属的 AgentPet 文件，保留其他插件、配置及恢复备份；遇到用户自定义或符号链接拒绝覆盖。Remove 同时识别单文件与目录形态，不依赖 CLI 仍可运行。V1 源码模板保留；V2 单独观察执行开始／完成／失败／中断、工具活动、权限和表单待办及当前公开文本。不读取推理、工具输出或完整历史；只有原生用户中断才记为已停止，其余断线／中断记为结果未知。V2 的服务端观察器与 TUI 导航分开。**V2 精确 TUI 导航最低要求 2.2.2（实际隔离验证版本：2.2.2）**，旧 V2 保留观察功能。新版 TUI 部分须已加载，使用公开 router／tabs 接口显式选择并确认目标，再将该实例的 TTY 交给 AgentPet 原有终端定位。当前精确终端路径为本机 iTerm2／Terminal；其他终端、远程服务、未来主版本不据此承诺。多个实例同时持有目标会话、目标未关联或已失效时不猜测、不标已读；曾由某 TUI 持有的会话可在该实例中重新打开。保留的 AionUI 关联与深链属于停止维护的历史实现，不把宿主能连接当作 Hook 已加载。

V2 2.0.29 的隔离原生测试使用本机模拟模型端点，已验证插件真实加载、任务与 `read` 工具上报及正常结束；V1 现有回归保持，V2 协议测试另覆盖并行待办、子会话／目录隔离、公开文本与卸载清理。未将模拟环境扩展为全部真实模型、宿主或长期恢复均已验收。

依据：[OpenCode V1→V2 迁移说明](https://opencode.ai/v2/docs/build/plugins/migrate-v1)、[V2 插件 API](https://opencode.ai/v2/docs/build/plugins/)。

## DSH 安装、更新与独立包

[`@agentpet-lite/dsh-bridge`](https://www.npmjs.com/package/@agentpet-lite/dsh-bridge) 已独立发布，源码与升级说明位于 [dsh-agentpet-bridge](https://github.com/jiziol/dsh-agentpet-bridge)，离线包及校验文件见其 [Releases](https://github.com/jiziol/dsh-agentpet-bridge/releases)。应用不内附或构建插件。桌面环境在 DSH 的“插件 → 添加插件”中填写包名安装；离线安装选择对应版本的预编译 `.tgz`。desktop Profile 与 web 是不同环境，须使用所选桌面应用对应的管理入口。

首次连接 Lite 时，在 DSH 原生插件管理器的 Host 配置中设置 `eventSocket`，填写 Lite 事件 socket 的**完整绝对路径**。可在终端执行以下命令，再把输出复制进该字段：

~~~sh
printf '%s/.agentpet-lite/agentpet.sock\n' "$HOME"
~~~

该配置字段不会展开 `~`、`$HOME` 或相对路径。自定义 Lite 数据目录时使用实际的 socket 路径。保存后按 DSH 提示重新加载／重启，启动 Lite，在设置中选择匹配的 DSH 桌面应用并点击 Test。没有活动任务也能检查协议、Client 与事件连接，不必额外发起模型任务。

从 Local 迁移的用户应核对原有显式 `eventSocket`；空配置保持旧 Local 默认语义，不会自动寻找 Lite。插件升级不修改此配置或迁移用户数据。包版本与 Lite 版本不要求相同，连接按协议主版本和实际能力判断。

AgentPet 的“Manage”只打开所选DSH，插件安装／更新／移除由原生管理器处理。登记和结构检查为只读诊断，允许兼容插件版本独立变化；不按应用内附版本或摘要要求重装。缺少内附包不会阻断 Test。旧 toolkit／旧名独立包的迁移和重复注册仍需在 DSH 中处理，应用不自动覆盖其配置或移除其他功能。

[协议 v1](dsh-bridge-protocol.md)规定生命周期、公开正文、健康、精确会话关联和导航。新桥支持无任务健康检测；只有已核实所选DSH实例、协议相容、事件连接正确且相关能力可用时分别确认。未知主版本明确不兼容；Client缺失／多Client或导航能力缺失不伪造成功。健康／关联查询不启动模型、切换会话或标记已读。旧 v1 观察帧仍可确认生命周期连接，新增关联查询需要支持bindings.v1的桥；应用不再解析agy-link私有文件。

## 移除与恢复

“Remove”清除受管理 JSON 格式中可明确识别的 AgentPet 命令，包括旧事件、agy 其他命名组中的旧注册；混合组中的其他处理器、匹配条件和用户字段保留。OpenCode 检查全局 plugin／plugins 下的 agentpet.js／agentpet.ts；确认是本仓库生成的完整模板才删除或合并重复项，手动改写内容会保留并提示检查。更新模板时应显式审查旧模板兼容，不能放宽为只看文件头。

移除后必须重开客户端，让内存中已加载的插件／Hook 停止生效。按钮不删除 Agent 客户端、宠物、养成、会话、其他插件或原生配置中的共享功能开关。空的 JSON 容器可能保留，但不再有 AgentPet 注册。

Codex／agy／OpenCode／Pi 的配置修改复用 HookFileTransaction：拒绝符号链接／硬链接／非普通文件、保留文件权限、私有备份及写前核验。备份放在对应配置目录的 `.agentpet-backups`，有意保留作恢复；不属于活动注册。多文件修改先预检，后续写入失败会尝试受保护回退；外部编辑导致无法安全回退时显式报错，不覆盖新内容。不要公开上传这些备份。

若在 config.toml、agy 主 settings.json 或 OpenCode 显式插件数组中另有 AgentPet 引用，先人工整理该引用，避免重复事件或指向已删除文件；安装器不会猜测改写不受管理格式。

## 验证与限制

既有针对性 XCTest 覆盖接入所有权与文件事务；OpenCode 既有生命周期、并行等待、子 Agent、公开回复、导航及迁移回退回归通过。既有隔离接入检查使用真实构建 helper 和本机客户端，不调用模型；这些是历史验证边界，最终候选结果需单独核对：

- 该脚本覆盖 Codex／agy／OpenCode 三类入口：新目录安装、当前配置识别、真实 helper／隔离 Unix socket、移除与重复移除。
- Codex 0.160.0：原生 app-server 列出六项启用但未信任的 Hook；移除后不再出现。没有代替用户进行信任或真实推理验收。
- OpenCode 1.19.0：原生服务发现插件，新会话事件抵达隔离 socket；移除并重启后不再上报。会话创建不进行模型推理。
- OpenCode 2.x：上述无模型脚本在原生私有服务中指定不存在的模型，确认本机 `provider.no-route` 失败抵达插件及移除后停止上报；不向模型端点发请求。空闲会话不会激活位置插件或制造任务帧。正常完成／工具活动另用本机模拟模型验证，不把“插件列出”视为运行任务已验收。
- agy 1.3.5：官方格式配置、安装命令处理原生形状载荷、合法 `{}` 输出与移除均通过；**没有在全新账号中重新登录、交互加载或调用真实模型**，不宣称该完整链路已重新专项验收。

可复现无模型原生检查（需要本机 Codex／agy／OpenCode，以及已构建的开发 Local 包；该脚本按 Local 身份设置隔离端点，不能直接替换为正式 Lite helper）：

```sh
bash scripts/test-integration-setup.sh "$PWD/build/AgentPet Local.app/Contents/MacOS/agentpet"
```

脚本编译与设置页共用的 Core 服务，隔离 Foundation 用户目录、CODEX_HOME、XDG 目录和 OpenCode 测试主目录；不覆盖 HOME，不改真实接入或信任记录。原生依赖初始化可能需要正常网络。可用 AGENTPET_INTEGRATION_REPORT 指定仓库之外的私人结果文件。

`scripts/install-codex-local.py` 与 `install-antigravity-local.py` 仅迁移精确识别的旧官方命令，不能代替新环境通用安装器或任意改写现有配置。旧 OpenCode Python 迁移器已退役；OpenCode 安装、更新和移除使用设置页，统一遵循完整模板所有权检查。

依据：[Codex Hook 与原生信任](https://learn.chatgpt.com/docs/hooks)、[agy Hook 说明](https://www.agy.dev/docs/hooks/)、[OpenCode 1.19.0 插件发现源码](https://github.com/anomalyco/opencode/blob/v1.19.0/packages/opencode/src/config/plugin.ts)、[OpenCode 1.18.34 同一机制](https://github.com/anomalyco/opencode/blob/v1.18.34/packages/opencode/src/config/plugin.ts)。

DSH Test 不会创建临时 ACP Profile、启动 DSH 或对话、安装插件、调用模型、发送导航请求或改变阅读回执。通信确认使用内存中本次真实接收的 metadata，排除持久化历史和队列回放；Unix 探测仅连接并核对本用户 peer 与所选应用进程归属，不发送协议帧。支持健康查询的兼容桥可确认零会话连接；不支持健康查询的旧桥在没有新鲜 observation 时只能报告通信未确认，不能据此判断插件故障。此检查不验证全部 Client 气泡与导航功能。


## Agent Orchestrator 项目任务气泡

AgentPet 可只读观察本机 AO；当前已验组合为基于 Agent Orchestrator 官方 v0.14.6 的补丁版。项目导航和 Chat 阅读同步依赖补丁提供的接口，官方未修改版本不具备这两项新增能力。启动两款应用后，同一个 AO 项目显示一个汇总任务气泡，沿用 Team 的样式与展开／收起交互；项目内 Codex、OpenCode、Pi 等会话共同汇总。不同项目分开，无项目的 standalone 会话保持独立，无需手动绑定成员或修改 AO 配置。

项目范围来自 AO 的精确 projectId；底层客户端仍保留自身身份。只有原生接入提供可验证会话 ID 时才去重 AO 与原生任务，关联不明会明确标识，不根据标题、目录或时间猜测。汇总反映成员工作与等待，Leader 空闲不遮蔽成员活动；单个回合完成、AO idle 或失联均不代表整个项目成功。

AO 待办在项目汇总中保留各自的“确认收到”按钮。确认仅消费所点击的 AO 事实，不审批工具、不清除原生任务未读，也不解决仍在等待的真实会话。断线或应用重启后保留未读事实，待重新读取宿主后才恢复有效角色。

观察通过本机发现文件、只读 API 与事件刷新完成，有读取大小和会话数量上限；不读取完整对话、推理或凭据，不向模型发送任务，不自动创建、恢复或重派会话。AO 项目汇总行点击后优先打开已存在的项目编排器，不可用时退到同项目看板。通过支持外部导航 v1 的 AO 构建，使用稳定项目 ID 和原生 `ao-app://navigate` 入口，无需 macOS 辅助功能或项目名称匹配。官方 v0.14.6 尚未包含此入口；缺少有效能力声明时报告不支持，不回退到辅助功能。能力声明位于所观察 `running.json` 同目录的 `desktop-navigation-v1.json`，绑定真实应用进程和 daemon 代际；只有对应请求的实际页面及前台确认回执才算成功。请求不创建或重启编排器；对象不存在、回执过期或宿主关联变化时报告失败。接口按跨平台设计，本轮仅验 macOS Apple silicon；Intel Mac、Windows/Linux、TUI／远程／Cloud 及全部长期场景未据此验收。项目主区域打开 leader，独立“未读 N”入口打开一个未读成员；只有精确确认对应原生结果才标读该条，看板不标读，导航不审批。

### AO 内查看与已读同步

支持 `session-read.v1` 的 AO 构建独立维护本机 Chat 会话已读水位，侧栏保持官方原有的圆点与运行状态动画，不新增未读呼吸灯。用户在 AO 内从 leader 报告或侧栏进入 worker、在前台看到最新对话底部持续约 1.2 秒后，AO 仅标读该会话。leader 中的摘要、后台窗口、预加载或只选中会话不视为读过 worker。初次启用时历史回复没有可靠旧水位，会保守视为未读。TUI、远程及 Cloud 不在此接口范围。

AgentPet 从 `running.json` 同目录的 `desktop-session-reading-v1.json` 消费独立阅读事实，不要求再次点击宠物。消费前核对能力、真实发布应用、daemon 代际、精确项目/会话与创建时间，以及当前原生回合的唯一覆盖范围；可用时同时核对提供商回合 ID。AO 的序号不与 AgentPet 的通知版本直接比较。已消费的旧阅读事实不重复清除后续通知，新回复与审批继续保留。该能力与导航接口独立，缺失或校验失败时保持未读，不把 idle 当作已读。

## Recorded daily Token usage

The pet status panel shows 30 local calendar days of recorded Token usage. Supported
Agent integrations start recording automatically when detected as configured.
If usage files are not available yet, the start is retained and read health is shown
separately, so the first later usage record remains eligible.
Integration is the only collection switch: configured sources record automatically,
and Remove stops reading and hides their contribution while preserving records.
Reinstallation starts a new interval without backfilling the removed period. The
original start survives restarts; earlier history and test records are excluded.
Collection refreshes every 60 seconds, when the panel opens and after integration
configuration changes. Read-only start/health details live in the existing per-Agent
information sheet; integration cards keep their original controls.

DSH reads the selected shared DSH data directory, covering desktop and TUI clients
using the DSH engine. Other data directories and independent TUI backends are
outside that scope. Usage explicitly attributed to the Antigravity provider is
displayed as agy once; other DSH usage remains DSH. Standalone agy CLI logs are not
read. The Antigravity CLI integration does not imply desktop app compatibility.

Codex rollouts, OpenCode usage metadata in its V1/V2 SQLite projections, DSH V4
plain/zstd persistence and the Claude Code compatibility format are read locally.
Only currently configured supported integrations are read. Missing, unsupported,
damaged or partially written records show incomplete coverage rather than zero.
The chart sums uncached input, cache reads, cache writes and output including
reasoning. It represents reported usage, not a complete account bill. Legacy
OpenCode fork reconstruction and older native formats may have incomplete
coverage; the info button reports these limits.

## 从 Local 迁移到 Lite

正式应用为 `AgentPet Lite.app`（1.0.0），Bundle ID `io.github.jiziol.agentpet-lite`，数据目录 `~/.agentpet-lite`。开发版Local保持独立的 `local.acerz.agentpet`／`~/.agentpet-local` 身份。当前签名为ad-hoc，本机迁移不代表已公证或公开发布。

`python3 scripts/migrate-local-to-lite.py --help`提供显式的只读plan与copy操作。先正常退出Local并导出其最新偏好；目标根目录必须尚不存在。copy在取得来源实例锁后，以校验摘要和SQLite一致备份迁移会话／已读、AO提醒、历史、宠物与声音、用量账本和队列，并生成`migrated-preferences.plist`及`local-migration-v1.json`。复制不导入系统偏好、不安装应用、不改客户端配置或登录项，也不删除来源。运行方须核对报告，再导入新Bundle偏好域并登记已存在的本项目接入。遇目标冲突、运行中来源、符号链接／硬链接、未知账本或复制中发生变化时停止，不能把空白目标当迁移成功。

有效迁移回执允许Lite持有新旧两域的实例锁，并兼容接收已加载Local Helper的事件及原生阅读／导航；旧GUI不能同时运行。新注册指向Lite，但已打开客户端可能仍使用旧代码，待任务结束后按该客户端原生方式重新加载。Codex变更后的Hook仍由用户在原生入口审阅，迁移不改信任。DSH独立桥与AO不因应用换身份而重装或改配置。

登录项按原启用状态重新登记；系统如显示待批准，需用户在系统设置完成。通知及自动化权限属于新应用身份，不能从旧偏好复制授权。Local数据保留作迁移来源；Lite产生新会话／养成／用量后，回退必须保全并迁移这些新增数据，不能直接用旧快照覆盖。旧数据／历史应用清理由独立清单处理。

现有DSH独立桥默认事件端点可能仍为`~/.agentpet-local/agentpet.sock`。本机Local迁移后由上述兼容端点接收；全新Lite安装没有迁移回执时，应由DSH原生插件管理器把桥的`eventSocket`显式设为Lite数据根中的`agentpet.sock`（使用完整绝对路径）。这项插件部署配置由DSH维护侧管理，应用不自动改写。旧端点仍有发布者时，不删除Local兼容目录。
