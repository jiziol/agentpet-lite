# Default deepseek酱 animation pack

来源与作者：[PC2005-cloud/dsh-pet](https://github.com/PC2005-cloud/dsh-pet)。

本包仅包含已筛选的33段MOV、对应海报、九组用途清单和来源／许可；不包含用户经验、等级、养成记录、名称覆盖、动画偏好、认证或会话数据。除下述用户提供的拖拽视频／海报及探边图外，32段视频保持所取上游压缩包原字节，海报由对应视频派生；静态回退直接使用悠闲哼歌海报，使用single布局以保留分离的发饰等部件，不分割为精灵网格。未包含来源待核的旧spritesheet.webp。

上游素材仅限非商业使用。介绍、展示与分发衍生作品时保留原项目地址。另行提供的三份素材已由提供者于 2026-11-12 声明为 AI 生成，允许随公开源码和 DMG 分发；其来源与授权分开记录，不归为上游 Release 原件。完整上游素材条件见LICENSE-ASSETS.md；LICENSE-CODE.txt仅记录上游代码MIT许可。

九组数量：idle 9、working 4、waiting 4、success 5、failure 2、quota 2、levelup 3、tap 3、drag 1。第一次触发时的默认绑定按purposes派生，用户选择保存在运行数据域内，不写回本包。

拖拽组的 `被鼠标拖拽悬空反馈` 继续使用同一用途/id/文件名，媒体已由用户提供的 `deepseek-drag.mov`（HEVC alpha、640×360、24fps、10 秒、无音、末 0.5 秒定格）及对应透明海报替换；播放仍按原速和末态，应用侧单次播放并在持续拖动时保持末帧。该文件不是上游 dsh-pet 素材，来源与摘要见 SOURCE.json 的 userProvidedMedia。

`edge-peek.png` 为可选贴边探头静图，同样是用户为本项目提供的素材：运行时只读取包内文件，不依赖 Downloads；加载时按非透明内容裁边，左贴边镜像。缺少、解码失败或没有有效内容时，应用不启用贴边收起，宠物保持正常可见。

SOURCE.json记录固定README、MOV Release和原压缩包摘要；SHA256SUMS.json记录本包文件摘要。新增动画格式见项目docs/pet-animation-packs.md。

Factory preset: the display name is deepseek酱. The nine purposes and within-group order use the selected 33 native clips. New users start at Lv 0. No XP, care, runtime preference files, custom name overrides, accounts or sessions are bundled. Existing users keep their packs, preferences and care state.
