# M13 播放模块策略验证

2026-11-13。纯Dart实现与独立外部Interface回归完成；原生验收另列，不能把本项计数扩大为设备能力。

在 `packages/playback_core` 运行 `dart run test/interface_regression.dart`：独立QA、实现者与主负责人分别执行，最终 **52 passed / 0 failed**，Dart分析无问题。无外部测试依赖；以可控Adapter、延迟回执与明确断言穿过公开Interface，不读取实现私有字段。

已覆盖：accepted与actual分离；Open默认暂停；账号/素材版本/代际；用户暂停与焦点恢复双顺序；独立多hold及原token归账；复用holdId不被旧gain清除；永久失焦/路由断开；capture/preview unknown与新Play门闩；晚到初始化补偿请求；hostReady独立事实、前台自举和宿主丢失；旧Open/Play异常隔离与同session暂停补偿；全局native unknown按单调序号阻断但不伪报已停；Stop恢复；Seek串行末次合并、位置与画面确认分开、超时；冷启默认暂停；快照不可变。

通过不证明：真实SDK已停麦/停相机、音频可听、FGS/锁屏、耳机/通话或画面到位。captureCleanupRequests只证明发出了清理请求。原生实验在 `validation/playback-01`，SDK、音频、安装包和原始运行日志留本机。

不是完整产品验收、灰度或上线批准；原生分支需以合并权限、真实系统状态及运行回归收口，失败继续修复。
