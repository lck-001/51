# 学习到播放串接独立 QA

2026-11-16，在本包目录实际执行：

```text
dart run test/coordinator_regression.dart
RESULT passed=22 failed=0 total=22
exit code: 0

dart analyze test
No issues found!
```

只修改本目录。真实 `FileMaterialStore` / `FileLearningStore` 和临时私有缓存与受控 Engine/System Adapter 串接；工作确认 Future 与观察事件严格分离。用例检查：

- 独立 Dart 进程复用已校验缓存文件，原件不覆写；缺源、同长度缓存篡改、错 owner/媒体版本明确拒绝。
- Open 不 Play；确认收到加载命令不等于 ready；loaded 与正确正时长到达后才恢复同版精确位置，并继续保持暂停。
- checkpoint 保存受控观察到的位置，不保存 Seek 预览目标；超时有稳定错误且不能算到位。Pause/超时不复活旧自动恢复，Stop 的零位置不覆盖有效续学位置。
- 旧素材事件、新媒体版本、跨 owner、绕过学习入口的 Open 及旧 session 不污染当前上下文；外部推进 checkpoint revision 后旧协调器不盲目重试覆盖新值。

`support.dart` 只生成原创 PCM 静音字节，不是英文朗读、模型输出或 TTS；没有创建 Player、播放/录音、主界面、键鼠、锁屏或云操作。测试通过只证明该本地结构和协调合同，不证明原生解码、实际 Seek/声音、OS 后台宿主、语言质量、PG/Auth 或断电耐久；不相关模块未重跑。所有子进程及自建临时文件均已收尾。
