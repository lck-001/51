# 拾语 Shiyu

把用户自己选择的材料变成英语听说练习。材料默认私有，不出售课程或学习包；目标覆盖 Android、iPhone、Windows、macOS。

当前处于技术预验证阶段：最新静态原型 v0.13 含 37 张手机与 4 张桌面画布；Windows 本机基础媒体闭环已验证；Android 0.0.2 测试包已构建并检查签名、版本及最终权限，实机验证尚未完成。完整学习界面、生产后台及专业发音评测仍未实现。静态示例分数不是测评结果，转写文本相似度不能充当发音准确率。

## 目录

| 路径 | 内容 |
| --- | --- |
| `prototypes-v13/` | 当前原型、编辑/生成源码、单屏 HTML、示例屏幕图 |
| `validation/media-01/` | 可解析/分析的 Flutter 媒体实验及 Android、Windows runner 源码 |
| `validation/local-01/` | Python 标准库合成契约参考模型与回归测试 |
| `planning/` | 产品需求、架构/Agent/反馈方案及公开工具链元数据、实验工具源码 |
| `GLOSSARY.md` | 领域术语与状态边界 |

只纳管可公开源码。真实素材、个人工作日报示例、原始助手记录、私有文档链接、设备映射、构建日志、SDK、签名密钥与安装包均不进入 Git。原始私有资料在本机及授权文档空间保留。

## 查看原型

直接打开 `prototypes-v13/index.html`，或在本目录执行：

```console
python -m http.server 8765 --bind 127.0.0.1
```

然后打开 `http://127.0.0.1:8765/prototypes-v13/index.html`。画布内数据、价格及连接状态为示例。重新生成当前画布：

```console
python prototypes-v13/build_design.py
```

## 本地契约检查

```console
python validation/local-01/run_checks.py
```

该模型使用合成身份、字典和内存锁，不能替代真实认证、PostgreSQL 事务、费用对账、容灾或设备验收。

## Flutter 媒体实验

采用 Flutter 3.50.0 / Dart 3.14.0，依赖版本见 `pubspec.lock`。建议在不含非 ASCII 字符的短路径检出；部分 Windows 原生着色器工具及旧 MSBuild 对路径存在限制。

```console
cd validation/media-01
flutter pub get
flutter analyze --no-pub
```

Windows 需要符合依赖要求的 C++ 工具链和 CMake（录音插件要求至少 3.23）；Android 需要兼容 JDK/SDK/NDK，工具版本见 `planning/media-v10/android-toolchain-metadata-v0.10.json`。Android SDK 使用前需由使用者接受 Google 许可。项目不自动修改全局 PATH、安装系统组件或接受许可证。

```console
flutter build windows --debug --no-pub
flutter build apk --debug --no-pub
```

操作摄像头/麦克风须由用户主动触发。当前是临时实验，文件列表不具备完整持久化；不要用它保存重要原件。生成原创合成测试素材：

```console
python make_fixtures.py
```

实验的统一后台暂停策略尚不能用于正式离屏听音。后台/锁屏、音频焦点、蓝牙、中断、低存储、其他设备及专业评测分别验收。

## 工程流程

专家讨论 → 产品评审 → 需求立项/评审 → 各端方案与开发 → 人工验收 → 灰度 → 正式上线 → 反馈迭代。构建成功不等于实机通过，局部技术测试不等于整套产品验收。

`planning/media-*` 的脚本保留受控实验方法，不是默认安装入口；执行前先检查参数、目录、资源及显式授权开关。个人机器的授权不能随源码继承给其他使用者。

## 第三方依赖

保留 Flutter/Gradle 模板自身版权声明。依赖由其各自许可证约束；Dart 包的许可不能代表 libmpv/FFmpeg 等全部原生构件。正式分发前须完成原生依赖来源、维护版本、许可与通知文件复核。本仓库不附带 SDK 或第三方原生二进制安装包。
