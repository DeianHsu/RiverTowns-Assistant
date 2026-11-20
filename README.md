# RiverTowns-Assistant

《河畔小镇》（River Towns）的 Windows 自动闯关助手。连接 Steam 版游戏后，助手读取实时棋盘，使用游戏规则校验落点，并自动选关、摆放和结算。支持连续闯关、指定关卡和六项特殊成就。

## 安装与启动

1. 在 Steam 安装游戏，并下载或克隆本项目。
2. 首次使用时，关闭游戏，双击 `Start.cmd`，点击 **安装连接组件**。助手会在 Steam 游戏目录中安装 UE4SS v4.0.0 加载器。
3. 从 Steam 启动游戏，再双击 `Start.cmd`。连接成功后，即可在助手窗口选择任务。

自动查找失败时，可指定包含 `EmpireBuilder.exe` 的游戏安装目录。

```powershell
.\Start.cmd -InstallSteamBridge -GamePath "<游戏安装目录>"
.\Start.cmd -GamePath "<游戏安装目录>"
```

连接组件的运行文件位于项目内的 `.river-runtime/live-bridge`。加载器在游戏的 `EmpireBuilder/Binaries/Win64` 目录中使用 `dwmapi.dll` 和 `override.txt`。关闭游戏后，移除本项目安装的这两个文件即可卸载连接组件。移动项目目录后，可用相同步骤移除旧加载器，再从新位置安装。

如果自动下载失败，将官方发行包 `UE4SS_v4.0.0.zip` 放进 `.river-runtime` 后重试。[UE4SS 官方发行页](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/v4.0.0)

## 窗口操作

| 操作 | 游戏行为 |
| --- | --- |
| 从头闯关 | 从第一世界第一关重新开始，按关卡顺序推进。 |
| 从当前关卡开始闯关 | 接着当前棋盘摆放，或进入选关地图上选中的关卡，结算后继续下一关。 |
| 闯指定关 | 挑战下拉列表中的关卡，结束后停在结算画面。 |
| 挑战成就 | 进入对应关卡，按所选成就的条件摆放。 |
| 停止 | 结束本轮自动操作，可在游戏窗口继续手动摆放。关闭助手也会停止本轮任务。 |

成绩由游戏写入当前使用的 Steam 存档。进入关卡和通过世界门遵循游戏的解锁条件。普通闯关依据本关历史最高分判断三星，连续两局仍未达标时停在结算画面。

## 特殊成就

| 成就 | 挑战关卡 | 目标 |
| --- | --- | --- |
| 漂亮！（Nice!） | 河流尽头（River's End） | 完美放置一块拼块 |
| 桥梁（Bridges） | 蜿蜒河道（Serpentine） | 架设至少 30 座桥并结算 |
| 最后的腐化（Last Corruption） | 腐化（Corruption） | 用最后一块拼块净化腐化 |
| 蒸汽浴（Steamy Bath） | 蜿蜒河道（Serpentine） | 用旧贵族建筑覆盖全部间歇泉并结算 |
| 为了鳗鱼之父！（For the Eel-father!） | 远古神庙（Ancient Temple） | 修复神庙，用教士建筑围满四周并结算 |
| 艰苦劳作（Hard Labour） | 逃离（Escape） | 仅用自由民拆除全部崩塌遗迹并结算 |

助手根据游戏发出的解锁请求报告达成情况，Steam 客户端显示账号的解锁结果。两局都未触发所选成就时，助手会停在结算画面。

## 命令行闯关

命令行模式使用静音的游戏副本，启动时跳过片头。首次准备副本需要约 1.1 GB 空间。全三星模式会跳过已经满星的关卡，当前世界全部三星后再过门。连续两局低于三星时，助手保存结算记录并退出游戏，等待复盘。

| 命令 | 用途 |
| --- | --- |
| `.\Start.cmd -Campaign` | 使用 `.river-runtime/profile` 中的助手存档开始或继续全三星闯关。 |
| `.\Start.cmd -Campaign -SteamSave -Visible` | 使用 Steam 本地正式存档，在可见窗口继续全三星闯关。运行前需退出正在进行的游戏。 |
| `.\Start.cmd -StopCampaign` | 停止助手存档的命令行闯关。可用 `-Campaign -Resume` 恢复。操作 Steam 存档时一并传入 `-SteamSave`。 |
| `.\Start.cmd -Trial 02/LVL04_Geyser` | 从助手存档创建隔离试跑，验证指定关卡的策略。 |
| `.\Start.cmd -Campaign -ReviewedRun run-…` | 使用试跑获得的三星记录恢复待复盘关卡。记录须来自当前策略版本。 |

Steam 存档的闯关可在复盘后用 `.\Start.cmd -Campaign -SteamSave -Resume` 恢复。关卡编号可在[关卡表](mod/levels.tsv)中查到。

## 日志与验证

- 窗口任务的事件记录位于 `.river-runtime/live/events.tsv`。
- 命令行结算记录位于 `.river-runtime/run-*/events.tsv`，全三星断点分别位于 `.river-runtime/campaign/state.json` 和 `.river-runtime/campaign-steam/state.json`。
- `.\Start.cmd -Verify` 使用静音隔离存档，检查自动摆放、结算和连续选关。
- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Campaign.Tests.ps1` 检查结算计数、断点和复盘续跑条件。

已验证的 Steam 游戏构建为 `18195330`。游戏更新后，连接组件可能需要适配新的内部接口。
