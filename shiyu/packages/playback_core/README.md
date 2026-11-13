# Playback Module

纯Dart策略模块，负责播放意图、实际观察、暂停原因、会话归属与资源恢复资格。它不读取文件、不申请设备权限，也不声称音频已经可听。

调用者只使用 `Playback.current`、`snapshots` 与 `dispatch`。Open默认加载后暂停；命令accepted只代表受理。引擎与系统Adapter从各自Seam注入，真实实现由应用持有，页面退出仅退订。

- 素材、版本、账号及代际隔离；旧回调不能覆盖新会话。
- 多个中断hold独立，清理归属按原token；用户暂停会撤销旧恢复资格。
- 音频后台必须同时具备能力与真实hostReady；视频后台暂停。
- 采集与预览非closed时阻断Play；closed不自动解除新Play门闩。清理请求不等于硬件关闭。
- Seek目标、实际位置与画面确认分开，命令受理不伪报定位完成；只保留最后等待定位。
- 全局EngineAvailability是单实例物理管线事实，按单调序号处理，不将旧操作的异常假冒成新素材错误；unknown不伪报暂停，confirmed恢复后仍须新Play。

```console
dart run test/interface_regression.dart
dart analyze
```

回归从公开Interface使用可控Adapter与延迟回执；当前结果以执行输出为准。这些检查不证明真实SDK、FGS、锁屏、采集释放或真人发音。真实适配实验在 `validation/playback-01`，与旧媒体实验分开。
