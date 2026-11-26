# Windows普通界面验收启动门与失败资源保留

原隐藏显示参数不足以覆盖engine/helper的焦点行为，普通入口又固定读取已有资料域。本次为后台真实UI验收增加Debug限定启动门：严格验证参数、非输入Desktop、物理私有父域及fresh profile后，才进入原有COM/engine/MediaKit与真实AppOwner；保留同一client_main、Host、Frame和业务Shell。普通无验证意图的构建继续走既有入口，验证专用构建漏参/错参直接拒绝，不回落旧profile。

两层startup工厂及部分Host未返回时，以同attempt保留原资源/Future、首错与cleanup状态。沿原G1和RootLock._held，不新增Store、锁或第二authority。standalone Storage只有确认全部清理结束、无pending/cleanup失败时恢复原异常和stack；显式上层token及Unknown仍保留载体。

Debug只读frame/status与实际Owner-close接口为闭集；close资格来自受控parent实际reader终态，不接受observerDone自报。首次材料为空，未自动grant/confirm/play。既有SMTC构造与后续Bind/WinRT激活分别记录，没有假Host、词典或评分服务替代真实能力。

## 已完成的限定检查

- 原生纯policy/parser：精确源码、合成向量、仅KERNEL32导入检查后，隐藏单元程序67项通过；未运行Win32 adapter/普通App。
- Dart冻结域62项作者回归及独立source/headless复核；后续standalone兼容修复的原用例与新反例单独复核通过。
- Root最终合并旧74及新测试：110/110、exit0，30份输入源码前后SHA一致。此前107通过/1失败原日志保留，未修改旧异常/清理/rename/marker断言换绿。
- 真实Shell/Frame在headless中保持实际几何、原Owner退出Future、Store关闭和A释放断言；平台channel为mock，未初始化真实Player/SMTC。

生成C++测试头仅含公开合成wire数据，与冻结编译输入逐字节相同。依赖及锁文件未升级，SDK/缓存/运行日志/媒体/真实资料未纳入源码交付。

## 仍需后续验收

本记录不是普通Windows界面或完整产品通过声明。完整App构建、fresh空库实际首帧/顶部band、真实安全退出及后续业务/冷启/Android受改动回归仍待各自准入。独立Desktop dummy机制已有实际取证，但不能外推普通App或所有共享helper；采样不能证明间隙绝无瞬态。没有调用SAPI/云、录播/Play、系统picker、用户主桌面或发布。

英文生成/真实朗读与专业发音评分仍另有资源/实现门；fixture或零PCM不代表这些能力。当前仅准备可追溯源码与后续build-only，未合并主分支、灰度或上线。
