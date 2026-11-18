# M20-A Android 实际 SAF 导入结果

2026-11-18，任务自有 API36 AOSP x86_64 模拟器。全过程 `-no-window/-no-audio`，主机相机／麦克风均不接入，AVD 只读运行；只使用私有 ADB5038 和明确虚拟设备，不访问默认 ADB、真实手机或主机界面。测试材料全部原创合成。

## 候选与结果范围

| 候选 | 实际证据 |
| --- | --- |
| `4039c0af9f0b3fa1b7dbb02f016c2969c7ef8b079b4972f385619e9dbb17e2b5` | TXT／DOCX完整实际 SAF、校对保存、来源附件、确认、冷启及取消／损坏／空／已知大小超限矩阵；75项标量检查通过 |
| `64650bb7444985a011c0fcfda70af4d3627b7cd4970445b1112b8df24f3f358e` | 最终 caller 重选保护包；升级保留旧材料、预览禁重复导入、原 stage 不丢失、真实保存／来源／确认／冷启；32项标量检查通过 |

两包均为未发布的 `0.1.1+2` debug 候选、121193104字节。SHA区分本次候选，不能把旧包完整矩阵说成新包重新执行过全部用例。最终改动是 Shell caller 重选保护，解析／SAF底层未变化。

实际安装包回读 SHA 与对应候选一致。合并 manifest 为 min24／target36；权限为 debug INTERNET、WAKE_LOCK、FOREGROUND_SERVICE、FOREGROUND_SERVICE_MEDIA_PLAYBACK及应用 signature动态receiver权限，无新增全盘存储、相机或麦克风权限。APK依赖目录列出三种 native ABI，但本次只实际验证 x86_64，不能据此宣称其它ABI可安装运行。包名／图标名称仍沿用工程测试身份，非正式发行包。

## 已走通的业务链

1. 在 App 点“导入文件”，实际打开 Android DocumentsUI 的系统 `ACTION_OPEN_DOCUMENT`；通过 Downloads或内部存储的已观察目录和文件列表选择合成文档，没有向App注入文件路径冒充选择器。
2. TXT 中文／英文／emoji和换行与既定黄金文本逐字匹配。预览阶段 Store 中没有新增草稿或制品；用 guest 输入校对文字后保存。
3. 真实回读本App私有 FileStore 和 blob，确认源文件字节／SHA、提取来源JSON、parserVersion、块定位及各制品长度／SHA。源文件CRLF原样保留，提取文本正规化LF，用户校对后草稿hash与提取hash正确区分。
4. DOCX 使用非固定 `q:` 前缀、中文／英文／emoji、正文和两行表格；五行次序及制表符逐项匹配。保存的来源JSON含 tableRow 定位，原DOCX附件字节与fixture完全相同。
5. 两份材料分别保存、确认第1版后，强停App并冷启动，两个草稿／两个固定版本／四个来源制品仍可真实读取。五份原始输入在guest的SHA均未改变。

最终guard包升级时保持上述两份材料；再实际导入一份合成TXT验证：预览的导入按钮 disabled，有先保存／返回提示；guest点击 disabled 区域不打开选择器，原私有 stage 文件及hash保持不变。校对标题并保存、确认、冷启动后为3草稿／3版本／6来源制品，原来两份数据未改变。保存收尾后私有stage目录为空。

## 负向与取消

- 实际在系统选择器取消返回 App，入口重新可用，前后草稿／来源制品注册表未改变。
- 选择损坏 DOCX：稳定显示无法处理，不创建假草稿或制品。
- 选择空 TXT：明确没有可导入正文，不创建假成功结果。
- 选择 `20MiB+1` TXT：供应商提供已知 SIZE，原生快拒并明确提示按章节拆分；前后 Store 不增，没有返回截断文件。
- 任务包崩溃缓冲区为空，当前包级日志未见 FATAL、native fatal、未处理异常或布局溢出标记。这是本批采样，不是“永不崩溃”的结论。

## 证据限制与脚本修正

- **未知／谎报 SIZE 的真实 ContentProvider 未实测**，其实际逐读上限和取消门闩已进行源码评审，但不能把上述已知大小快拒当该路径已通过。被供应商阻塞的 open/read 取消也未做真实provider故障注入。
- Windows原生选择器、真实安卓手机、iPhone／macOS未在此批验收。无云翻译、配音、发音评测、公开发布或分享。
- 只读AVD中验证了 App冷启持久化；没有声称销毁只读AVD后临时层仍保留。
- adb推入的合成文件初期尚未被DownloadsProvider索引，刷新合成文件索引后继续使用真实SAF；后续异常fixture经内部存储provider选择。
- DocumentsUI网格会暴露被系统导航栏遮挡的文件文字bounds。首个空文件脚本误点返回，改为列表和可见bounds／滚动定位后重新验证，未当App缺陷或成功掩盖。
- 最终guard脚本曾把正规化LF正文与原始Windows CRLF直接比较。与既有黄金LF全文核对确认App正确后修正脚本，并从同一已保存草稿继续确认／冷启，没有清数据或重复造草稿。私有原执行记录及修正说明保留。

原始UI XML、截图、Store快照、原始日志、fixtures和本机路径仅留私有结果目录，不进入公开Git。最终按实时 AVD名称／qemu／私有ADB进程归属核验后关闭自有AVD与ADB5038：专用端口全空，自有模拟器进程0，未触碰默认ADB或真实设备。
