# M19-B1 本机桥接与stdio代理验证

2026-11-18。本文只记录受控本机发送端，不把手写JSON／测试进程改名为真实Codex、WorkBuddy或百度搭子接入。未修改真实MCP配置、reload客户端、复用模型／CLI／TTS账号、启动可见App窗口或操作主界面。

## 已实跑的模块与生命周期证据

| 范围 | 实际结果与边界 |
| --- | --- |
| 实现方Root／privacy | 12项native标量检查通过；新私有descriptor真实WinAPI ACL读写，broad目录拒绝且不写secret，同进程冲突不丢原锁、第二进程竞争、释放后重取及真VM终止后OS释放 |
| 独立Root QA | 4/4通过；仅使用自造Root和新holder，校验实际VM PID后终止，不访问旧程序 |
| 实现方本机帧／Store | 19项标量检查通过；真实loopback proof、receive-only拒原文、实际候选持久幂等、同delivery换内容冲突、media:null拒、独立原文scope、cap轮换integration稳定、本人路径确认external partial、撤销与真实inflight drain |
| 独立协议QA | 6/6通过；原始服务器scope／owner伪造／confirm／media拒绝，绑定和cap轮换、未知提交与revoke drain、实际stdio到Core、真实旧port复用fake listener坏proof拒绝且无cap／正文发出，以及实际bytes／重复key／非HTTP拒绝 |
| App静态／关闭 | 整probe分析无问题；11/11回归通过，包含真实两Store关闭后才释放Root锁、最终释放故障重试不重复关闭Store |

Controller收件成功只更新真实候选ID／状态通知；不会创建学习版或切换正在学习的材料。本人确认单独经同实例Store完成。传输摘要来自实际业务bytes，不含cap；原文／声明／可信提交上下文保持分层。

## 独立exe与普通上下文边界

纯Dart Windows stdio代理已编译为独立exe，6719488字节，SHA256：

`2d1490d4ba99423117c9e5181ae83d97c5d2884de78e278364bd0a642ebc4142`

使用canonical C路径，进程参数不含SDK、Python、URL、私有文件定位或secret；环境仅带descriptor定位。普通受限工具上下文的R不可见，仍实际完成initialize和三个受限tools.list，证明exe启动不依赖R／SDK。随后数据调用被OS拒绝读取拥有者私有descriptor，返回稳定`privateStorageUnavailable`；直接stat也得到WinError5。**这条普通受限上下文的数据链没有通过**，没有为演示放宽ACL。

在与受控App authority相同的OS拥有者上下文，另一个独立exe进程实际stdio完成19项检查：引用读取、receive-only原文拒绝、真实中性`delivered`收件回执、相同ID幂等重放、media:null明确拒绝、stdout纯协议／stderr空／退出0。exe退出后App authority和Store仍运行；随后所有者测试路径读取真实唯一候选，确认成external `partial`，重复确认仍唯一1个学习版、无媒体、provider未知。没有模型调用。

真实桌面助手MCP server进程的启动权限／配置与当前受限exec工具并不等价，需最后用可审App／exe／授权目标及配置由本人完成实际工具验证；现在不写“真实Codex已连通”。App高级setup导出canonical路径，不使用只在构建上下文可见的R映射。

## 保留的失败与修正

- 初版WinAPI getter存在空类型编译错误，已修正并对聚合实现整体分析；不把编译失败算行为红，也不靠UI窄import隐藏App实现错误。
- 早期crash fixture用dart.exe launcher，不能证明杀到实际VM；已改sibling dartvm.exe并核自报PID等于Process.pid后才终止。此前launcher结果仅算受控关闭，不作hard-kill证据；独立Root／旧port测试也用真实VM重跑。
- Controller回执先改delivered但stdio白名单仍pending_review，真实整链抓出不匹配；两作者同步中性合同，旧exe不分发，重新编译后实际链通过。receive-only不读取本人当前处理状态来补字段。
- fixture所有者进程的首次非交互stdin立即EOF并正常结束，未当服务已长期运行；改工具内部PTY保持自己的stdin后完成独立进程验证，没有打开主机窗口。

上述模块与独立代理测试的临时authority／descriptor／Store已清理，自建进程退出；后续整App失败目录另按下节保留，不能混为清理成功。未触碰既有Windows录制进程。原始cap文件、配置定位、stdin/输出、私有计划和执行回执仅在私有目录，未入Git。

## 整App后台验证的失败门槛

普通客户端与独立debug demo均已后台构建成功。debug demo仅创建原创中文材料、受控原文读取授权，等待当前会话实际工具送入；入口不创建或确认学习候选。构建成功不等于运行通过。

首轮在隐藏／焦点合并检查失败，未形成ready、未送入候选、未请求播放。新增逐次白名单native诊断后，以新控制ID重跑：打开Owner时181ms为不可见／无焦点，实际App渲染后752ms仍不可见但`windowFocused`和`nativeForeground`均为true；检查立即失败，清理阶段777ms仍报告true。这是阳性观察，不能以稍后不可见或无焦点推翻，也不采用等待重试消除历史。

两轮均未确认学习版，Root锁已释放，进程内完整清理未确认。仅在核对完整可执行路径、静音参数、控制ID与拥有者标记后回收各自测试进程；保留失败目录及独立外部回收记录，不将外部终止写为进程内清理成功。没有再启动同一可疑版本。

根因由当前Flutter SDK和同引擎版本源码核对：Navigator初始路由获逻辑焦点，经View请求原生焦点，引擎直接SetFocus到子窗，可激活父窗，绕过runner的创建阶段焦点门闩。无窗口回归以普通MaterialApp作阳性对照，原debug边界实际捕获focused事件而红；仅debug根增加ExcludeFocus后2/2绿，正常页面对照仍请求焦点。普通App／C++未改，三个原生阳性与未知检查全部保留，未采用事后隐藏或转移焦点。

## 当前会话经命令工具的真实业务送入

独立源码评审和重建后，以新控制ID运行真实原生App：入口只创建原创中文固定原稿并授予受控读取许可，候选不由入口seed。当前会话经命令工具启动标准stdio MCP客户端，先完成initialize／initialized，再实际调用source reference与fixed source工具，核对返回原文UTF8摘要，现场整理三句自然口语英语及中文对照，经submit工具取得`delivered`。

随后App从同一真实Store回读唯一候选，候选ID及三句正文与回执／本会话输入匹配，状态pendingReview；学习版数量0。真实RepaintBoundary截图显示“待你校对 · 1份”、“3句”计数及外部助手来源，学习列表为空；三句正文一致由Store回读证明，截图没有展开正文。没有确认、自动选择、播放、云端生成或发音评分。

本次owner-open218ms、rendered813ms、candidate-sample63027ms、cleanup83225ms四次原生检查均为不可见／无焦点／非前台。最后Stop实际idle、bridge及Store drain、Root锁释放、native退休、临时Root标记核验后删除；result passed／cleanupConfirmed均true、ownerCleanupRequired=false，自己的测试进程自行退出。该成功仅证明本次观测与控制路径，不消除前两轮失败证据，不宣称从未存在其他未采样事件。

这是**当前Codex会话→命令工具→标准stdio MCP客户端→真实App候选箱**的实际业务路径，不是桌面客户端原生MCP注册／热加载或官方品牌认证。原文由原创demo创建，不是同次SAF导入；未走本次UI校对确认或双进程冷启，不能拼称完整用户端到端验收。分层证据按PM准入收口，下一小包补导入→真实桥接→UI确认→Store重开组合回归，不为本轮新增大型native控制协议。用户暂不开通Azure的决定保持有效。

## 尚未证明

原生整App已构建，本次受控窗口及当前会话命令路径已实际通过；原生客户端MCP注册、完整导入组合、本人产品验收及灰度／上线仍分别待验。现有证据不证明模型／语言质量／版权身份、音频／专业发音评测或Apple端。默认授权仍关闭，原文读取单独授权；本地cap不是OAuth／官方品牌认证。
