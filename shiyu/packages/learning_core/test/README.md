# 学习版本与续学独立 QA

2026-11-16，冻结源码后在本包目录实际执行：

```text
dart run test/learning_store_regression.dart
RESULT passed=25 failed=0 total=25
exit code: 0

dart analyze test
No issues found!
```

25 个外部 Interface 用例使用真实临时文件、真实 material_core 前置数据和独立 Dart 子进程；检查 owner/材料确认版本/学习版本/媒体版本绑定、来源与不可变句锚、缺内容不 ready、PCM 字节时长与时锚、checkpoint expectedRevision/旧 session、同版精确位置恢复为 paused、新版不沿用旧百分比、缺媒体/哈希漂移和损坏索引回退/失败。未读取实现私有字段；未重跑不相关模块。

`wav_fixture.dart` 只在内存产生原创合成 PCM 音调字节，不播放、录音或模拟英文朗读。通过仅证明本地结构与恢复合同：不证明英语自然度、翻译正确、TTS、音质、真实逐句语音对齐、Player/系统后台行为、PG/Auth 或断电耐久。`ready` 不等同 AI 已生成；翻译可为空，不能称双语已完成。备份回退可能回到较早已知位置，测试要求显式报告恢复，不伪装完整最新数据。

测试只修改自己创建的临时目录，结束后清理；本包无云调用、主界面或主机声音操作。
