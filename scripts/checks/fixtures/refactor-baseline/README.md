# R0 状态回放基线

更新：R1.1/R1.2/R1.3 已修复 socket、Hook 和损坏历史保护；当前可用 `bash scripts/test-refactor-baseline.sh --regression` 执行三项严格回归。无参数的历史 baseline 模式仍要求三项缺陷全部存在，因此在当前源码上会失败，不能作为当前正常检查入口。

`session-events.json` 是人工编写的行为契约，schema 为 1。所有 ID、时间、路径均为合成值；Codex 原生 JSON 只保留消息类型、调用/问题索引及 accepted 标记，不包含真实问题、选项、答案、命令或凭据。原始诊断材料和私有快照不放在此目录。

14 个固定场景覆盖：

- Codex / Antigravity / opencode：工作蓝、运行点击仍蓝且保留阅读回执、新活动蓝、完成红、完成点击绿、未读不因超时消失、重启、已读过期清理。
- Claude / Codex / Antigravity / opencode / Pi：并行请求、点击仍等待、新请求橙、迟到点击与答复、全部处理后工作蓝、重启。
- Codex：异步 accepted 不算答复；正常执行结束保留未答卡片；新轮替换旧卡片；旧轮结束不能覆盖新任务；取消清理待办。
- opencode：断开保留未读未知结果；权限与回复请求按身份分别处理。
- 相同工作目录的两个会话保持独立。

`refactor_replay.swift` 在临时目录使用 Core 的公开接口按记录顺序回放，断开检查注入进程不存在的结果，不读取真实数据库或操作客户端。`open` 表示导航成功回调，仅检查回执保护；它不验证真实窗口/会话是否跳转。`restart` 读取当前 v1 持久化文件。UI 消失时机、真实请求检测、安装与性能仍需专项验收，不能由这些场景替代。

`codex-native-metadata.jsonl` 则来自 R0 当时已观察的真实 Codex 记录。仅保留 95 条生命周期与人工介入元数据：38 个轮次、8 个调用使用稳定别名；时间整体平移，保持顺序及间隔；问题索引和 options 的数量关系保留，问题、选项、答案及错误正文均移除。固定回放结果为 asked 9、resolved/retired 8、待办 0；取消/新轮替换也会关闭请求，因此这些数值不能解释为用户作答次数。提取脚本与来源散列只留在交接证据。入口会以当前源码检测该样本，不读取原始会话文件。

执行：

```sh
bash scripts/test-refactor-baseline.sh
```

该入口先验证状态契约，再通过 `reliability_baseline.swift --baseline` 确认审查中的三项缺陷仍可隔离复现。**baseline 退出 0 仅表示已知失败与记录一致，不表示缺陷修复或发布回归通过。** 所有 socket、Hook 配置及损坏历史使用临时合成数据。

R1 修复各项之后使用对应的严格模式：

```sh
bash scripts/test-refactor-baseline.sh --regression socket
bash scripts/test-refactor-baseline.sh --regression hooks
bash scripts/test-refactor-baseline.sh --regression history
# 三项全部修复后：
bash scripts/test-refactor-baseline.sh --regression
```

严格模式要求目标行为成立。早期 R0 曾退出 1 的说明属于缺陷修复前的历史；当前结果须按本次执行日志判断。若未来数据模型、事件接口或历史写入的返回值变化，应审查回放器及历史探针的接入方式，保持用户契约；不要修改预期来掩盖行为回退。R1.1 的超限、并发、停止与审批往返测试仍需补充，这三个探针不是完整 socket/安装/历史测试集。
