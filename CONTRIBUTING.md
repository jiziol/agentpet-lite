# 参与维护

本项目维护 [README](README.md) 所列 Codex、agy、OpenCode、DSH、Pi 和 AO 的已适配 macOS 场景。Pi 的原生扩展、接入安装和生命周期纳入持续维护；AionUI／AionUI Team 专用适配已停止维护，旧实现保留，不再承担其版本兼容或导航修复。AO 导航与阅读接口由宿主补丁提供，应用只维护消费端。Claude Code 保留兼容入口，但不承担新增适配、版本兼容或专项验收。功能变更前请先确认维护范围，避免重新引入已移除的网页同步、历史页或退役来源。

## 本地开发

使用完整 Xcode、Node.js 22+ 和 Python 3.9+。已验证的工具链为 Xcode 26.3 / Swift 6.2.4，CI 通过 `DEVELOPER_DIR` 固定到同一版本；旧版 Swift 的 XCTest 主线程隔离检查可能无法编译现有测试。首次构建需要网络解析 SwiftPM 依赖：

~~~sh
swift package resolve --force-resolved-versions
bash scripts/build-local.sh
bash scripts/verify-local.sh full
~~~

默认应用产物为 `build/AgentPet Local.app`；构建不自动安装。正式Lite构建使用 `AGENTPET_APP_NAME="AgentPet Lite" bash scripts/build-local.sh`，产物 `build/AgentPet Lite.app`，Bundle ID／数据域与Local分开。`AGENTPET_LOCAL`是维护策略的历史编译标志；Lite额外启用`AGENTPET_LITE`选择正式身份，不启用上游服务或更新器。完整验证运行两个 SwiftPM 测试目标及 Swift／Node／Python 检查。`portable` 模式不包含 XCTest，不能用它声称完整验证通过。验证日志默认位于 `.build/verification/`。

生成正式Lite后可运行 `python3 scripts/package-dmg.py`：创建仅含应用、Applications快捷方式和安装说明的DMG，执行只读挂载／签名／逐文件核对，生成SHA256；成功后移除重复构建.app，保留DMG作为同版本唯一完整候选。打包不自动安装或发布。

应用包构建额外启用 `AGENTPET_APP_BUNDLE`，从自身 `Contents/Resources` 读取宠物和图标，不携带 SwiftPM 的绝对编译目录回退。开发工具和普通 `swift test` 继续使用 SwiftPM 资源。脚本在签名前检查可执行文件，拒绝残留的资源回退路径或用户主目录路径；自定义缓存也受检查。

局部修改可按影响范围执行已有检查；涉及目标、资源、状态存储或目录结构时运行完整验证。接入变更还可按[接入说明](docs/agent-integrations.md)运行隔离原生检查。不要向真实运行数据写合成事件，不通过真实模型任务制造验收结果。

职责划分见[架构说明](docs/architecture.md)。添加动画时遵守[动画包格式](docs/pet-animation-packs.md)，提供准确来源与许可，媒体中不要携带个人养成或偏好。

## DSH bridge 消费端

适配器为独立维护项目 `dsh-agentpet-bridge`，其源码、固定 SDK、生成描述符、Node测试与 npm／tgz 打包不属于应用构建。应用不导入适配器源码、不内附插件，不通过包版本或文件摘要限制运行连接。协议真源为 [DSH bridge protocol v1](docs/dsh-bridge-protocol.md)，最小合成样例在 `Tests/Fixtures/dsh-bridge-v1.json`；适配器使用固定版本的副本作互操作检查。

修改消费端时验证未知协议拒绝、兼容发行版本、空会话健康、事件连接与能力区分、精确身份及导航回执；DSH私有会话／账号关联格式由适配器转换为规范结果。注册检查只作诊断，不是协议连接前置门禁。安装、更新、移除由DSH原生管理器执行，应用只提供管理入口和说明。独立插件归档、构建检查、宿主安装和自然场景验收分别留证，不互相代替。

## 公共文件与内部记录

`docs/` 仅维护公共指南：架构、维护范围、Agent 接入、动画包格式、公开范围，以及[能力演进与验证边界](docs/feature-comparison.md)。另包括DSH桥接协议；功能对比包含可复用的独立评测建议，实际评测记录不属于公共指南。发布决策、开发流水和原始验证证据在仓库外私有维护区保存；公共指南只保留经过隐私核对的稳定结论。本机代理维护指引不随公开源码或克隆分发。

提交前检查暂存区：

~~~sh
python3 scripts/prepare-source.py --check-index
~~~

检查覆盖整个 Git index 的允许路径、普通文件类型、无冲突状态及必需根文件／七份公共指南，强制暂存也受检查。它不检查文件正文、隐私或历史，也不生成导出文件。本机安装的 pre-commit、CI 和 `verify-local.sh` 会执行此检查；本机钩子不随克隆继承。

新增文件若被拒绝，先确认公开用途，再有意更新 `prepare-source.py` 的允许清单；新增公共 docs 还须同步 `.gitignore`。内部笔记继续放在私有区，不为提交笔记放宽公开清单。

**本地开发历史仍含迁出前的内部原文，不得直接整体推送开发仓库。** 公开版采用从最终审定源码快照建立全新初始历史的方案，保留原开发仓库及历史；还需审查实际上传的文件、提交作者和消息。迁出文件和检查通过不等于历史已经清理。

## 导出本地审阅快照

在项目根目录执行，输出必须是仓库之外尚不存在的新目录：

~~~sh
python3 scripts/prepare-source.py --tracked-only --output ../agentpet-lite-source-review
~~~

`--tracked-only` 只导出已跟踪文件的当前工作区内容，保留但排除未跟踪诊断测试；默认不加该选项时还会纳入允许范围内的未跟踪文件。脚本按允许清单生成 `agentpet-lite-source-review.zip`、`source-manifest.json` 和 `SHA256SUMS`；清单记录来源提交、工作区是否有修改、纳入文件摘要与排除项，不携带 Git 元数据或历史。已有输出不会覆盖，再次导出时换一个新目录。

解压后的无 Git 源码可运行 `python3 scripts/prepare-source.py --check-tree`；`verify-local.sh` 在无 `.git` 时使用该检查，构建生成目录不算源码。路径检查不代替清单摘要核对。

这只是本地审阅快照，既不上传，也不表示隐私、素材许可或历史审查已经通过。具体纳入、排除范围及干净公开历史方案见[公开范围](docs/public-scope.md)；远端建仓与发布另行执行。

## 变更与反馈

提交问题时提供应用版本、macOS 版本和架构、Agent 版本、宿主组合、复现步骤及实际／预期结果。日志与截图先移除账号、对话、令牌、个人路径及其他敏感信息；不要提交运行目录、偏好、认证文件或配置备份。

变更说明写清具体问题、最终行为和相关验证。修改 Hook 时保留非本项目处理器、共享配置、原生信任与权限流程；数据迁移需要兼容既有用户状态。

源码使用 MIT；依赖和媒体各自的许可另行适用。新增资源需同步更新[第三方说明](THIRD_PARTY_NOTICES.md)，不能把来源网站、用户提供或根 MIT 当作全部素材的授权依据。

接入 Test 的隔离协议与取消回归位于 `LocalAgentConnectionTests`；真实本机无模型握手需要显式设置 `AGENTPET_NATIVE_CONNECTION_TEST=1`。该项只覆盖临时接口，不调用真实模型或替代用户接入验收。
