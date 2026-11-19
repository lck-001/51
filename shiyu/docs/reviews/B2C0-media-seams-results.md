# B2C0：媒体预检与中性投递查询

本包补齐媒体接收前所需的两个 Core 接口，未新增 Schema、持久索引、上传、bridge 工具或 App 界面。

## 接口边界

`inspectExternalCandidateMedia` 为公开纯函数，先限制 bytes、句数和时锚数量，再复用 strict PCM／有序时锚策略，返回实际完整 bytes 的 SHA、长度和时长。媒体 receive 与 matched confirm 共用实际策略，时锚仍使用精确 sample／byte 运算，不因 floor 毫秒放宽。它不注册制品、不读文件、不证明英语朗读或语义对齐。

`findDeliveryReceipt` 直接查询原 delivery map 及不可变 submission，不使用会逐项读取媒体的 listCandidates，不新增映射。closed／hold／writeBlocked 和媒体双 Store 门禁先于 null 或 receipt 早返；版本与 payload 不符为冲突。三种候选终态均返回相同中性 receipt，不返回当前状态、修订、正文或声明，也不改首次 transport 审计。该查询仅证明投递存在，不证明资源此刻可用，完整 submit 仍须真实复验。

## 实际证据

| 范围 | 结果 |
| --- | --- |
| 作者原有与新增回归 | 原59及新6项，合计65项退出0；分析无问题 |
| 独立 QA 相关回归 | 新seams6、media20、候选独立10、本地4，合计40项退出0；分析退出0 |
| 独立补测 | 4/4，退出0 |
| 整 Probe 集成分析 | 无问题，退出0；未重复无变化的上包82项 |

独立补测覆盖128个时锚、60秒边界、精确 sample 越界、完整 bytes 摘要与不可变结果。实际三种终态及 B1 delivery 在原文／媒体代理拒读、文件 IO 全拒的条件下仍可正确查询，读计数为0，主快照、sequence 和审计不变；真实 Material 损坏后的持久 hold 对已有／不存在的键均封门，closed 不可早返绕过。

作者6项首轮有5项完成，最后的测试 finally 重复 close 导致失败；修正测试收尾后6/6真实退出0。该轮失败保留，不修改产品去迁就支架。

独立 QA 还以发布者公开样例做一次纯预检：242732 bytes、7584ms、实际 hash 相符；样例来自 [LJ Speech 发布者页面](https://keithito.com/LJ-Speech-Dataset/)，由本机仅作采样率转换。原始及派生音频、私有路径和执行日志不入 Git。未播放、未独立听辨内容，不称真实听力或音质验收。

## 范围限制

本包不重跑上包的旧库大容量矩阵或旧 Learning25 项独立验证，不把作者结果计作本轮独立执行；Schema 及迁移逻辑没有变化。全仓 implementer 搜索仅 FileLearningStore 实现媒体能力，无需给无关 fake 增加方法。

没有 Material、bridge、UI 或依赖改动，没有新账户、云模型、TTS、原生窗口或播放。下一项是已评审的独立 media_ingest 结构模块；wire、stdio、授权 UI、实际播放及人验分别后续准入。
