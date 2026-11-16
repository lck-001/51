# M15 Windows 后台原生回归

2026-11-16。独立隐藏、静音的验证进程，未激活或操作用户主界面，也未触碰既有UI/录制进程。真实Core、media_kit与own HWND SMTC，无fake Adapter。

实际构建：Flutter3.50/Dart3.14、MSVC2019/WindowsSDK19041、专用CMake3.31。独立bundle与运行JSON均留本机，不上传安装包或原始音频。

## 本轮真实通过

- 隐藏入口显式抑制first-frame Show及两处SetFocus；每个原生检查的windowVisible、windowFocused与nativeForeground均false。
- 原始合成WAV Open后实际暂停、时长可读，不自动播放。
- 静音Play后真实引擎位置推进，原生SMTC为playing，通用标题/作者及空album/mediaId/thumbnail核验通过。
- Pause后真实暂停；controlled lifecycle往返不自动复播。
- Seek到5秒由真实引擎位置确认；不据此宣称视频画面或声音已经对齐。
- 明确重播后Stop，原生SMTC为stopped且禁用，元数据全部清空；退休后的background Play拒绝。
- 等待native Stop与固定版本6秒timer drain后退休宿主；cleanupConfirmed=true，own进程已自行退出，无ownerCleanupRequired。

收据schema：shiyu.windows.background-regression.v1，passed=true；desktopInputOrActivationRequested=false，controlledLifecycleOnly=true，realLockScreenVerified=false。

## 修复与边界

首轮构建与最终Dart诊断字段不同步，状态枚举未正确核对；冻结源码重编后分开处理原生数值与受限字符串。随后严格退休校验发现只调用DisplayUpdater.ClearAll不足以清空typed property读回值；已显式恢复Music类型并逐项清空title/artist/album/mediaId/thumbnail，再Update，严格同一原生查询通过。失败收据保留本机，没有改测试吞错误。

生命周期为测试输入，不是Windows实际最小化/锁屏/睡眠；未注入全局媒体键、未采集真人、未实听音质。不是四端、专业声学或完整学习产品验收。真正主界面/锁屏/可听测试待用户明确参与，不阻塞后台材料与服务端研发。

复跑：单独构建 `validation/playback-01/lib/background_regression.dart`，运行带 `--background-regression --silent-validation --synthetic-fixture=<original-WAV> --report=<private.local.json>` 的专用bundle。不得将隐藏回归入口覆盖或启动为用户当前UI程序。
