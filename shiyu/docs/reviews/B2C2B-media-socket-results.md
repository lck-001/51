# C2-B：真实本机媒体 socket 与 Client 接入

2026-11-23。本片接通 Controller／Client 的五个媒体动作，继续使用同连接 proof、固定来源授权及C1私有暂存。未改 stdio调度、工具列表（仍原3个）、流式SDK、App UI、Player、Core、依赖或Schema。B通过不代表媒体MCP已可用。

## 行为与资源边界

- Controller可选借用已绑定的MediaIngest；Material／Learning／RootLock须为同一可信装配实例。没有模块、错配或关闭状态时，媒体授权在创建listener／descriptor前拒绝。媒体默认关闭，与原文读取权限独立。
- 新授权明确写descriptor2及required媒体布尔值。新版Client继续读v1为媒体false；旧冻结代理对v2拒绝属于已声明升级边界，不声称旧二进制无感兼容。
- 每grant只有一个C1 lease，lifetime与64次请求额度分离。已受理第64次可完成，第65次拒绝不使在途lease失效；wire abort没有免额特权，可信内部revoke仍可封门。
- 普通持久操作一槽，只有完整auth／binding／scope／quota校验后的abort可进独立控制槽，同步调用真实module后tracked drain。仍最多两连接；未被受理的第三连接不能声称取消生效。
- revoke／expiry／close同步封lifetime并retire唯一lease。descriptor或其他清理分支失败也等完所有已受理普通、控制和retirement Future，再报告首个中性错误。Controller不关闭借用module／Store，装配owner按顺序关闭它们后才释放RootLock。
- Client入口先制作有界稳定快照，完整预编码后才在实际socket写入前设置businessStarted。全部五mutation发出后断连、超时、非法ACK或未知错误均保守为outcomeUnknown，不自动重试、新key或续授权。
- 实际传输审计来自Controller解码出的inner业务raw bytes。媒体submit的ACK摘要必须匹配稳定输入实算的语义hash；candidateId首次未知只检查格式，不捏造可验证的ID绑定。

## 固定源码与验证

最终Client SHA：`800b8c2460ac39478724cdb48193b8811f081552363c8ac43ea8de8e8b13327b`；Controller SHA：`b6f108cd9239f1050a9668f1c78378779aa03603c963d47c571d056c1520a02d`。独立测试前后五个冻结文件均保持一致。

以上SHA为实际验收工作区字节；Git行结束符规范化与实际blob摘要由公开源码清单另行记录，不混作相同字节表示。

| 验证范围 | 实际结果 |
| --- | --- |
| 作者真实socket／proof peer脚本 | 最终28组PASS，退出0；内部多动作循环不冒充额外组数 |
| 作者兼容 | 原bridge6/6、原MCP8/8、整包分析均退出0 |
| 独立真实Controller／FileStore | 12/12，退出0 |
| 独立隔离TCP peer | 8/8，含六模式×五mutation的30子案例，退出0 |
| 独立错误合法摘要ACK负例 | 1/1，退出0，旧版红与修复版绿分开保留 |
| 独立架构 | 固定SHA及最小修复源码复核无剩余P1；未自行运行Dart |
| 修复后完整Probe静态集成 | 无问题，退出0，8.8秒；无原生运行或播放 |

独立真实Store用例验证五动作、重放、私有授权默认关闭、错误cap／source不停止原上传、实际Material提交后暂停回执下合法abort、实际Learning已提交后的取消不回滚、64th submit与65th abort，以及普通与控制同时在途时descriptor清理失败仍真实drain。observer异常隔离，不改变合法abort结果或丢失Future。

隔离peer验证五动作正常、小ACK严格字段／类型与绑定、未知错误、断连及真实Client deadline。超时用例实际等待Client五秒，未以提前断连冒充；proof等待期间修改caller Map不改变实际发送快照。预算验证是否收到业务frame及未发送事实；精确outer字节向量引用A已测编码器，不假称另做了相同raw计量。

作者还用可信注入clock及捕获的实际15分钟Timer回调验证expiry，以真实C1活动暂停验证第二控制槽busy，另持有两条证明连接拒第三条；独立QA未覆盖全部这些时间／连接穷举，不把revoke推断为独立expiry通过。

## 实际P1与修正

首轮Client只检查ACK摘要为合法64hex。具有正确proof的peer可返回exact成功shape但填另一合法hash，Client仍误报delivered。旧Client `465b6a…` 已固定完整库快照，独立负例实际退出1且前后源码一致。

最小修复仅对media_submit：首次await前从稳定owned bytes复用A decoder取得预期semantic hash，严格比较后才knownReply；不符且businessStarted后为outcomeUnknown。正常peer也改用真实语义摘要，错误但合法摘要保留为专门负例。旧v1 candidate_receive未扩大到新语义校验，candidateId仍仅格式检查。最终全套独立重跑，不用首轮20绿替代修后验收。

作者首次MaterialProbe重复complete引起脚本错误，修测试探针后重跑；旧失败不覆盖、不改产品断言求绿。

## 限定结论

本片有限准出真实本机socket／Client；不证明C2-C同stdin取消、有界stdio输出、八工具、代码流式SDK或C3界面／实际朗读。独立QA未执行15分钟Clock、queued TTL及全部第三连接组合；没有四端实机、人验或发布结论。所有资料为合成fixture、私有执行日志不入Git，不调用新账号或云配音。
