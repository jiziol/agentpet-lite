# 项目目录与职责

项目使用 SwiftPM。`AgentPetCore` 承担状态、协议和存储逻辑；可执行目标 `agentpet` 包含 macOS 应用及供 Hook 调用的 CLI。目标最低 macOS 13，应用依赖 SwiftUI／AppKit、系统 SQLite 和 Sparkle。

## 目录导航

| 目录／入口 | 职责 | 代表文件 |
| --- | --- | --- |
| `Sources/AgentPetCore` | Agent 事件、接入配置、会话状态、持久化、归档和养成计算 | `AgentEvent`、`AgentIntegrationSetup`、`SessionReducer`、`SessionStore`、`PetCare` |
| `Sources/App` | macOS 窗口／菜单栏、宠物显示、动画、额度探测与会话导航 | `AppDaemon`、`PetController`、`PetWindowModel`、`NativeUsageProbe`、`SessionNavigationService` |
| `Sources/App/Settings` | 已拆分的设置子视图与预览状态 | `AboutTabView`、`SettingsPreviewState` |
| `Sources/App/Pets` | 默认宠物的离线安装 | `BundledDefaultPet` |
| DSH bridge协议消费端 | 使用独立适配器的版本化本机协议，独立于插件源码／发行 | `DSHBridgeProtocol`、`DSHObservation`、`DSHNavigation` |
| `Sources/App/Resources/DefaultPets` | 随包媒体、用途清单、来源与许可，不含用户状态 | `deepseek/` |
| `Sources/CSQLite` | 系统 SQLite 的模块桥接 | `module.modulemap`、`shim.h` |
| `Tests/AgentPetCoreTests` | 事件／状态／存储／接入的隔离检查 | Core 对应测试 |
| `Tests/AgentPetAppTests` | 动画／设置／消息／布局检查 | App 对应测试 |
| `scripts` | 构建、验证、受限接入迁移、素材导入 | `build-local.sh`、`verify-local.sh`、`install-*-local.py` |
| `Localizations` | 四种语言资源 | 各语言 `Localizable.strings` |
| `docs`、`third-party-licenses` | 使用／维护说明与第三方来源、许可 | 本页、动画包说明、许可证 |

App 内仍有较多扁平文件。`SetupView.swift` 负责设置路由，并包含通用／宠物页；养成和气泡视图在对应文件，关于页已独立。后续按实际变更拆分，避免仅为目录美观重写现有功能。

## 事件与界面

1. Agent 的 Hook／插件调用 `agentpet hook`，或由 `agentpet run -- <command>` 包装命令；事件通过本地 Unix socket 进入运行中的应用。
2. Core 解析事件并更新会话状态；App 的 observation／metadata coordinator 补齐已适配客户端的元数据和生命周期信息。
3. `SessionReducer` 维护状态转换，相关 effects 交由 App 执行；会话存储与界面观察分开。
4. `PetWindowModel`、任务气泡和宠物视图呈现状态；`SessionNavigationService` 处理受支持会话的跳转。公开回复只使用已观察到的 Agent 内容，不额外请求模型。

原生元数据观察依赖各客户端和宿主，因此支持边界按[维护说明](maintenance-policy.md)限定。气泡页的模拟面板复用展示组件，但不导航、审批真实任务或写入真实会话／养成。

## 接入配置

设置页与首次引导共用 `SettingsModel`；Codex／agy／OpenCode／Pi 配置经 Core `AgentIntegrationSetup`，DSH由App `DSHIntegrationSetup`只读诊断、`DSHReadinessTest`确认协议连接：

- `AgentHooks` 定义受管理的路径与事件，`HookInstaller` 处理配置格式及命令所有权。
- `HookFileTransaction` 提供文件类型检查、私有备份、写前核验和受保护回滚。
- 底层状态检查核对完整事件、当前 helper／socket 和插件模板，保留 absent／configured／needsUpdate 与读取冲突。卡片仅显示未配置／已配置；旧注册和冲突放入ⓘ，读取失败禁用配置操作。“已配置”表示已识别注册存在，不代表完全匹配、运行连接或原生信任。

维护版构建使用 `AGENTPET_LOCAL`，启动时不自动迁移／修复真实接入。修改由明确的 Install／Remove 操作触发。Codex／agy／OpenCode／Pi 在维护范围内；DSH bridge在独立项目维护，应用仅消费协议并提供DSH管理入口；Claude Code 仅保留兼容入口。项目内自行配置不属于全局安装器管理范围，详见[接入说明](agent-integrations.md)。

## 独立 DSH bridge

适配器源码、DSH SDK适配、Typert生成与预编译npm／tgz发行在独立 `dsh-agentpet-bridge` 项目维护。应用构建不需要该源码或产物，不打包桥接资源。协议真源为 [DSH bridge protocol v1](dsh-bridge-protocol.md)。

`DSHIntegrationSetup`只读报告注册与结构异常，不再比较内附版本／摘要，也不调用DSH安装CLI。`DSHReadinessTest`优先按安全Unix端点查询健康；验证所选官方应用的实际进程祖先、Profile／Host身份、协议主版本、事件socket及能力。兼容桥可以独立升级；注册缺失或旧登记不阻断已验证的实际通信。旧v1仍可由新鲜事件和端点确认连接。

DSH私有agy关联文件由适配器读取，应用只请求精确UUID关联。状态、关联与导航共用有界本机传输，但只有明确用户导航才可能形成已读回执；健康与关联查询不创建任务或发起模型请求。所有历史会话键、阅读水位与养成数据保持既有语义；未知协议或歧义明确失败，不以重置真实数据解决版本兼容。

## 资源与用户状态

SwiftPM 把 `Resources/DefaultPets` 复制到资源 bundle；构建脚本将该 bundle 中的当前资源复制进 `.app`，并打包本地化、许可证和 Sparkle.framework。`BundledDefaultPet` 在首次加载时验证并暂存安装默认媒体，保留已有选择和文件，不连接上游图库。`PetInstaller` 继续提供手动图库／导入。

动画按[九组用途](pet-animation-packs.md)组织。媒体包只存素材和默认定义，用户绑定、偏好与养成保存在运行数据域。`SpriteSlicer` 支持原网格和单帧布局，默认鲸鱼娘使用同源海报作单帧回退。

正式 Lite 使用 `io.github.jiziol.agentpet-lite` 偏好域和 `~/.agentpet-lite` 数据目录；开发 Local 使用 `local.acerz.agentpet` 和 `~/.agentpet-local`。构建脚本按应用名选择身份，Lite 在维护策略标志 `AGENTPET_LOCAL` 之外启用 `AGENTPET_LITE`。有效迁移回执允许 Lite 兼容旧端点，并持有新旧两域的实例锁，防止迁移后两个 GUI 并行写入。[Local 迁移说明](agent-integrations.md#从-local-迁移到-lite)列出数据、偏好、接入及回退边界。

历史页已移除，Core 的归档模型与存储保留；旧网页云同步已删除，少量旧结构与纯合并函数保留以兼容数据，没有云端同步调用。

## 修改后的验证

`scripts/verify-local.sh full` 是完整源码检查入口。部分独立检查脚本直接编译 `Sources/AgentPetCore/*.swift`；移动 Core 文件时需同步脚本，避免 SwiftPM 构建正常而独立检查漏编译。资源改动还需核对实际 `.app` 内的文件、许可及签名，不能只验证源码目录。

## Daily usage storage

`TokenUsageCollector` serializes background source reads and transactions.
`TokenUsageReader` consumes native persistence without launching clients or
acquiring their writer locks. DSH decompression uses the bundled, pinned
Zstandard decoder; there is no runtime Node or Homebrew dependency.

`TokenUsageLedger` keeps collection intervals, source health and native call
identities in `usage-v1/ledger.sqlite` below the injected application data root.
This ledger is separate from existing care/XP and project usage. Its schema and
formal/test mode are checked before opening; unknown formats are not migrated
implicitly. Call revisions replace prior counters transactionally, and replay is
idempotent. Queries regroup original timestamps into the current calendar/time
zone for the 30-day view. The integration settings and collector use the same
configuration inspection; integration, recording enablement and read health are
separate states. New eligible instances establish their start automatically, even
before the first usage file exists; unreadable data keeps a health warning. Integration eligibility is the sole collection switch. Legacy closed intervals
resume from the next confirmed integration check; previously excluded gaps stay excluded.
