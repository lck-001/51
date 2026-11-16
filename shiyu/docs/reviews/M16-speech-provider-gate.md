# M16：专业发音评测接入前有限准入

日期：2026-11-16。承接 `planning/gate-v06/专业语音有限验证候选-v0.6.md`；本包缩小为**同一原始合成短 WAV 最多2次、提交音频合计不超过30秒**。不扩展为 v0.6 的真人／50次验证，不构成云资源、费用或外发批准。

## 已完成与未执行

已准备 `validation/speech-01/`：标准库 REST 请求构造、格式／hash门禁、专业声学结果合同、持久次数／时长／费用预留、默认离线 CLI 及离线测试。已本机离线合成自造文本 WAV，不采集或读取真人声音，不播放、不操作电脑主界面。

**本轮 Speech 云请求为0，没有资源创建、服务分数、计费账单或真人纠音效果证据。** 离线测试用合成 PCM 和自造 JSON 检查程序合同，不能冒充供应商真实回归。

## 当前官方协议核查

1. 短音频 REST 发音评测上限30秒，WAV为16kHz、单声道PCM。请求用 `Pronunciation-Assessment` Base64 JSON；本包有稿 en-US、HundredMark、Phoneme、Comprehensive、Miscue；prosody默认关闭。REST 当前文档示例将分数直接放在 `NBest[0]`，不能只按 SDK 常见的嵌套 `PronunciationAssessment` 解析。[REST协议及响应](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/rest-speech-to-text-short)
2. 官方 SDK 示例仍给出区域端点，故受限客户端可以只用 key／region；新指南同时提供资源专属域名。实际资源若要求私有／自定义域名或主权云，本包停止，不擅自转到公共区域。[微软当前官方示例](https://github.com/Azure-Samples/cognitive-services-speech-sdk/blob/master/scenarios/python/console/language-learning/pronunciation_assessment.py)、[区域与处理范围](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/regions)
3. 专业声学分与识别文字／置信度不同；音素相近程度、流利度、完整度是模型维度，百制分不是客观正确百分比。REST有稿与 SDK无稿不是同一合同；SDK内容评估预览自1.46起退役，不能顺带承诺语法／话题打分。[评测使用与版本限制](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/how-to-pronunciation-assessment)
4. 发音评测基础用量参照标准 STT；韵律是额外特性。当前公开价格页在未选实际账号报价时显示 `$-`，本轮无法核实2026-11-16指定资源／地域／币种的金额，不写单价和人民币换算。[官方价格页](https://azure.microsoft.com/en-us/pricing/details/speech/)
5. F0页面列实时 STT 每月5音频小时，标准／自定义共享，不能据此断言当前账号有F0、还有额度或本次评测／韵律免费；F0并发为1且不可调，本包串行请求，但仍须核实资源实际允许评测。[免费说明](https://azure.microsoft.com/en-us/pricing/details/speech/)、[配额](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/speech-services-quotas-and-limits)

## 最终审批的具体数据与缺项

| 事项 | 已具体化内容／仍缺项 |
| --- | --- |
| 外发数据 | 仅本机 Microsoft Zira Desktop 合成的原始16k/mono/16bit WAV；参考句 `Let me walk you through the plan.`；不包含工作记录、账号、真人录音或完整材料库 |
| 固定 payload | 本次音频 SHA-256 `27fe53c37eece07cd6f7b49da9b1a40c174f0620a7d711934fbf3d1fbc82c41d`；参考文件 SHA-256 `6af5f411ca79e53c43c433c8e4155f046a1f437c6401156941e70bb89d25ec5e`。重新合成改变hash须重新批准 |
| 次数／时长 | 拟最多2次同文件请求，用于链路与有限重测。每次按毫秒向上取整为2.435秒，合计4.870秒；实际计费取整／最低计费尚待核实，不把4.870秒直接当最终计费量 |
| 功能 | 照稿声学评测，en-US；prosody关闭；不调用内容、语法、LLM、TTS或Voice Live。自由口述后续单独验证，不以本包替代 |
| 地域与资源 | 候选公开Azure `eastasia`，尚未确认具体订阅／Speech资源ID、实际地域、F0/S0、端点和资源所有者的用途授权；不同云不自动回退 |
| 凭据 | 由获授权资源所有者仅向当前进程注入 `AZURE_SPEECH_KEY`、`AZURE_SPEECH_REGION`；不在聊天索要key、不搜本机其他凭据、不代建资源。实际key与资源归属及区域匹配需所有者确认 |
| 费用批准 | 缺实际地区／币种价格证据、有效日期、最低计费／取整、失败处理／税费、F0余额（如主张免费）、原币种总额上限及付费人。官网动态金额未核实，**当前不能给出可批准金额** |
| 外发批准 | 用户需明确同意上述payload和区域处理，填写批准依据与有效期。模板保持approved=false；仅有产品研发授权或 `--allow-cloud` 不能替代这一批准 |
| 人工专业复核 | 本轮合成音仅验证链路；后续真人样本的自愿许可、专业核验者、同条件基线和严重误纠正标准仍未具备，不能报告专业效果通过 |

费用模型只在取得实际报价后填写：每次计费秒数为 `max(已核实最低秒数, ceil(提交秒数/已核实取整单位)×单位)`，再按基础／批准附加项小时价、每请求费用与税费估算，预留整批。实际计费还需账单核对；不承诺“失败不收费”或预算告警即时硬停。

## 软件执行门禁与未知状态

- 默认离线，不读取key、不创建HTTP opener或云预算库。线上必须显式开关＋具体批准文件＋固定hash／地区／资源／费用字段全部有效。
- 只允许已核公开Azure区域的HTTPS端点，禁止重定向和自动代理，不把key转到其他主机。请求串行，最大发送2次，总音频≤30秒，每次≤15秒。
- SQLite `BEGIN IMMEDIATE` 对全包持续预留次数、时长、费用；不同进程重启或新批准不能清除总门槛。没有 reset CLI，删库属于人工变更，不能视为正常恢复。
- 批次先预留，断网／超时／解析失败／专业评分缺失不自动退回或重试。未知与失败冻结后续调用，需核对真实处理状态／用量；HTTP结束不证明供应商未计费。
- 结果区分完整、partial、无有效语音、专业评分缺失；缺音素声学细节不补造，ASR Confidence永不作发音分。模型版本若服务未提供则未知，不伪称两次同模型。

## 数据留存边界

微软说明实时音频在服务器内存处理、不存静态音频；发音评测会处理音频及参考文本。这不能代替实际资源条款，也不等于客户端／可选日志从不存储。本包不开启音频日志、自定义训练、翻译或额外模型。[官方数据说明](https://learn.microsoft.com/en-us/azure/foundry/responsible-ai/speech-service/speech-to-text/data-privacy-security)

本地只保留原始合成fixture、hash与脱敏合同收据／预算账本；不输出原始音频、完整服务响应、ASR原文、请求头、secret或私有路径，生成物被gitignore排除。

当前阶段：专业语音接入前离线验证。下一步：独立复核本包后补实际资源／报价／数据批准，再执行有限真实请求；当前用户无需操作电脑主界面或提供真人录音。
