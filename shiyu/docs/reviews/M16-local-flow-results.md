# M16 本地材料与受限送入有限验证

2026-11-16。后台代码/测试，无主界面输入、真实资料或云调用。

| 实现 | 实际验证 | 不能扩大成 |
| --- | --- | --- |
| material_core：单设备单writer File Adapter，草稿、不可变确认版本、owner hash分区、不透明制品SHA/length、校验next/backup恢复 | 独立QA30/30：真实临时FileIO、Unicode/换行、两个合成owner、原件不覆写、版本冲突、缺blob/hash损坏、截断恢复；真实新Dart进程重开 | 真实认证、PG事务并发、真实断电、云同步或四端UI |
| backend intake/material领域、Repository、显式validation-only SQLite、PG adapter/migration SOURCE | 独立QA37/37：27领域/SQLite＋10真实localhost TCP HTTP，服务进程重启仍同回执，scope/body-owner/跨owner拒绝、同ID不同payload409、同源另草稿与immutable确认、日志不回显私文 | 正式PG已运行、OIDC/JWT已接、真实Codex工具已连、材料自动生成学习内容 |
| Speech准入REST CLI、预算ledger、批准模板、原始合成WAV与响应合同 | Root与实现者34/34离线通过，显式封HTTP，cloudCallsSubmitted=0；2次共4.870s计划，prosody关闭 | Azure已开通、F0一定适用/有余额、真实声学效果/账单已通过 |

首轮FileStore初始化Windows separator误判导致28失败，按独立QA修URI比较后原断言保留，最终30通过；不把初始化失败当空库成功。后端默认无可信resolver即401；HTTP验证器明确仅合成且服务只127.0.0.1临时端口，测试进程已退出。SQLite不是静默替换PostgreSQL。

用户已选择先准备免费Speech资源方案。仅F0候选且无Prosody，F0不可选/S0/报价非0/免费范围不明则不调用、不升级；官方注册可能有约1美元临时预授权，必须本人决定及登录。当前不索聊天key，不创建资源，不外发真人或工作材料；具体见 M16-free-speech-resource-plan.md。

仍未交付完整学习界面、真实英语生成/TTS/专业发音效果、PG运行/认证、真实外部助手绑定及正式上线。可继续后台实现学习版本与进度锚点，供应商效果必须真实资源批准后单列，不用固定分数或ASR相似率代替。
