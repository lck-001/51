# C-stdio：有界MCP调度、八工具及输出故障收尾

2026-11-23。本片只接MCP stdio，不包含代码流式SDK。B的Controller／Client／Core、App UI和依赖未改；C整体仍须SDK另行完成。

## 已冻结合同

- 原三个工具加五个媒体工具，复用A/B严格decoder与真实Client。工具可发现不等于授权；默认媒体scope关闭，v1的media:null等原保护保留。
- 普通工具与media_abort各一槽，持槽到响应flush；reader的metadata／拒绝响应也await同一个writer。writer容量3包含active，没有无界then链或旁路输出。
- 已读取且获准的同stdin abort不等普通submit返回；背压下尚未读取的请求不保证受理。取消通知不冒充已鉴权media_abort。
- 原始JSON／UTF8／重复键／孤立surrogate坏帧按已评审策略结束session，后续帧不执行；有效RPC的工具参数或权限错误正常返回isError，session可继续。旧坏帧后ping策略有意调整，不声称旧关闭语义未变。
- EOF／fatal／坏stdout先停止接纳，等待已受理Client Futures settle后关闭Client。Client结果可为unknown，代理退出不等于另一进程Store终态或撤回；App端真实Store drain仍由B负责。
- writer watchdog为15秒。超时settle逻辑completion，原flush只观察，不在finally继续await已坏flush、借用sink.close或done；必要runner在Client收尾后明确失败退出。

## Windows真实背压缺陷及修复

初版受控never-flush测试通过，但真实OS管道测试25秒超时。SDK源码及独立最小实验确认：Windows默认Stdout使用同步writeFromSync，满管道时isolate卡在add，Dart计时器也无法运行。

独立三对照：默认stdout不读取时卡在第一次add前，7秒上限回收确切任务VM；nonBlocking同样不读取时约3.1秒有限退出、flush超时为true；默认stdout被实际读取时8次flush／512KiB正常完成。随后runner及真实Stdout输出均使用nonBlocking，自定义IOSink须遵守非同步阻塞契约。

产品级OS用例另行真实验证：父进程从未订阅child stdout，200次tools/list实际填满管道；15秒watchdog后child失败退出，App真实Store仍pending，之后父进程显式release由B真drain。它不是最小实验或fake sink的替代证明。

## 实际执行与独立结果

| 验证 | 实际结果 |
| --- | --- |
| 作者新stdio行为脚本 | 13组PASS，退出0；另5行任务PID诊断不计测试 |
| 作者既有兼容 | MCP8/8、bridge6/6、整包分析均退出0 |
| 独立架构 | 六文件SHA匹配固定版本，源码复核无剩余P1；该角色未执行Dart |
| 独立真实子进程链路 | 11/11，退出0，约50.5秒；任务marker与真实VM PID逐项一致 |
| 独立writer／收尾 | 6/6，退出0，约28.3秒；模拟回调与真实计时分开记录 |
| 独立真实OS pipe | 1项PASS，测试退出0，预期故障child退出1；父进程未订阅stdout，非mini替代 |
| 完整Probe静态集成 | 无问题，退出0，18.1秒；未运行原生窗口或音频 |

独立行为QA已按上述范围有限准出，无跳过、cleanup kill为0。最终子进程与writer前后六文件SHA一致；真实OS pipe使用先前同一冻结SHA的实际已过结果，未重复等待或把不同版本拼成终验。

独立QA早期私有fixture路径过长、stdin未串行flush及错误封套字符串期望不符，均保留失败日志，只修测试支架，未修改产品源码／Store效果断言。最终工具错误按exact error对象code、isError与text镜像精确验证，不以任意异常求绿。

作者真实子进程验证五动作从stdio到B/C1/真实FileStores、同stdin submit在实际Material已提交但回执暂停时abort先到Module，release后Learning为0、原ref保留；输出和回执仅固定小字段。另验metadata与busy、默认scope、cancelled通知无副作用、8192帧与4096 ID边界、EOF／raw fatal／broken output下Client收尾及writer容量。

## 保留失败与有意测试更新

原MCP首跑6/8的两条失败为已评审的工具数量和raw坏帧关闭策略变化。工具数量改为恰8且保留原3名字／字段／权限；三个坏帧按独立session保留拒绝断言，新增后续帧不执行。另一bridge测试只改3→8数量断言，其余保留。

初期pause输出订阅不可靠地代表OS背压；第二轮真实不读取配默认同步stdout仍超时，cleanup的同步StreamSink错误又遮住原超时。失败记录保留，cleanup改为捕获同步错误保首错，默认输出改nonBlocking后重跑产品用例。任务child直启dartvm并记录marker／真实PID；仅回收自身Process，未操作用户程序。

## 范围

纯本机合成数据、私有临时目录和测试ACL，没有云／账号／TTS、实际朗读、四端人验或上线结论。代码SDK尚未实现；不能把已有chunk工具当流式SDK完成。后续SDK的channel所有权、无响应超时、两遍source及sticky取消需独立冻结和验收，C3再接界面及实际播放。
