# bnb-roblox

把 `~/code/game/BnB`（网页版泡泡堂）完整移植到 Roblox 的项目。服务端权威、纯俯视 2D、房间化对局。

- **服务端**：30Hz 固定步长运行纯 Luau 的 `Game` 引擎（从 BnB `server/game.js` 移植）。移动、碰撞、泡泡、爆炸、道具、坐骑、推箱、踢泡、遥控、针、被困、死亡、掉落、胜负全部在服务端判定。
- **客户端**：只做表现。用 `ScreenGui` 画布渲染地图、精灵、HUD、等待/选角、3-2-1、结算，并在两个快照之间插值。客户端不发送位置。
- **对局（M1）**：服务端可为同一服务器上的多个真人分别运行独立房间。当前每个真人进入自己的练习模式 1v1：等待 10 秒（最后 3 秒锁定选角，未选中的角色卡灰化）→ 选角色 → 3 秒倒计时 → 对战 Bot → 4 秒结算 → 自动下一局。`RoundState`、快照、`Fx`、`RoundEnd` 只发送给该房间的成员，房间之间互不影响。原有 6 人混合 Bot 模式不再对外提供，但引擎仍支持 N 人。
- **数据层（M2）**：玩家档案保存在 DataStore `BnB_Profiles_v1`，加载时用原子 `UpdateAsync` 获取会话锁；同一账号并发登录不会重复发物品。结算、离开、30 秒心跳和关服都会保存；免费库存与购买库存分桶记账。
- **素材**：复用 BnB 的图片/音频。素材未上传时客户端自动降级为色块/文字，逻辑仍可完整游玩。

## 环境

| 工具 | 用途 |
|---|---|
| Roblox Studio | 运行/发布体验 |
| [Rojo](https://rojo.space/) 7.7.1+ | 构建 `.rbxlx` 或同步到 Studio |
| [Luau CLI](https://github.com/luau-lang/luau/releases) | 运行共享引擎测试（`brew install luau`） |
| Python 3.10+、ffmpeg | 预处理 BnB 素材（仅上传素材时需要） |
| Node.js 18+ | 生成/上传资源 ID（仅上传素材时需要） |

## 构建与运行

```bash
rojo build -o bnb-roblox.rbxlx
```

用 Studio 打开 `bnb-roblox.rbxlx` 直接 Play；或：

```bash
rojo serve
```

在 Studio 中通过 Rojo 插件连接。

> `default.project.json` 已关闭 Roblox 默认角色（`Players.CharacterAutoLoads=false`）、清空 3D 场地，并关闭 `StreamingEnabled`。当前每个真人会获得独立练习房间，因此 Max Players 不再是单局人数上限；双客户端验证 1v1 时保持默认即可，后续多房间压测再在 **Place → Game Settings → Players → Max Players** 调高（Rojo 无法写这个属性）。

## 数据层（M2）

玩家档案保存在 DataStore `BnB_Profiles_v1` 的 `Player_<UserId>` 键下。M2 实际写入并恢复选角（`settings.char`）；`currency`、`inventory`（每件物品的 `free` / `purchased` 两桶）、`loadout`、`stats.versus`、`freeNeedle`、`receipts` 等字段已按版本化 schema 预留，供 M3–M5 接入。

- **会话锁**：加载只用原子 `UpdateAsync` 声明锁（`sessionId` + 每次加载唯一的 `lockId`）。活锁超过 120 秒才允许接管；同一账号并发登录时后到者加载失败，不会创建默认档，也不会重复发物品。`lockId` 防止同服旧 handle 在新锁接管后覆盖或清除新锁。
- **保存时机**：房间结算、`PlayerRemoving`、30 秒心跳、`BindToClose`。同一档案的保存和释放走串行队列；释放用一次 `UpdateAsync` 写入最终数据并清锁。普通 DataStore 错误保留 dirty 等下一次重试；只有锁所有权丢失才踢出并提示重新加入。
- **库存**：`consumeStock` 先检查免费 + 购买的总量，足够时先扣免费、再扣购买；不足时两桶都不变。
- **加载失败**：未开启 Studio API 访问、DataStore 不可用或档案损坏时不入座，直接踢出并显示原因；不会静默回退到内存档。
- **加载中提示**：档案加载期间（最长约 7 秒）服务端对 `GetSync` 返回 `{ phase = "loading" }`，客户端显示“正在加载数据…”并关闭输入；入座后服务端推送房间状态，客户端另有每秒一次、最多 60 次的轮询兜底，防止漏掉事件。加载占位不会覆盖已收到的真实状态。
- **免费针规则常量**（`ProfileSchema`，可调）：`FREE_NEEDLE_GOAL = 5` 局得 1 根、`FREE_NEEDLE_START_PROGRESS = 2` 新手起点、`FREE_NEEDLE_DAILY_CAP = 3` 每日上限、`FREE_NEEDLE_STOCK_CAP = 4` 库存上限；发放逻辑属于 M5。

### Studio 前置

1. 将项目发布到一个**独立的测试体验**（Studio 的 DataStore 会写入该体验的生产数据）。
2. 在 **Game Settings → Security** 打开 **Studio Access to API Services**。
3. 用 Studio 打开构建出的 `bnb-roblox.rbxlx`（或 `rojo serve` 同步）再 Play。未发布本地文件或未开启 API 访问时，加入会被踢并提示数据加载失败。
4. Studio 的 **Stop** 不保证等待完整的 `BindToClose`。Studio 主要验证选角恢复和 API 关闭时的踢出；真正的关服保存请用发布后的测试体验或线上服务器验证，或离开前等一次 30 秒心跳。

### 验证

- 加入后等待档案加载再入座；选 `haidao`，完成一局或直接离开，重进后角色仍为 `haidao`。
- 停止服务器再启动，重进确认存档仍在。
- 关闭 Studio API 访问后加入，确认收到“数据加载失败”提示，且没有入座或覆盖档案。
- 同账号并发应由后到者提示“该账号已在其他服务器登录”。单账号无法在 Studio 同时开两个客户端；锁、接管和 fencing 由 `tests/profile/` 的 fake DataStore 覆盖。
- Output 不应反复出现 DataStore 或锁泄漏警告。

## 操作

| 输入 | 动作 |
|---|---|
| WASD / 方向键 | 移动（方向键由游戏独占：Roblox 默认相机会占用左/右键旋转镜头，游戏用更高优先级的绑定接管了全部四个方向键） |
| 空格 | 放泡泡 / 若有遥控泡泡则引爆 |
| Ctrl、Shift、E、B、X | 使用道具（针 / 遥控） |
| 手柄左摇杆/十字键 | 移动（对局中手柄由游戏独占，不再触发界面导航；选角界面仍可用手柄导航） |
| 手柄 A | 放泡泡 |
| 手柄 B / X | 使用道具 |
| 触屏虚拟方向键 | 移动 |
| 触屏泡泡/道具按钮 | 放泡泡 / 使用道具 |

## 共享引擎测试

```bash
bash tests/run.sh
# 或指定 Luau 路径：
LUAU=/usr/local/bin/luau bash tests/run.sh
```

覆盖地图结构、321 冻结、泡泡/连锁/火焰阻断、推箱、踢泡、道具/坐骑/针/遥控、被困/死亡/掉落、断线、胜负、快照字段与 grid 变化；`tests/match/` 用轻量 Roblox/Net stub 跑通练习房间的等待→选角→开局→断线→结算→下一局，并验证多房间互不影响、快照/结算只发给房间成员、快照协议字段、输入清洗和独立房间生命周期；`tests/profile/` 用 fake DataStore 验证档案归一化、免费/购买分桶、会话锁与 fencing、加载/保存重试，以及结算、离场、心跳和关服释放；假 DataStore 还能模拟“写入已提交但响应丢失”和“回调被重跑”两种故障，验证加载、保存、释放、接管在这些情况下仍与实际写入的锁一致。

## 素材管线（可选）

原始素材在 `../BnB/client/assets`。预处理后为 **61 张图片 + 10 段音频 = 71 个资源**，全部图片 ≤1024×1024，音频转 OGG：

```bash
python3 tools/prepare_assets.py
node tools/verify_assets.mjs
```

输出：

- `assets/prepared/images/*.png`
- `assets/prepared/audio/*.ogg`
- `assets/prepared/manifest.json`（key、帧信息、尺寸）
- `tools/studio_asset_ids.json`（手动上传路径的 ID 模板）

生成后的资源 ID 最终写入 `src/shared/AssetIds.luau`（带 `rbxassetid://` 前缀，由脚本生成，不要手改）。**当前 71 个资源 ID 已全部填入**；任何一项为空时，客户端会对该项自动降级。

### 路径 A：Open Cloud 自动上传（推荐，可重复）

1. 打开 <https://create.roblox.com/dashboard/credentials?activeTab=ApiKeysTab>。
2. **Create API Key**，名称如 `BnB-Assets`。
3. **Access Permissions → Assets** 勾选 **Read + Write**（`asset:read`、`asset:write`）。
4. 可选限制 IP / 体验 / 有效期。
5. **Save & Generate Key**，key 只显示一次。**不要提交到仓库、不要贴到聊天里**，只在运行命令的 shell 中通过环境变量提供：

```bash
export ROBLOX_API_KEY='...'
export ROBLOX_CREATOR_TYPE=user      # 或 group
export ROBLOX_CREATOR_ID=12345678    # userId 或 groupId
```

先干跑确认清单：

```bash
node tools/upload_assets.mjs --dry-run
```

确认后再真正上传（外发操作，需自行明确执行）：

```bash
node tools/upload_assets.mjs --images-only
node tools/upload_assets.mjs --audio-only
# 或只传部分：
node tools/upload_assets.mjs --only=img_box,sfx_explode

# 上传完成后生成 AssetIds.luau：
node tools/gen_asset_ids.mjs
```

- 上传缓存写在 `assets/.cache/upload-cache.json`（已 gitignore），可断点续传。
- `--force` 会重新上传已有缓存的项目。
- 审核被拒/配额不足的项会保留为空字符串，客户端继续降级。
- 音频按 `explode → bomb_set → get → role_die → start → save → lose → draw → victory → BGM` 顺序上传。

### 路径 B：Studio Asset Manager 手动上传（无需 API key）

1. Studio → **View → Asset Manager → Images**，**Bulk Import** `assets/prepared/images`（单批最多 50 个，61 张分两批）。
2. **Audio** 标签页导入 `assets/prepared/audio`（10 个 OGG）。
3. 等待审核通过后，右键资产 → **Copy ID**。
4. 把 ID 填进 `tools/studio_asset_ids.json`（键名与文件名一致，例如 `img_box`、`sfx_explode`；可以只填数字，工具会补 `rbxassetid://`）。注意这必须是合法 JSON（最后一项后面不能有逗号），否则 `gen_asset_ids.mjs` 会报错退出。
5. 生成：

```bash
node tools/gen_asset_ids.mjs
```

Studio 映射优先于 Open Cloud 缓存，便于手动纠正。两条路径最终都只修改 `src/shared/AssetIds.luau`。

### 音频限制

- Studio 与 Open Cloud 共用音频上传配额：未验证账号约 10 次/月，实名验证后约 100 次/月。默认只传 9 个 SFX + 1 个 BGM。
- 图片上传后公开可用；**音频默认仅上传者可见**。若体验属于 group，需在 Creator Dashboard 给体验授权音频，或改用有 group 权限的账号/Open Cloud 上传。
- 审核失败或配额不足时留空即可，客户端静音降级。

## 目录

```
src/shared/   Constants/Grid/Map/Characters/Mounts/Flame/Game/Bot/Net/Sprites/AssetIds
src/server/   Main.server / MatchService / Room / PlayerService / BotService / SnapshotService
src/client/   Main.client / Board / Renderer / Hud / Input / Audio / Interpolation
tools/        prepare_assets.py / verify_assets.mjs / upload_assets.mjs / gen_asset_ids.mjs
tests/        headless Luau tests（Game/Bot/Map/Match）+ match stub 环境
assets/       prepared 输出与上传缓存（.cache 不提交）
```

## 网络协议

| Remote | 方向 | 内容 |
|---|---|---|
| `Input` | C→S | 方向数组，最多 4 个合法方向，最后按下优先 |
| `Action` | C→S | `"place"` / `"use"` |
| `SelectChar` | C→S | `"baobao"` / `"haidao"`（仅等待阶段有效） |
| `RoundState` | S→C | phase、roomId、mode、maxPlayers、计时、roster、yourId、grid、结算 |
| `Snapshot` | S→C 20Hz | 玩家、泡泡、爆炸、道具、掉落、滑箱；grid 仅变化时附带 |
| `Fx` | S→C | 音效提示 |
| `RoundEnd` | S→C | 胜者/平局/用时/存活数 |
| `GetSync` | C⇄S | 初始同步（按服务器分配的练习房间，强制带当前地图，不消费广播 grid 标记） |

`Snapshot`、`RoundState`、`Fx`、`RoundEnd` 都由房间实例通过 `Net.send` 定向发送；`Net.broadcast` 仅保留给未来的服务器级通知。

## 开发状态

- 共享引擎、房间化服务端状态机、数据层和客户端入口通过 **687 项 headless 测试**；其中包含多房间隔离、快照/结算受众、练习 1v1 组合、N 人房间配置、房间故障隔离、选角锁定、输入映射（键盘/方向键/手柄）、档案锁与 fencing、响应丢失/回调重跑故障注入、免费/购买库存、加载中提示，以及结算/离场/心跳/关服保存测试。
- 房间故障隔离：`MatchService.step` 对每个房间单独 `pcall`；某个房间抛异常时只关闭该房间并把成员安置到新房间，其他房间不受影响。同一玩家 30 秒内最多被重新安置 3 次，超过后停止自动重建并记录日志（重新同步或重进服务器会恢复）。客户端画布/渲染/HUD/输入/音频已接线。
- 选角锁定的灰化效果（遮罩 + 压暗头像）和手柄交还逻辑只能在 Studio / 真手柄上目视确认。
- M1 房间化重构与练习 1v1、M2 数据层均已完成 headless 验证；剩余实机项是 Studio 双客户端验证（两个真人应各自进入独立练习房间）、M2 存档/踢出流程（需已发布测试体验并开启 API 访问）以及手机/手柄实机测试。素材 ID 已填入，需在 Studio 里确认图片和音频都能正常加载。
- 上传素材属于外发操作；请在明确确认后再运行上传命令。
