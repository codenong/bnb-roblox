# bnb-roblox

把 `~/code/game/BnB`（网页版泡泡堂）完整移植到 Roblox 的项目。服务端权威、纯俯视 2D、自动匹配。

- **服务端**：30Hz 固定步长运行纯 Luau 的 `Game` 引擎（从 BnB `server/game.js` 移植）。移动、碰撞、泡泡、爆炸、道具、坐骑、推箱、踢泡、遥控、针、被困、死亡、掉落、胜负全部在服务端判定。
- **客户端**：只做表现。用 `ScreenGui` 画布渲染地图、精灵、HUD、等待/选角、3-2-1、结算，并在两个快照之间插值。客户端不发送位置。
- **对局**：进入服务器后自动等待 4 秒 → 选角色 → 3 秒倒计时 → 对战 → 4 秒结算 → 自动下一局。真人不足 6 人时 Bot 补满；超过 6 人时多出的真人观战到下一局。
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

> `default.project.json` 已关闭 Roblox 默认角色（`Players.CharacterAutoLoads=false`）、清空 3D 场地，并关闭 `StreamingEnabled`。唯一需要手动设置的是 **Place → Game Settings → Players → Max Players = 6**（Rojo 无法写这个属性）。超过 6 名真人时，第 7 人起观战。

## 操作

| 输入 | 动作 |
|---|---|
| WASD / 方向键 | 移动 |
| 空格 | 放泡泡 / 若有遥控泡泡则引爆 |
| Ctrl、Shift、E、B、X | 使用道具（针 / 遥控） |
| 手柄左摇杆/十字键 | 移动 |
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

覆盖地图结构、321 冻结、泡泡/连锁/火焰阻断、推箱、踢泡、道具/坐骑/针/遥控、被困/死亡/掉落、断线、胜负、快照字段与 grid 变化；`tests/match/` 用轻量 Roblox/Net stub 跑通等待→选角→开局→中途观战→断线→结算→下一局，并验证 >6 人观战、快照协议字段和输入清洗。

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

生成后的资源 ID 最终写入 `src/shared/AssetIds.luau`。**当前所有 ID 为空，客户端使用降级画面。**

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
4. 把 ID 填进 `tools/studio_asset_ids.json`（键名与文件名一致，例如 `img_box`、`sfx_explode`；可以只填数字，工具会补 `rbxassetid://`）。
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
src/server/   Main.server / MatchService / PlayerService / BotService / SnapshotService
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
| `RoundState` | S→C | phase、计时、roster、yourId、grid、结算 |
| `Snapshot` | S→C 20Hz | 玩家、泡泡、爆炸、道具、掉落、滑箱；grid 仅变化时附带 |
| `Fx` | S→C | 音效提示 |
| `RoundEnd` | S→C | 胜者/平局/用时/存活数 |
| `GetSync` | C⇄S | 中途加入/初始同步（强制带当前地图，不消费广播 grid 标记） |

## 开发状态

- 共享引擎与服务端状态机通过 285 项 headless 测试；客户端画布/渲染/HUD/输入/音频已接线。
- 尚未完成：Studio 实机全流程验证、真实素材上传（`AssetIds` 全空）、手机/手柄实机测试。
- 上传素材属于外发操作；请在明确确认后再运行上传命令。
