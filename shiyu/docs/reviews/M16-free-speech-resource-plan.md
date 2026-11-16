# M16：免费 Speech 资源准备方案

核对日期：2026-11-16。用户当前没有可用 Speech 资源，选择“先准备免费资源方案”。本文件只作准备，不修改已冻结试验包或准入单；没有注册账号、登录门户、创建资源、取得key、请求语音API、安装SDK、操作电脑主界面或上传音频。其他研发不等待本项。

## 1. 结论与零付费边界

**仅准备 Azure Speech F0 的基础发音评测路线；目标是本次 Speech 服务费为0，不把目标写成已经验证免费。**

- 官方价格页列 F0 实时 STT 每月5音频小时，Standard／Custom共享；基础发音评测沿用STT基价，prosody是附加项。这支持把F0作为基础专业评测的首个候选，不是必须先购买S0的依据。[价格页](https://azure.microsoft.com/en-us/pricing/details/speech/)、[发音评测计价与能力](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/how-to-pronunciation-assessment)
- **F0是否真实支持本次完整基础PA：当前未能在用户资源上确认。** 本次打开的主文档没有为这个尚不存在的账号／资源提供逐SKU、逐维度的可调用承诺。基础ASR成功也不证明已返回专业PA；必须在资源确认和明确外发批准后，用限定请求核对准确度、流利度、完整度及请求的音素声学结果。缺失时报告受限，不能换成ASR相似率或自动升级。
- 当前官网地区／币种动态付费金额仍显示 `$-`。F0的公开免费量存在，不代表账号具有资格、有剩余额度或所有附加项免费；**现在不能承诺该用户开通或调用后必为0费用**。
- 零付费是硬停止条件：F0不可选择、创建页显示非0或付费SKU、免费计量关系不明、要求购买额外服务、已有免费限额被占用，均停止。不能自动选择S0、Pay-as-you-go升级、另一账号／区域或其他供应商来绕过。试用赠金抵扣付费服务不作为本方案的F0免费证明。
- 不承诺整个Azure账户总账单为0；已有其他资源、订阅或付费项目不属于本试验。注册验证占款也不能假称从未发生，见下一节。

## 2. 用户本人必须完成的边界

以下步骤只供本人在方便时操作；助手不打开／激活门户、不代按键鼠、不填写身份或支付资料，也不代接受条款。

| 时点 | 本人需要做什么 | 必须停止的情况 |
| --- | --- | --- |
| 账号／订阅 | 如已有合适Azure订阅，先确认有权在该订阅创建专用Speech F0。否则本人从[Azure免费账号官方入口](https://azure.microsoft.com/en-us/free/)了解资格、注册并完成必要身份核验 | 不具资格、无法核验、需要不接受的付费订阅或商业承诺时停止，不另建账号绕限制 |
| 身份／卡片验证 | 官方说明注册可能要求电话及银行卡验证，可能出现约1美元或等值的临时预授权，验证后撤销；必须由本人判断是否接受 | 如果“零付费”还要求完全不能发生临时占款，则不能保证此注册路线满足，停在准备阶段，不代绑卡／付款 |
| 创建资源 | 本人到[Azure门户](https://portal.azure.com/)，查找 **Speech**，检查单一语音资源是否明确提供 **Free F0**，核对创建前摘要后才决定是否开通 | 向导只提供S0／付费Foundry资源或默认带其他付费组件，不照着默认创建；不因门户名称变化就推断免费 |
| 权限与条款 | 本人确认该资源的用途、实际地域、服务协议及音频／参考文本处理许可；key只在本人本机终端使用 | 不提供公司或他人的资源key，不把key、登录验证码、卡号发聊天 |
| 最终试验 | 资源和免费条件确定后，再明确批准固定两次合成音频外发及0服务费上限 | 当前“先准备”不是创建资源或发请求批准；不能由模板中的开关替代本人确认 |

注册中的临时预授权不是本次Speech服务费，但确有资金验证流程，不应淡化。[Azure官方账号说明](https://azure.microsoft.com/en-us/pricing/purchase-options/azure-account)、[官方注册排错](https://learn.microsoft.com/en-us/azure/cost-management-billing/troubleshoot-subscription/troubleshoot-azure-sign-up)

本方案不需要下载工具或SDK：Python标准库客户端已在仓库准备好。官方[Speech入门](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/get-started-speech-to-text)与[REST协议](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/rest-speech-to-text-short)只作参考，不能把“创建免费账号”的文案等同“向导里任何资源都免费”。

## 3. 创建前后的具体确认字段

建议专用、空闲的Speech F0，不接其他应用；仅创建它，不随向导创建模型部署、存储、日志工作区、虚拟机等额外资源。候选公开Azure区域仍为 `eastasia`，实际不可用时停，不静默切主权云／私有端点。现有CLI不会自动跨云回退。

| 本机批准记录字段 | 必须确认的值／证据 |
| --- | --- |
| 实际资源 | 资源名称／ID仅本机留存；资源部署成功，确属获授权账号与订阅；不是只看到门户入口 |
| SKU | 资源详情真实 `F0`，不是S0；创建摘要／当前计价对本次基础PA为免费量内0服务费，保留日期和适用范围 |
| 地域 | 资源实际region与环境变量完全一致；当前候选 `eastasia`。不能凭名称猜测已同意的数据处理地域 |
| 基础PA适用性 | 实际资源允许本包短音频照稿PA，免费计量范围包含此次基础评测；门户说明不足时由本人核对官方支持，不先请求试试看会不会扣钱 |
| 共享免费量 | 当前计费周期、Standard／Custom共享用量、计量器名称／单位、最新入账时间及其他消费者；5小时是合计上限，不各算5小时 |
| 剩余可用量 | 足以覆盖本批两次及已确认的计费取整／最低量。新建资源的“尚无数据”不等于已核实余额满额 |
| 付费项 | prosody关闭，不启用连续语言识别、说话人分离、自定义训练／托管、Voice Live、内容／语法模型、TTS或额外日志服务 |
| 费用与控制 | 0服务费上限、实际原币种、F0免费资格／余量证据；计费取整、最低量、税费说明与失败用量处理清楚。不能为了通过模板把未知价格、税率或规则随便填0 |

免费账号可在门户的 Subscriptions → 对应订阅查看免费服务的 Meter、Usage/Limit、Status，并在Cost analysis按本资源过滤；其他订阅／界面未展示同一免费服务表时，不套用免费账号专属优惠。官方说明这些用量状态可能延迟 **1–2天**，所以即时0账单或未显示数据不能单独证明免费。F0的5小时共享规则以Speech价格页为准，不与免费账号赠金余额混算。[免费用量官方核查路径](https://learn.microsoft.com/en-us/azure/cost-management-billing/manage/check-free-service-usage)、[Speech免费量](https://azure.microsoft.com/en-us/pricing/details/speech/)

F0实时请求并发上限为1，不可提高；本包串行执行。若创建限制提示已有／已删除的F0资源占额，不自动清理旧资源、反复创建或改区域；由本人确认实际订阅限制后再处理。[Speech配额说明](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/speech-services-quotas-and-limits)

## 4. 保持不变的具体试验

- 原始离线Microsoft Zira Desktop合成WAV，参考句：`Let me walk you through the plan.`
- PCM16LE、16kHz、单声道；每次按毫秒向上取整2.435秒，最多两次，共4.870秒。音频与参考文件hash沿用[M16冻结准入单](M16-speech-provider-gate.md)，不重新合成／改hash绕过批准。
- 固定 `en-US`、有稿、专业Phoneme／Comprehensive／Miscue，**不传 `--prosody`**。本包硬门槛2次／30秒不代表获准用满30秒，最终批准范围可收紧为这份固定文件的4.870秒。
- 只有资源、免费条件、数据外发及有效期均明确后，才填写本机 `approval.local.json`：`resourceTier=F0`、`prosodyApproved=false`、固定hash、两次／4.870秒、经核实的免费余量与0服务费预算。当前模板仍未批准，原试验包不因本方案改成可调用。
- 基础PA返回缺失、无音素声学细节、401/403/429、超时／未知、免费条件或费用出现异常，停止后续请求并保留预算记录；不升级、不盲重试、不删除账本来再试。
- 只评估合成音链路。高分也不证明初学者纠音质量；ASR Confidence和文字匹配不算发音分。两次真实结果与账单均尚未取得。

## 5. 仅供本人执行的本机安全环境模板

此模板现在不执行，也不发云请求。它仅在**当前终端进程及其子进程**短暂设置变量，完成后清除；不会把key自动传给已运行的Codex进程。无需 `setx`、机器级环境变量、`.env`文件、门户截图或聊天传key。

```powershell
# 仅在资源与免费条件已核对后，由本人在 validation/speech-01 目录执行。
# 不启动录音／播放器／浏览器，不输出key。
$speechRegion = (Read-Host '输入资源中已确认的 region').Trim()
$speechSecureKey = Read-Host '在本机输入 Speech key（隐藏，不发聊天）' -AsSecureString
$speechBstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($speechSecureKey)
try {
  $env:AZURE_SPEECH_REGION = $speechRegion
  $env:AZURE_SPEECH_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($speechBstr)
  # 默认仍离线；此命令不会读key或联网。
  python speech_probe.py --calls 2 --output results/offline-preflight.local.json
  # 获得明确的最终外发批准后，才在同一作用域使用经审阅的线上命令。
  # 这里不自动调用 --allow-cloud，也不自动填写 approved=true。
} finally {
  Remove-Item Env:AZURE_SPEECH_KEY -ErrorAction SilentlyContinue
  Remove-Item Env:AZURE_SPEECH_REGION -ErrorAction SilentlyContinue
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($speechBstr)
  $speechSecureKey.Dispose()
}
```

隐藏输入避免key明文出现在命令历史；环境变量仍是进程内明文，不等于加密保险库，临时BSTR清零也不保证清除所有运行时副本。不要把执行终端做含凭据的录像／转录。将来生产使用独立密钥管理，本次不为此安装新工具。

## 6. 费用核对、撤销与清理

1. **执行前**记录F0、免费量范围和最新用量证据，确认专用资源没有其他消费者。保持付费升级与附加项关闭；免费量不足或无法确认即不调用。预算告警不等于即时硬停，本包本地门槛也不替代账户计费。
2. **执行后**对照本机批次账本／实际提交次数，与该资源的计量和Cost analysis复核。考虑官方1–2天入账延迟后再检查，不把刚请求后的0当最终结算证明。任何非0服务费或不可解释计量立即停止并由本人核查，不用追加调用“试到成功”。
3. **本机撤销**结束CLI并清理上述临时环境。保留已脱敏账本／收据到费用核对完成，不清库重置两次门槛。
4. **资源撤销**如果不再使用，由本人在门户对这个专用资源撤销／轮换用过的key；确认不影响其他应用后再删除该资源。核对删除完成，不自动删整个资源组、其他资源或公司订阅。
5. 如果注册免费试用需要转付费才能延续，**不自动升级**。是否保留或取消专用订阅由本人决定；其他研发可继续本地／后台工作，不以此为由控制电脑或停工。

当前阶段：免费资源路线准备完成，账号／资源／免费资格及最终数据批准待本人确认。下一步：本人方便时决定是否接受官方注册验证并核对F0；团队继续其余研发。当前没有必须立即操作电脑主界面、交出key或提供真人录音的动作。
