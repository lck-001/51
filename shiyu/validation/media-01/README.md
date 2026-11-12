# M04 原生媒体隔离实验：source overlay

2026-11-12更新：本目录为媒体实验源稿，已有实际pub锁文件和分析配置。源稿与`.toolchains/media-probe`独立runner均完成依赖及分析，0问题；用户批准开发者模式后，使用专用CMake3.31.12和临时ASCII访问路径完成Windows原生构建，产物在`.toolchains/c/runner/Debug`，已启动实验进程。**Computer Use应用访问授权超时，首屏及真实播放/录音/录像尚未验证，Android未构建。** 普通Flutter CLI仍受VS自带旧CMake限制，不能将本次手动CMake成功写成CLI通过。临时R映射已解除。正式学习界面尚未开发。证据见planning/media-v09/results。

## 范围与行为

- 原生系统文件选择；用户取消正常返回；复制到应用支持目录。文档仅测试导入，不解析 Word/PPT/PDF。
- 用户点击列表文件后播放音视频，支持播放/暂停和拖动进度条定位。
- 用户点击开始录音才请求麦克风权限，AAC-LC/M4A 录音，停止保存并手动回放。
- 用户明确点击相机预览才创建相机控制器并请求相机/录像麦克风权限；另点开始录像才录制；停止保存并手动回放。
- 初始不访问摄像头、不录音。录像无暂停续录；Windows 插件不支持该能力。
- 拍摄、录音、播放切换经过序列化操作；切后台尝试停止录制、释放相机和暂停播放器；返回前台不自动开麦或相机。权限对话框的 inactive 不视为后台。
- 文件只在本地，列表仅本次会话存在。**没有持久化草稿索引、强制终止恢复、自动删除、后台录制或视频剪辑。** 程序崩溃/断电/强制结束时无法保证文件完整，不能宣称异常恢复已通过。

## 后续如何成为可执行实验（已完成项见首段，剩余步骤待执行）

1. 已核验Flutter 3.50.0归档大小/SHA256、实际Dart 3.14.0与Git提交；doctor识别现有VS2019 C++工具链。Android SDK仍缺，尚无Android构建证据。
2. 已生成并同步独立Windows/Android runner。Windows链接与手动原生构建已成功；本源稿目录无平台runner，不能直接构建Windows/Android。下一次构建需按M09记录重新创建并核验临时映射、刷新配置，长期环境应改为规范ASCII工作区。
3. Android runner 的 AndroidManifest.xml 声明 CAMERA、RECORD_AUDIO；不添加广泛存储权限；文件导入通过系统选择器。按 SDK 许可流程处理许可，并验证 minSdk 与插件要求（当前候选至少 24）。
4. Windows 要核验系统相机/麦克风隐私开关、驱动、MediaFoundation 和原生播放库。无设备时应显示错误而非成功。
5. 已完成依赖、runner链接及Windows手动构建；原生运行、分发义务和Android构建仍待关闭。不能据编译宣布真实媒体效果通过。
6. 按 MANUAL-CASES.md 在本机 Windows 与用户安卓真机测试；首次权限和 USB 调试授权需要用户本人操作。

媒体顶层依赖沿用精确候选；本轮依据Flutter 3.50实际SDK模板加入material_ui 1.11.0与flutter_lints 6.0.0，移除旧Material入口弃用提示并补齐检查规则。本目录98项依赖已实际解析并留锁文件，Windows runner的平台链接阶段尚未成功；未额外引入 permission_handler。media_kit_libs_video 1.0.7 的原生 libmpv/FFmpeg 许可和分发方式仍需核验，不应把 Dart 包 MIT 当作全部二进制许可。

## API 核对及未核验事项

已查官方 API 文档的接口形状：[AudioRecorder](https://pub.dev/documentation/record/latest/record/AudioRecorder-class.html) 的 start/stop/hasPermission/isEncoderSupported/onStateChanged/dispose；[Camera 开始录像](https://pub.dev/documentation/camera/latest/camera/CameraController/startVideoRecording.html) 的 enablePersistentRecording 参数；[停止录像](https://pub.dev/documentation/camera/latest/camera/CameraController/stopVideoRecording.html) 返回 XFile；[Player](https://pub.dev/documentation/media_kit/latest/media_kit/Player-class.html) 的 open/pause/playOrPause/seek/stream/dispose。文件选择与目录用法见 [file_selector](https://pub.dev/packages/file_selector)、[path_provider](https://pub.dev/packages/path_provider)。

**已核验**：精确依赖下Dart分析0问题，包括NoVideoControls、录像参数与Slider类型；Windows便携CMake原生构建通过，插件DLL与资源已产出，实验进程已启动。**仍未核验**：首屏与运行时媒体加载；camera_windows录像参数的运行实现；Android content URI复制；录音中断事件；权限错误映射；真实解码、录制与格式。`.mp4`为目标后缀，须检查实际容器，不以后缀判成功。

系统停止录音会更新状态，但本稿未接入 record 7.2 的 onStopped 文件/停止原因归档，因此被系统终止的 take 可能留在目录而未出现在会话列表。下一轮应依据 7.2 精确版 API 补齐后验证，不能假定中断文件自动可恢复。

本源稿按实验要求把流程放在一个文件方便审查；通过验证后再把媒体能力拆入独立 Adapter，不直接复制成正式业务模块。

## 独立审阅修正记录

2026-11-12，经主审提出问题后已修正源稿：

1. Video 设置 `controls: NoVideoControls`，禁用包自带的播放/手势控件，所有播放操作仅通过本稿受互斥状态控制的按钮和进度条。已核对维护者仓库 [2.0.1 版本声明](https://raw.githubusercontent.com/media-kit/media-kit/main/media_kit_video/pubspec.yaml)、[公共导出](https://raw.githubusercontent.com/media-kit/media-kit/main/media_kit_video/lib/media_kit_video.dart)及 [NoVideoControls 定义](https://raw.githubusercontent.com/media-kit/media-kit/main/media_kit_video/lib/media_kit_video_controls/src/controls/no.dart)；当前仓库声明版本 2.0.1，定义为 null。尚未与下载的发布归档或分析器核对。
2. 录制状态在原生停止成功后才置空；原生停止抛错时保留状态，以便重试。停止已成功但保存文件失败时维持非录制状态，不再假装设备仍在录制。
3. 操作锁改为 pending 计数，生命周期清理排队时，前一个操作的 finally 不会提前解锁。窗口关闭后跳过的排队操作也经 finally 递减。

上述三项最初属于静态审查修正；M09已实际完成依赖解析、Dart分析0问题及Windows手动原生编译。设备媒体验证仍未执行，不能作为播放/录制通过证据。
