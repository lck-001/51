# 2026-11-25 普通客户端功能验收与安卓导入修复

**整体结论：工程能力部分通过，完整英语学习产品不通过。** 普通Windows预览包与当前源码Android APK分别实际运行；不能用空态、禁用按钮或历史探针代替未完成能力。

## Windows普通包

实际验收对象为普通client_main预览入口，App SHA `092f79c46b5e07055cc7fbcd2c282a07f328827a78d4dfb86e6a69a66c873f1e`。通过Flutter自带调试接口观察真实Element tree/帧，并操作实际控件回调；没有换成mock Widget或直接写Core DTO。

| 已实测项 | 结果 |
| --- | --- |
| 五导航、中文录入、保存、确认 | 通过，实际材料和第1固定版本出现 |
| 修改草稿不改变固定版本 | 通过，草稿修订2与固定版1隔离且冷启保留 |
| 双许可默认、独立选择、取消重开 | 通过，原文/音频分别控制，重开恢复默认关闭 |
| 代理送入、候选校对保存和确认 | 通过，真实proxy+SDK投递合成双语/零PCM；确认前不进入学习，不自动播放 |
| 手动播放、暂停、定位 | 通过，实际playing约1090ms、paused约2383ms、暂停定位5000ms；仅自有Player音量0 |
| 点词与词卡 | 未接词典，正确提示不可用；不算词典、音标、例句业务完成 |
| 程序化退出、重开持久性 | 三次实际自然exit0，合成草稿、固定版及学习内容保留；所有本次App/attach进程已结束 |

系统文件选择器、鼠标键盘/X按钮、窄窗、系统大字和真实英语听感未由本轮验证。静音零PCM不能证明朗读质量。最后一次冷启未再次播放音频，不声称该次重播已验。

**仍有问题：** 顶部提示条未铺满，左右露黑底（P2）。最后一次冷启观测到自有窗口visible=false但foreground=true并持续约32秒；量测类型未见明显错误，但缺窗口class/owner/thread/GUIFocus，具体原因未证。已停止该现场，不复开或猜因；后台隔离安全门不能通过。普通可见模式与后台测试模式需分开处理，不能为后者给所有正常窗口加禁止激活。

## Android真实模拟器

使用本项目API36 x86_64任务AVD、无窗口/无声音/无主机相机、私有ADB；未连接真实手机。对原版本实际系统选择器导入有效TXT、DOCX及空TXT，均返回通用失败；手输保存、确认、冷启和返回保护正常。因此原Android工程候选导入链不通过。

**P1原因与修复：** 原生BoundedDocumentImport固定在Activity.cacheDir/material_import_v1写session.source；存储工厂却把Dart读取点统一改成AppSupport的material-import-staging。两端路径不一致，失败发生在解析前。

- AppOwner仅在Android用既有path_provider解析OS cache目录，传入纯Dart typed AndroidMaterialImportCache；固定suffix与原生相同，不传用户选择路径或任意native写路径。
- ClientPrivateStorage仍为headless工厂，不新增插件调用；非Android注入和Android selection混用在lease/Store之前拒绝。Windows原lease child、pathGuard和原件ACL保持。
- Kotlin、SDK/Core、权限、锁文件和依赖版本未改；取消、native idle、清理与真实drain合同不变。

修复APK SHA `13a4b834aa053f67bb2e9ce3038b17753c8c03f695500cbb266a3198437f271e`，版本仍0.2.0+3，以摘要区分。实际install-r升级，无clear/wipe/卸载，旧手输材料完整保留。

| 修复候选真实SAF复验 | 结果 |
| --- | --- |
| 同一有效TXT/DOCX预览、校对、保存、确认 | 通过；全文与fixture精确匹配，预览未写Store |
| 空TXT | 明确无正文提示、Store不变，不再是通用读取失败 |
| 取消后重新导入 | 通过，无虚假新增材料，随后DOCX可成功导入 |
| 原件、sidecar、注册表及冷启 | 原件字节/长度/SHA及提取全文摘要一致，冷启再读4制品全部匹配 |
| 数据与清理 | 最终3草稿/3固定版本/4来源制品，原手输资料保留，两stage目录空；当前包日志未见采样错误/崩溃 |

新增配置契约两例与原Windows host/关闭/存储/导入/来源回归共62项单次通过；三变更文件分析无问题、diff检查通过。新增API缺失的编译红仅是配置契约红；真实SAF旧红与修复绿单独保存。独立源码复审有限通过，真实模拟器操作由独立平台验收者完成，未以headless结果代替设备结果。真实安卓手机尚未验。

## 产品欠交与下一步

自动中文转地道英语、自动配音、专业发音纠正、词典/收藏/带音复习、学习能力看板、共享/反馈、账号同步仍未接通。PPT/PDF/OCR/URL/口述和音视频业务导入未完成；Android本机助手接入尚不支持，不能继承Windows证据。iPhone/macOS没有本轮构建或设备验收。

先将安卓导入P1修复纳管，再独立处理顶部视觉与后台隔离验证方案；学习主线必须补齐“真实自选材料→可校对英语→真实朗读→有效复习”，在此之前不作完整产品验收、灰度或上线声明。原失败、修复及私有环境证据保留，不上传个人资料、descriptor、服务令牌或原始日志。
