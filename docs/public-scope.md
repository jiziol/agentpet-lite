# 公开源码范围

当前开发仓库用于本地开发检查点；远端存在、文件路径检查通过或本地构建成功均不代表已批准公开。公开源码采用从最终审定快照建立全新初始历史的方案，原开发仓库及历史保留。正式公开前仍须核对候选、素材说明和实际上传对象。本页的导出命令只生成不带 `.git` 的本地审阅快照。

## 计划纳入

| 范围 | 内容与条件 |
| --- | --- |
| `Sources`、`Tests`、`Localizations` | 审定的当前实现、必要检查与四种语言；包含已并入主线的 AO 消费端功能，不能用过期分支快照替代；未跟踪诊断可显式排除并保留在开发区 |
| `Package.swift`、`Package.resolved` | SwiftPM 目标与固定依赖记录 |
| `scripts` 的显式允许项 | 本地构建与验证、隔离检查、接入迁移及动画导入工具 |
| DSH bridge 消费端 | 公开协议、消费端与合成互操作样例；不包含独立适配器源码、npm 依赖、构建或安装包 |
| 应用元数据与图标 | 元数据、经分发依据核对的图标；嵌入 Swift 的 SVG／base64 PNG 同样属于素材审查范围 |
| 默认宠物 | 当前33段MOV、海报与探边图及定义／来源／摘要；上游非商业条款与另行提供素材的授权分别处理，未决前不能作为完整公开包 |
| 许可与公共说明 | 根 LICENSE、第三方许可、中英文 README、贡献指南和下述七份公共指南 |
| `.github/workflows/ci.yml` | 源码验证及 ad-hoc 包构建；不含公开发布、签名、公证或部署操作 |
| `.github/readme` 的显式允许项 | README 展示图、内置动画节选与来源说明；仅使用隔离演示数据和已列明来源的素材，不纳入私人桌面截图或原始验收证据 |

七份公共指南为 `architecture.md`、`maintenance-policy.md`、`agent-integrations.md`、`dsh-bridge-protocol.md`、`pet-animation-packs.md`、`public-scope.md`、`feature-comparison.md`。`.gitignore` 默认排除其他 docs 文件；内部过程文档不通过放宽白名单进入源码。

AppIcon 按提供者的原创／自行生成及分发声明记录。Codex／agy 等品牌文件的具体分发范围和另行提供的默认宠物素材仍有未决项，见[第三方说明](../THIRD_PARTY_NOTICES.md)。不将源码 MIT 套用到全部媒体。

## 排除

| 范围 | 原因 |
| --- | --- |
| 认证、密钥、账号指纹、配置与偏好 | 私人或敏感信息 |
| 运行目录、养成／任务／额度／阅读记录、配置备份 | 用户数据，不属于默认资源 |
| AGENTS／本机规则、README.local、私有交接、原始截图与审计流水 | 本机维护材料，不随克隆分发 |
| `.git`、stash、reflog、未经审查的开发历史 | 当前文件检查不能替代历史审查 |
| `.build`、`build`、日志、缓存、ZIP／DMG／app、依赖生成目录 | 不属于源码；二进制附件单独核验 |
| 旧动画工作目录、未用精灵图、暗夜实验、原始筛选媒体 | 非当前默认包，或来源／条件未核实 |
| 上游 Web／Windows／官网／CDN／营销素材及旧发布管线 | 超出当前 macOS 维护范围 |

## 导出与检查

在开发仓库根目录执行，输出必须是仓库之外尚不存在的新目录：

```sh
python3 scripts/prepare-source.py --check-index
python3 scripts/prepare-source.py --tracked-only --output ../agentpet-lite-source-review
```

导出读取**当前工作区字节**，不是 `git archive HEAD`。`--tracked-only` 排除未跟踪文件，适合保留私有诊断但不将其混入候选；不加该选项时允许范围内的未跟踪文件也会纳入。新增的必要公开文件须先审查并有意纳入跟踪，不能依赖此选项替代候选完整性检查。

输出包含 `agentpet-lite-source-review.zip`、`source-manifest.json` 和 `SHA256SUMS`；清单记录来源提交、dirty 状态、导出模式、逐文件 SHA256 和排除项。来源提交号不表示所有文件与提交相同。清单是本地审计附件，公开前也需检查排除路径是否含私有信息。

解压后的无 Git 源码运行：

```sh
python3 scripts/prepare-source.py --check-tree
swift package resolve --force-resolved-versions
bash scripts/verify-local.sh full
AGENTPET_APP_NAME="AgentPet Lite" bash scripts/build-local.sh
```

`--check-index` 检查整个 index 的允许路径、普通文件类型、冲突状态和必需文件，包括强制暂存项；不会修改 index。`--check-tree` 检查无 Git 源码树，忽略 `.build`、`build`、`.swiftpm` 生成目录。`verify-local.sh` 按是否有 `.git` 选择入口。两种检查都只检查文件范围，不审计正文、隐私、素材许可、历史或生成目录内容。导出时的有限密钥模式扫描也不是隐私证明。

## 内容与历史审核

1. 固定来源及未提交差异，核对导出清单、资源和必要测试；构建后再次核对源文件摘要，验证日志与包另行登记。
2. 扫描并人工核对秘密、账号、个人路径、会话正文及二进制／内嵌媒体元数据。合成 ID 与许可证中的公开作者署名不能误当作应删除的秘密。
3. `scripts/checks/fixtures/refactor-baseline/codex-native-metadata.jsonl` 是去正文、平移时间与稳定别名处理后的历史元数据；旁边 README 说明范围。发布前复核仅保留允许字段，不包含原始问题、选项、答案、命令或凭据。不得把匿名化等同于全部夹具天然无隐私。
4. 复核第三方来源、修改说明、许可原文、App 内致谢及实际包内资源；有非商业条件的素材须单独说明，不能标成全部 MIT。
5. 从审定快照建立公开初始历史时，检查实际上传的对象、提交作者信息、消息、tag 与分支；本地所有 refs 的扫描不能自动批准公开历史。

**开发历史仍含已迁出的内部记录和本机路径，禁止直接整体推送。** 已验 R5 功能已并入当前主线，最终候选还需包含后续审定改动；保留现有开发历史，不在原仓库重写或清空历史来准备公开版。

公开版采用全新初始历史，同时在根许可、README 和第三方说明中保留上游版权、来源与对应基线。公开仓库与原开发库分开管理；本页不授权创建远端仓库、push、tag 或 Release。
