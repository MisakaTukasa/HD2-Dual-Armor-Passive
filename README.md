# HD2 双护甲被动

本模组通过 Bingus Shared Loader, 在当前身甲自带被动之外, 为人物添加一套可选的护甲被动. 它修改头盔的被动数据, 不改变身甲、头盔或披风外观. 本质是双甲 bug 的延申, 但涉及内存读写, 请酌情使用. 完全 vibe 产物, 0 % 人类含量.

## 安装

1. 在 HD2 Arsenal 中启用 [Bingus Shared Loader](https://github.com/CowboyBingus/BingusSharedLoader/releases) v15 或更新版本.
2. 下载 [HD2-Dual-Armor-Passive.zip](https://github.com/MisakaTukasa/HD2-Dual-Armor-Passive/releases/download/v1.0.3-build25480438/HD2-Dual-Armor-Passive.zip), 导入 HD2 Arsenal, 启用模组并重新部署. 如果安装过旧原型包, 先在 HD2 Arsenal 中移除旧条目.
3. 启动游戏, 在舰船按 F9 检查菜单是否打开.

Mod 版本 `1.0.3-build25480438` 针对 Steam 游戏版本 `25480438`. 不保证兼容性和及时更新, 但会尽量做.

## 选择额外被动

- 在舰船或出击准备界面按 F9 打开菜单; 任务中不能打开.
- 用鼠标点击列表项, 或用方向键选择和翻页. 点击“确认”或按 Enter 应用; 再按 F9、Esc 或点击“关闭”退出菜单.
- 菜单打开时, 鼠标点击由菜单处理, 不会穿透到舰船或出击准备界面的原生按钮; 关闭后原生点击恢复.
- 选择“无额外被动”并确认即可关闭额外被动. 当前身甲原有被动继续由游戏处理.
- 选择会保存, 下次启动自动恢复. 使用游戏原生军械库更换身甲或头盔后, 已选额外被动也会继续应用.
- 如果确认时显示“应用失败”, 本次选择未完成; 请查看日志中的失败原因后重试.

菜单列出参考构建的 31 种护甲被动, 包括*尚未拥有的护甲*对应的被动. 游戏语言设为简体中文时, 菜单使用游戏中的简中名称; 其他语言暂显示英文. 身甲与额外槽选择同一种被动时, 由游戏原有规则处理重复效果; 仅验证"急救包"不会使针数从 6 支叠加到 8 支.

## 排查问题

如果菜单未打开、确认后没有生效, 或游戏更新后出现异常, 先检查是否同时部署了 Bingus Shared Loader 和正式包, 再查看 `%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\HD2DualArmorPassive.log`. 日志中的 `Phase`、`Runtime`、`GUI`、`Scene`、`Native input` 和 `Events` 可帮助定位失败环节. 保存的选择位于 `%LOCALAPPDATA%\CowboyBingus\Helldivers2\HD2DualArmorPassive.cfg`.

目前只对部分代表效果做过实机验证, 其余被动尚未逐一验证.
