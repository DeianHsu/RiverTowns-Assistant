# 河畔小镇闯关助手

Windows 桌面助手，通过《河畔小镇》（River Towns）的内部接口读取实时棋盘和拼块。助手选择合法落点、摆放建筑、等待游戏写入成绩，并按游戏的解锁规则继续选关。

## 启动

1. 首次使用时，退出游戏并双击 `Start.cmd`，点击 **安装连接组件**。助手会查找 Steam 库。也可以用 `Start.cmd -InstallSteamBridge -GamePath "游戏安装目录"` 手动安装。
2. 在 Steam 中启动《河畔小镇》，然后双击 `Start.cmd`。助手会连接已经打开的游戏，并在独立窗口显示进度。
3. 选择闯关方式。游戏会将结算成绩保存到当前使用的 Steam 存档。

- **从头闯关** 从第一世界第一关重新开始，按关卡顺序推进，原有最高分仍由游戏保留。
- **从当前关卡开始闯关** 在游戏中进入关卡或在选关地图上选中关卡后可用。已经摆放过的棋盘会接着打，结算后继续下一关。
- **闯指定关** 从下拉列表选择一关。此模式只挑战所选关卡，结束后留在结算画面。游戏尚未解锁所选关卡时，助手会停止并显示原因。
- **停止** 结束本轮自动摆放，保留游戏窗口和当前棋盘。关闭助手窗口也会结束本轮闯关。

连续两局后，若该关仍未取得三星，助手会停在结算画面供复盘。需要查看本轮选关、摆放和结算记录时，可打开 `.river-runtime/live/events.tsv`。

连接组件使用 UE4SS v4.0.0，在 Steam 游戏目录的 `EmpireBuilder/Binaries/Win64` 中安装 `dwmapi.dll` 和 `override.txt`。运行文件保存在 `.river-runtime/live-bridge`。如果自动下载失败，可将官方发行包 `UE4SS_v4.0.0.zip` 放到 `.river-runtime` 后重试。[UE4SS 官方发行页](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/v4.0.0)

助手读取已放建筑、障碍和待放拼块，用游戏的计分预览比较当前落点，并根据关卡向后搜索。搜索兼顾同色连片、跨河连接、树木复苏、遗迹修复和腐化围堵，并给后续拼块留下可用空间。每次实际落子都由游戏校验。

## 特殊成就

从成就下拉列表选一项，点击 **挑战成就**。助手会进入对应关卡，按所选条件摆放建筑。进入更后面的世界需要在存档中解锁相应的世界门和关卡。

| 成就 | 挑战关卡 | 目标 |
| --- | --- | --- |
| 漂亮！（Nice!） | 河流尽头（River's End） | 完美放置一块拼块 |
| 桥梁（Bridges） | 蜿蜒河道（Serpentine） | 架设至少 30 座桥并结算 |
| 最后的腐化（Last Corruption） | 腐化（Corruption） | 用最后一块拼块净化腐化 |
| 蒸汽浴（Steamy Bath） | 蜿蜒河道（Serpentine） | 用旧贵族建筑覆盖全部间歇泉并结算 |
| 为了鳗鱼之父！（For the Eel-father!） | 远古神庙（Ancient Temple） | 修复神庙，用教士建筑围满四周并结算 |
| 艰苦劳作（Hard Labour） | 逃离（Escape） | 仅用自由民拆除全部崩塌遗迹并结算 |

游戏触发所选成就的解锁请求后，助手会显示完成。Steam 在客户端记录解锁结果。两局仍未触发时，助手停在结算画面。挑战期间可随时点击 **停止**。

## 命令行全三星闯关

`Start.cmd -Campaign` 静音运行全三星模式。助手按世界顺序跳过已满星的关卡，直到当前世界的内置关卡全部三星才会过门。首局低于三星会重试同一关。连续两局低于三星会保存结算记录、退出游戏，等待复盘更新。关卡、计数和待复盘状态保存在 `.river-runtime/campaign/state.json`。

命令行模式首次运行需要约 1.1 GB 空间准备游戏副本。副本的默认存档位于 `.river-runtime/profile`，每次启动的状态和动作记在 `.river-runtime/run-*` 中。

`Start.cmd -Campaign -SteamSave -Visible` 从 Steam 安装版使用的本地正式存档续打，并显示独立的静音游戏窗口。启动前请退出正在运行的游戏。闯关状态保存在 `.river-runtime/campaign-steam/state.json`。复盘后可加上 `-Resume` 继续，或用 `Start.cmd -StopCampaign -SteamSave` 停止。

`Start.cmd -StopCampaign` 停止助手存档的闯关或试跑，可用 `Start.cmd -Campaign -Resume` 恢复。需要在隔离存档中验证某关时，可用 `Start.cmd -Trial 02/LVL04_Geyser`。取得三星后，用 `Start.cmd -Campaign -ReviewedRun run-…` 传入对应的试跑编号，回到助手存档重打同一关。

在 Steam 构建 `18195330` 上，已从本地正式存档实机续打并核验四个世界共 40 关三星。高难关卡可在两局结算后根据日志调整策略，再继续挑战同一关。游戏更新后，内部函数名或数据结构可能变化。

## 验证

`Start.cmd -Verify` 使用静音的独立测试存档启动助手，检查自动摆放、结算和连续选关。

`powershell -ExecutionPolicy Bypass -File tests\Campaign.Tests.ps1` 检查结算计数、检查点和复盘续跑条件。
