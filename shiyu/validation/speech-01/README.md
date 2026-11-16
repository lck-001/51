# M16 专业发音评测：受限真实接入前验证包

当前仅离线准备。没有发云请求、创建资源、读取真人录音、播放声音、采集设备或操作主界面。

## 已实现与范围

- Python 标准库 REST 请求构造，不安装 Speech SDK。固定 en-US、有参考文本朗读、Phoneme、Comprehensive；默认不启用另计价的 prosody。
- 输入仅本目录原始合成 WAV＋自造参考文本：manifest 校验来源声明、无派生处理、音频与文本 SHA-256、PCM16/16k/mono、每次≤15秒。
- 默认离线；线上另需 `--allow-cloud`、有效具体批准文件、明确资源与价格证据。环境变量仅读取 `AZURE_SPEECH_KEY` / `AZURE_SPEECH_REGION`；不搜索其他目录的凭据。
- 请求限定已审公开 Azure 区域域名、HTTPS、禁止重定向、无自动重试；不自动使用代理、创建资源或切换云／区域。
- 同一验证目录 SQLite 持久总门槛：最多2次、音频合计≤30秒；全批先预留。失败／未知冻结，预留不因超时退回，没有 reset CLI。它不是抗篡改生产配额或供应商账单。
- 合同同时识别 REST 平铺评分与 SDK 嵌套评分；纯 ASR 文本／Confidence 不成为发音分。缺失维度保留缺失，专业音素细节不足标 partial；不输出“正确百分比”。

## 离线运行

```powershell
# 在本目录；只创建本地文件，不播放声音或访问云。
./make_synthetic_fixture.ps1
python speech_probe.py --calls 2 --output results/offline-preflight.local.json
python -m unittest -v test_offline.py
```

生成器限定 Windows 已安装的 Microsoft Zira Desktop 离线语音。参考句：**Let me walk you through the plan.** 若该声音不可用，报错停止，不下载／切换云声音。测试内的 PCM 样例只验证格式与合同，不是发音效果证据。

## 只有最终批准后才可线上运行

复制 `approval.example.json` 为不提交的 `approval.local.json`，填写真实批准依据、有效期、资源、地域、SKU、准确 payload hashes、实际地区报价／取整规则／税费及总额上限。当前模板 `approved=false`、价格均未知，故不能调用。

由资源所有者在当前进程安全注入两个环境变量，不把 key 粘贴聊天、写入参数／文件或输出。然后才可在已批准范围内运行：

```powershell
python speech_probe.py --allow-cloud --approval approval.local.json --calls 2 --output results/cloud.local.json
```

此示例是调用方法，不是执行授权。`--prosody` 还需要独立附加项批准和报价。新地区／主权云／私有端点不自动回退；本包不支持无稿评测、连续模式、TTS、Voice Live 或内容／语法模型。

## 结果与计费边界

只输出哈希、格式、时长、受限状态、评分及词／音素索引；不输出 key、请求头、原始音频、ASR 原文、完整服务响应或私有路径。原始 WAV、manifest、收据、SQLite 被 `.gitignore` 排除。

全批预留后崩溃也不自动再提交。未知是否到达服务时，已预留的次数／时长／估计费用保持占用，需人工核查；不能从 HTTP 超时推定服务未处理或免费。账本不能自行防止用户删除文件，也不能替代账户级预算和供应商真实计费。

本轮 F0 可用性、剩余额度、当前地区币种价格均未核实。官网“5小时/月免费 STT”不能直接变成本次免费承诺。CLI 的成本门槛依赖经批准的真实价格模型，不能保证云价格变化或账户其他调用后的实际账单。

TTS 合成音只证明格式／请求／返回链路；即使以后服务返回高分，也不验证真人初学者纠音、误纠正率、长期学习提升或四端采集效果。见 `../../docs/reviews/M16-speech-provider-gate.md` 的具体审批缺项与官方依据。
