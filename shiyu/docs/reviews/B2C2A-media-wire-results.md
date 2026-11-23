# C2-A：严格媒体消息、授权文件兼容及执行确定性

2026-11-23。本片只增加纯 v2 消息 DTO／解码器、编码预算、descriptor兼容和C1窄接口；不改变 Controller／Client 调度、连接额度、stdio 并发、工具列表或 SDK。当前仍只有原三个工具，不代表媒体协议已端到端接通。

## 合同

- v2 begin／chunk／seal／submit／abort 各层严格字段、整数类型、Unicode、canonical base64、实际块摘要及声明映射。完整submit从实际输入实算语义hash，不增加可冒充真相的正文hash字段；v1 decoder仍拒绝media及null。
- descriptor支持严格1／2；v1媒体为false，v2必须显式布尔字段，默认写入仍为schema1。工具可发现性和实际授权是后续B/C的独立边界。
- C1实例核验只返回对象身份判断，不暴露Store／路径。caller context从可信代码提供的业务raw bytes计算摘要，不由正文反序列化；缺省仍为controlledTest。工厂本身不完成proof／cap认证，真实Controller接线属B片。
- 每个公开动作有独立执行上下文，持久create/write/flush/rename/delete、注册及接收尝试前做标记。发生尝试后的异常保守为unknown；lifecycle子操作的unknown不得变回notAttempted，不按异常字符串猜可重试。
- inner业务JSON空白／字段顺序变动可保持语义hash而改变raw hash；只改outer request JSON不会改变base64解出的业务raw。两种摘要不混用，重放不覆盖首次审计。

## 实际编码向量

以下是作者脚本指定参数的真实Dart编码统计，不是通用固定开销；VECTOR输出不计测试组数。产品上限仍为business196608B、request JSON262144B，帧头另12B，MCP封套和LF另核。

| 指定向量 | raw | business JSON | request JSON | 含12B帧头 | MCP JSON+LF |
| --- | ---: | ---: | ---: | ---: | ---: |
| 64KiB零块、index31 | 65536 | 87756 | 117269 | 117281 | 87869 |
| outer临界-1的business | — | 196409 | 262142 | 262154 | — |
| outer临界的business | — | 196410 | 262142 | 262154 | — |
| outer临界+1的business | — | 196411 | 262146 | 262158 | — |

最后一行被产品request限额拒绝。测试仅为测量使用有界512KiB编码器观察被拒大小，没有扩大产品限制或发送该请求。base64取整使前两临界request长度相同。

## 验证记录

| 验证方／范围 | 实际结果 |
| --- | --- |
| 作者新消息／确定性脚本 | 11组PASS、4行VECTOR，退出0 |
| 作者C1回归 | 17组通过，真实Store／文件断言保留并加强typed错误断言 |
| 作者既有兼容 | bridge6/6；MCP在正确package工作目录8/8；整包分析退出0 |
| 独立架构 | 七个冻结文件SHA核对一致，源码复核无剩余阻断P1；本角色未执行Dart |
| 独立新版消息用例 | 6/6，退出0 |
| 独立C1类型化回归／原故障 | 17/17、4/4，均退出0，故障无跳过；原文件／Store事实断言保留 |
| 独立旧代理兼容 | 原冻结代理SHA核对一致；同路径／ACL的v1可读、v2明确拒绝，子进程退出0且本地连接数0 |
| 独立有效submit编码边界 | 三个边界向量通过，无网络发送 |
| 完整Probe静态集成 | 无问题，退出0，17.5秒；未运行原生窗口或播放 |

独立QA已按上述范围有限准出；七个冻结文件在各轮测试前后SHA均一致。有效完整submit的196409／196410B business均得到262142B request，196411B得到262146B并被产品tooLarge拒绝，与独立通用编码向量分开核验。

冻结SHA对应Windows工作区实际字节。暂存核对七文件无内容变化，三个文件仅由Git作CRLF→LF规范化；公开源码清单记录实际Git blob的SHA，不将两种字节表示混为同一摘要。

传输审计通过真实Store的可信测试工厂直接调用验证：语义相同而inner raw不同、首次submission审计不被重放覆盖、缺省仍controlledTest。该工厂不等于proof认证，本片不据此称真实媒体socket链路已通过。

## 失败及范围

作者首次从仓库根运行旧MCP脚本，子进程相对路径错误产生7/8失败；在原package工作目录、原断言和原源码下重跑8/8，保留首轮记录，不改测试求绿。独立typed C1测试首轮将“同业务不同正文”的期望写成invalidRequest，与已冻结deliveryConflict合同不符；仅精确适配错误code，保留once为0及原sealed最终可正常提交等事实断言。

本片未接真实媒体proof socket、Controller取消通道、同stdin并发、八工具或流式SDK；未改变Core／Schema／依赖／UI，无音频播放、发音评测或四端结论。后续B/C须分别实施、独立验收；数据面由代码搬运，不让模型生成大段Base64。
