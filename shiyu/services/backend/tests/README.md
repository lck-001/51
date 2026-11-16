# 受限送入独立 QA

2026-11-16，冻结源码后独立执行（backend 目录）：

```text
python -m unittest discover -s tests -v
Ran 37 tests in 4.337s
OK
exit code: 0
```

- `test_intake_sqlite.py`：27 项，真实临时 SQLite；关闭重开及新 Python 进程验证持久回执去重、双合成 owner/integration、scope、不可变版本、expectedRevision、同源待确认更新、原文保留、失败和日志边界。
- `test_http_loopback.py`：10 项，独立隐藏进程的真实 `127.0.0.1` 随机端口 HTTP；验证默认拒绝认证、显式合成身份下的 201/401/403/404/409/413/422、额外 owner/actions 拒绝、HTTP 进程重启幂等、错误及日志不反射正文或合成令牌。
- HTTP 测试显式使用 4096 字节文本上限及对应 raw-body 上限，禁用环境代理；只操作自身进程及临时目录，退出时关闭并清理。未使用 UI、主机音频、公司数据库或公网服务。

SQLite 是验证 Adapter，不是定版生产数据库。合成 resolver/TrustedCaller 不验证真实 JWT/OAuth；PostgreSQL 迁移、生产并发/事务、真实账号、外部 Codex/Agent 工具接入均未执行。这里的确认仅创建材料版本；接收或确认成功不代表学习内容生成、供应商调用、计费或分享成功。
