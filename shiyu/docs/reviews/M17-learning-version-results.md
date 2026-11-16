# M17 学习版本与同版续学验证

2026-11-16。承接M16真实material_core存储，纯Dart本地结构实现，未调用云或启动UI/Player。

实现：固定确认材料版本→不可变学习版本/单元/句ID；manual/synthetic来源；实际注册制品SHA/长度与PCM WAV容器/时长及完整时锚验证；pending/partial/ready结构状态；五字段owner/material/material-version/learning/media绑定；真实checkpoint expectedRevision与旧session拒绝；同版精确位置恢复只paused，新版不搬旧百分比。

独立QA与实现者冻结后分别实际执行25/25、exit0，Dart分析无问题；包含真实临时FileIO及独立新Dart进程恢复原句anchor与4200ms、paused。缺英文/音频/坏PCM/timing不ready，缺媒体/hash/坏索引恢复与拒绝均有测试。证据见packages/learning_core/test/README.md。

边界：ready仅本地结构，不证明翻译自然/双语完成、真实TTS、声音或逐句语音对齐。不会创建Player或发Play；不存在供应商/AI生成假来源。PG/Auth/并发/断电/跨端和完整用户主流程未验。

下一项正在执行：learning_playback协调固定版本制品与真实Playback Interface，Open/恢复永不Play、等实际加载与duration才定位、实际观察进度才落盘；client_shell按已确认原型做注入式前端并后台widget测，不激活桌面。专业服务仍在免费资源准备而未调用。
