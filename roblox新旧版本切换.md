❯ 新的问题：正在运行的服务器，换新的版本，在roblox是怎么处理这个过程的


Roblox 的核心规则是：发布新版本，不会替换正在运行的服务器。

1. 发布时发生什么

- 每台服务器在启动时绑定一个 place 版本，之后一直运行那份代码。
- 发布新版后，新启动的服务器才使用新版本；旧服务器继续跑旧代码，直到自然空服、被重启或因维护关闭。
- 因此新旧版本可能长时间并存：已经进入旧服务器的玩家看不到新 UI/新功能，也不会被强制踢出。
- 同一台服务器内的服务端和客户端都来自同一个 place 版本，所以单服内协议是一致的；混版发生在服务器与服务器之间，以及它们共享的 DataStore 上。

2. 主动切换玩家：Restart Servers

在 Creator Hub：

Creations → 游戏 → Configurations > Server management → Restart Servers

两个关键选项：

- Restart only servers with outdated versions：只重启旧版本服务器，推荐勾选，避免把已经在新版的玩家也踢下线。
- Delay server restart（1–60 分钟）：也叫 “server bleed-off”。给玩家时间自然离开，而不是立即短暂断线。延迟期间：
  - 匹配系统不再把点 Play 的新玩家送进这些旧服务器；
  - 但邀请、传送、通过个人资料加入仍可能进入旧服务器；
  - 服务器会收到 DataModel.ServerRestartScheduled，可用来显示倒计时、保存进度或提前传送。

重启执行后，Roblox 会自动把玩家传送到新版本；同一台旧服务器的玩家会一起被送到同一台对应的新服务器。重启本身不会关闭游戏，玩家仍可重新加入；要彻底关闭需要撤销公开访问。

也可以用 Open Cloud 的 POST /cloud/v2/universes/{universe_id}:restartServers 自动化，支持“只重启旧版本”和 bleed-off。

3. 对本项目的影响

- 内存里的房间和对局会消失：重启后玩家进入新服务器，正在进行的对局无法恢复。当前项目在 BindToClose 里结算道具并保存档案，所以库存和战绩不会丢，但“这一局”本身会中断。
- 新旧服务器同时写 DataStore：更新期间必须保证档案格式前后兼容。现在的 ProfileSchema.normalize 会保留不认识的字段，这是有利的；但不要直接改变已有字段的含义，新增字段也要让旧版本能安全忽略。涉及结构变更时，最好用明确的版本号和迁移逻辑。
- Product ID 不受影响：Product 属于体验（universe），不属于 place 版本。发布新版本不会改变已配置的 ID；只有在另一个体验里重建产品才需要换 ID。
- 配置也不是热更新的：ShopConfig 的改动只在新服务器生效，旧服务器仍用旧配置。即使以后把配置放进 DataStore，也要明确“启动时读一次”还是“每次购买时读”，否则同样会出现新旧服务器行为不一致。
- 迟到的购买收据：发布/重启时可能还有未完成的购买回调。新版本必须继续认识旧产品 ID；下线某个产品时，最好保留它的映射（至少保留一段时间），否则旧收据可能无法发放。
- 先测试再发布：Roblox 发布新 place 版本后，新服务器会立刻对外提供新版。M2 存档、真实购买这类验证应放在独立的测试体验，不要直接拿主体验试。

4. 建议的切换流程

1. 先在独立测试体验发布并验证。
2. 发布正式版本。
3. 在 Server Management 里选择 Restart only servers with outdated versions。
4. 视情况设置 1–60 分钟延迟，让进行中的对局自然结束。
5. 如果需要，监听 ServerRestartScheduled，在对局结束阶段提示玩家并停止开新局。

来源：Release game updates、Introducing Server Management
