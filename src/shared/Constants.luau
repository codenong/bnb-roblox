-- src/shared/Constants.luau
-- 全局常量。坐标单位说明：
--   "格"  = 地图网格单位，格子 (col,row) 的中心点坐标就是 (col,row)，边界在 ±0.5
--   "stud" = Roblox 世界单位，1 格 = CELL_SIZE stud

local Constants = {
    -- 地图尺寸
    MAP_WIDTH = 15,
    MAP_HEIGHT = 13,

    -- 每个网格单元对应的 Roblox 世界尺寸
    CELL_SIZE = 8,

    -- 地图中单元格的逻辑类型
    TILE = {
        EMPTY = 0,
        WALL = 1,
        CRATE = 2,
    },

    -- 默认地图中第一格中心点的世界坐标
    MAP_ORIGIN = Vector3.new(0, 0, 0),

    ---------------------------------------------------------------- 玩家
    MAX_PLAYERS = 4,
    PLAYER_HALF_SIZE = 0.34, -- 碰撞盒半边长（格），整个碰撞盒 0.68 格
    PLAYER_BASE_SPEED = 3.4, -- 格/秒
    PLAYER_BASE_BUBBLES = 1, -- 同时可放泡泡数
    PLAYER_BASE_POWER = 2, -- 爆炸威力（向四个方向延伸的格数）
    CORNER_SLIDE = 0.45, -- 拐角辅助：偏离车道中心不超过该值时自动滑入

    -- 出生位置对应的颜色 (RGB 0-255)
    PLAYER_COLORS = {
        { 255, 90, 90 },
        { 80, 150, 255 },
        { 90, 215, 120 },
        { 255, 205, 60 },
    },

    ---------------------------------------------------------------- 泡泡 / 爆炸
    BUBBLE_FUSE = 2.5, -- 泡泡引爆倒计时（秒）
    BLAST_VISIBLE_TIME = 0.45, -- 火焰持续时间（秒），期间踩到也会被困
    TRAP_DURATION = 4, -- 被泡泡困住后多久死亡（秒）
    TRAP_SPEED_MULT = 0.3, -- 被困时移动速度倍率
    TOUCH_KILL_DISTANCE = 0.7, -- 其他玩家碰到被困玩家的距离（格）

    ---------------------------------------------------------------- 回合
    MIN_PLAYERS = 1, -- 开始一局所需人数。开发期设为 1 方便单人测试，上线前改成 2
    INTERMISSION = 3, -- 局间等待（秒）
    END_DELAY = 4, -- 结算展示（秒）

    ---------------------------------------------------------------- 网络
    SNAPSHOT_RATE = 20, -- 服务端每秒广播玩家位置次数
    INTERP_DELAY = 0.1, -- 远端玩家插值延迟（秒）
    RECONCILE_DISTANCE = 1.5, -- 本地预测和服务端相差超过此距离（格）就强制拉回

    ---------------------------------------------------------------- 镜头
    -- 纯 2D 外观：镜头正对地面（90°），视角很小 = 近似正交投影，没有透视变形。
    -- 想要回到伪 3D 的斜视角，可以改成 CAMERA_TILT_DEG = 62、CAMERA_FOV = 40。
    CAMERA_TILT_DEG = 90,
    CAMERA_FOV = 12,
}

return table.freeze(Constants)
