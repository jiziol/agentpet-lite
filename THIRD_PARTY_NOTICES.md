# 第三方来源与许可

本项目是上游 AgentPet 的维护衍生版，与所接入的 Agent 厂商没有隶属或背书关系。源码、依赖、美术素材与品牌标识分别适用下述许可和权属说明；根 MIT 不覆盖所有媒体或商标。

| 对象 | 来源／证据 | 当前处理 |
| --- | --- | --- |
| AgentPet 源码 | ntd4996/agentpet，基线 `60b6f0d47d59b78d89a61a916998ac7f09b7e316`；MIT，Copyright (c) 2026 Nguyễn Thành Đạt | 根 LICENSE 原样保留，构建包复制该许可证；About 明确标出上游作者与项目 |
| Sparkle 2.9.2 | 固定 revision `6276ba2b404829d139c45ff98427cf90e2efc59b` | 保留完整 LICENSE（包括 EXTERNAL LICENSES），随 app 打包；本地更新器仍不启动 |
| SQLite | 通过系统 libsqlite3 使用，没有另行随包分发 SQLite 源码 | 声明系统依赖；本轮只验证 macOS SDK 的链接 |
| Agent Orchestrator 项目标识 | [OrchestratorInc/agent-orchestrator](https://github.com/OrchestratorInc/agent-orchestrator/blob/e424538c94ab67940b555efec4d46d25122edec0/frontend/assets/ao-logo.svg)，官方 v0.14.6 固定 revision `e424538c94ab67940b555efec4d46d25122edec0` 的 `frontend/assets/ao-logo.svg`；原始 SVG 未修改，SHA256 `880aec323d4fdf68606a3751bd453eb0529a2bbeac880a5996c8c820b2b7023d` | 仅标识 AO 项目；仓库 Apache-2.0 许可原文保存于 `third-party-licenses/AgentOrchestrator-Apache-2.0.txt` 并随包保留；商标权仍归原权利人，不表示背书 |
| AionUi Team 标识 | iOfficeAI/AionUi，固定 revision `c140550d04e44f3d6f8a9830b40ae56e4689a977` 的 `resources/icon.png`，800×800 原始 PNG；内嵌文件未修改，界面反色为白底黑标并放大内部图形，非独立官方白底文件 | 用于标识所属 AionUi Team，不代表官方合作或背书；原仓库 Apache-2.0 许可副本保存在 `third-party-licenses/AionUi-Apache-2.0.txt`，随包保留。商标权仍归权利人，不授予本项目品牌权利 |
| DSH bridge（外部插件） | `@agentpet-lite/dsh-bridge`，由独立 `dsh-agentpet-bridge` 项目维护 | 不随 Lite 源码或应用包分发；安装、更新与移除由 DSH 原生管理器完成，插件及其依赖的许可由独立发行包保留 |
| OpenCode SVG 标识 | anomalyco/opencode，`907b3bc518fa48e90e8ec24dd327d13eee71c36c` 的 brand 资源；仓库根许可证 MIT | 保留固定来源与根 MIT 副本；仅作产品识别，相关商标归原权利人，不表示官方背书 |
| DSH SVG 标识 | deepseek-ai/deepseek-harness，`5badb15009ae1756c3afe0ae0cef1faafc290ccc` 的 favicon；仓库根许可证 MIT | 保存根许可证与来源；源码许可证不自动解决全部商标使用问题 |
| Codex 标识 | 记录来源为官方 ChatGPT/Codex 26.930.31730 的 webview/assets/codex-app-ga-logo-3e5209898ca3.png，现用透明 PNG 为 104×104 | 采用已记录的固定文件作接入来源识别，按维护者决定保留；相关版权与商标归 OpenAI，不随根 MIT 再许可，不表示官方背书 |
| agy 标识 | 沿用上游内嵌的 256×240 Antigravity PNG；现用字节保持，官方资料见 [Press Assets](https://antigravity.google/press) | 按维护者决定保留现有标识，仅用于识别接入来源；相关版权与商标归 Google，不随根 MIT 再许可，不表示官方背书 |
| Claude Code 标识 | 先前用户指定 thesvg.org SVG；本轮核对与 lobehub/lobe-icons 固定版本 claudecode-color.svg 的所有 path 属性一致 | 已补 LobeHub MIT 许可与固定来源，保留路径／配色；该许可不代表 Anthropic 对本项目背书或额外商标授权 |
| Pi 标识 | 用户提供的像素 P 原 SVG 与 lobehub/lobe-icons 固定版本 pi.svg 整文件摘要相同；AppKit 只归一化宽高，路径保持 | 已补 LobeHub MIT 许可与固定来源；该许可不代表 Pi 厂商对本项目背书或额外商标授权 |
| 常规猫咪 AppIcon.icns | 用户提供 PNG 后裁透明边距生成，原画未重绘；2026-10-15 用户声明为本人原创或自行 AI 生成，并允许随项目公开 | 按用户来源与分发声明关闭此前待确认项；此处记录用户声明，不声称独立核验原创。暗夜素材与自动切换实验不在候选内 |
| Hermes／OpenClaw 自定义字形 | `AgentIcons.swift` 中原有简单 H／爪形 SVG，属于 AgentPet 衍生源码中的自绘占位字形 | 随 AgentPet MIT 保留，不宣称是厂商官方 Logo |
| deepseek 宠物媒体 | PC2005-cloud/dsh-pet；固定 README／许可 commit `e4c8c2af8b8b982d199d39fdec9de3ed5f84ecc5`，MOV Release 为独立来源 | 当前包为33段MOV、对应海报与探边图，其中32段视频与上游压缩包原文件一致，海报由对应视频派生，拖拽视频／海报及探边图是另行提供素材；SOURCE.json与SHA256SUMS.json记录来源和摘要。代码MIT，素材非商业条件及衍生作品介绍／展示／分发来源链接要求保存在LICENSE-ASSETS.md。静态回退直接引用同源海报；未知来源旧精灵图未纳入 |
| 另行提供的默认媒体 | `SOURCE.json.userProvidedMedia` 列出拖拽 MOV、对应海报及 `edge-peek.png`；与上游 Release 来源分开 | 提供者于 2026-11-12 声明三份素材均为 AI 生成，允许随公开源码和 DMG 分发；按该声明记录，原始字节与 C2PA 来源元数据保留，不归作上游原件 |
| 用户导入／在线图库宠物 | 各自 pack、作者或图库的条款 | 不随候选分发；下载／导入者需要分别核查来源与许可，不能套用项目 MIT |

已保存许可证在 `third-party-licenses/`，构建时随 app 复制。品牌标识仅用于兼容产品识别，相关权利归各自权利人，不表示合作或认可；用户导入媒体适用其各自条款。

核查入口：[AgentPet LICENSE](https://github.com/ntd4996/agentpet/blob/60b6f0d47d59b78d89a61a916998ac7f09b7e316/LICENSE)、[Sparkle LICENSE](https://github.com/sparkle-project/Sparkle/blob/6276ba2b404829d139c45ff98427cf90e2efc59b/LICENSE)、[OpenCode LICENSE](https://github.com/anomalyco/opencode/blob/907b3bc518fa48e90e8ec24dd327d13eee71c36c/LICENSE)、[DSH LICENSE](https://github.com/deepseek-ai/deepseek-harness/blob/5badb15009ae1756c3afe0ae0cef1faafc290ccc/LICENSE)、[dsh-pet LICENSE](https://github.com/PC2005-cloud/dsh-pet/blob/e4c8c2af8b8b982d199d39fdec9de3ed5f84ecc5/LICENSE)、[OpenAI 品牌说明](https://openai.com/brand/)。

2026-10-14素材核查补充：[固定README中的素材与二创条款](https://github.com/PC2005-cloud/dsh-pet/blob/e4c8c2af8b8b982d199d39fdec9de3ed5f84ecc5/README.md#许可)比根LICENSE提供了额外素材条件，必须同时保留。About仅列作者名字不足以覆盖README要求的来源链接位置；未来介绍／截图展示／发布页也需附原项目地址。

2026-10-15：已移除上游网页主页、社区及捐赠入口，并删除其专用CoffeeView／donate-vietqr.png资源；上游源码版权与许可证保持。About保留AgentPet与dsh-pet来源链接及素材条件说明。

默认鲸鱼娘媒体位于Sources/App/Resources/DefaultPets/deepseek；本包的LICENSE-CODE.txt只记录dsh-pet代码MIT，素材适用LICENSE-ASSETS.md单独条件。首启离线安装不调用上游图库或安装统计。

## DSH 外部插件许可边界

Lite 只维护版本化协议和消费端，不内附 bridge 安装包、插件代码、内联 Zod 或插件打包清单。独立插件通过 DSH 原生管理器安装、更新与移除；应用不执行其包管理命令，也不以应用内附版本或摘要限制插件升级。

插件代码及其依赖的许可证、第三方说明和发行文件由独立插件项目维护，随其 npm／tgz 发行包提供。Lite 的根 MIT 许可证及宠物媒体条件不替代或改变独立插件的许可。

## 许可副本与品牌标识

Sparkle 的完整许可含 EXTERNAL LICENSES；OpenCode、DSH、dsh-pet、LobeHub、AO 和历史 AionUI 标识的许可副本随源码及 app 保留。根代码版权署名不因维护衍生版或新建公开 Git 历史而删除。

LobeHub 来源为 [lobehub/lobe-icons@05a9b8c41e4735a4a2b6d2f1e43574bd8ec6c8cb](https://github.com/lobehub/lobe-icons/tree/05a9b8c41e4735a4a2b6d2f1e43574bd8ec6c8cb)；Claude Code SVG 的 path／配色及 Pi 原 SVG 保持，AppKit 仅归一化尺寸。对应 MIT 副本为 `third-party-licenses/LobeHub-Icons-LICENSE.txt`。

本发行保留上述现有产品标识，品牌相关权利归原权利人，不将其宣称为本项目原创或可按根 MIT 自由再许可。官方使用说明可参考 [OpenAI 品牌指南](https://openai.com/brand/)、[Google 品牌说明](https://about.google/brand-resource-center/guidance/)、[Antigravity 官方素材页](https://antigravity.google/press)、[OpenCode Brand](https://opencode.ai/brand) 与 [Pi Press Kit](https://pi.dev/press-kit)。这里记录来源、用途与维护者的保留决定，不声称获得新的厂商品牌授权。

## 默认宠物媒体

默认包包含 33 段 MOV 与对应海报：32 段来自已记录的上游 Release，海报由对应视频派生；另行提供的拖拽视频／海报与探边图按上表的提供者声明分开记录。上游动画适用非商业使用与衍生作品介绍／展示／分发附原项目链接的条件，不能将包含这些素材的包宣传为全部 MIT 或无条件商用。

当前文件来源与逐文件摘要见默认包的 `SOURCE.json`、`SHA256SUMS.json` 和 `LICENSE-ASSETS.md`；探边图保留原有 C2PA 来源信息。项目文档、应用致谢和发行说明均保留 [PC2005-cloud/dsh-pet](https://github.com/PC2005-cloud/dsh-pet) 链接。

## Zstandard usage decoder

The usage reader includes unmodified Zstandard v1.5.7 common/decompression sources
from https://github.com/facebook/zstd/releases/tag/v1.5.7, compiled into the application
with legacy codecs and assembly disabled. Copyright Meta Platforms, Inc. and affiliates.
Used under the BSD license in `third-party-licenses/Zstd-BSD.txt`; the same license is
included in packaged applications. Source archive identity is in
`Sources/CUsageZstd/UPSTREAM.json`. No external zstd executable is required.
