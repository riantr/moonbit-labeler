# 视频标注 Schema 与工作流

> 本文档锁定 `Label@<name>/<video>.json` 的字段约定、与图像 JSON 的关系、以及
> "视频视作若干静态帧" 这条产品决策带来的实现细节。

## 1. 设计原则

- **视频 = 帧序列**。把视频看成一组按时间排序的静态帧，每一帧都可以独立标注。
- **复用图像标注器**。所有图像功能（rect / polygon / keypoint / binding、撤销、
  画布、平移/缩放、autosave）在视频模式下都保持原样。
- **向后兼容**。已有 CARS 图像的 `Label@<name>/<basename>.json` 必须继续能读
  能写。新增的 `frames` 字段是可选的，缺省 = 适用于整段视频（图像模式
  仍使用 `frames: []` 作为占位）。

## 2. 文件约定

| 资产     | 路径                                            |
|----------|-------------------------------------------------|
| 视频     | `Video@<dataset>/*.mp4`                         |
| 标注     | `Label@<dataset>/<basename>.json`               |
| 缩略图   | `<cache>/thumb/<basename>.jpg`（运行期生成）    |

> `<basename>` 必须 **原样保留**（含 `_0`、`_1` 等后缀），不要试图剥离。

## 3. JSON schema

### 3.1 图像模式（保持原样）

```json
{
  "img_name": "1800003_0.jpg",
  "infos": [
    { "id": "obj_abc12", "shape": "polygon", "type": "scissors",
      "points": [[120, 80], [180, 90], [200, 200], [110, 220]] }
  ],
  "bindings": []
}
```

### 3.2 视频模式（新增 `frames` 字段）

```json
{
  "img_name": "clip_001.mp4",
  "frames": [12, 24, 25, 26, 27, 28, 29, 30, 60, 120],
  "infos": [
    { "id": "obj_abc12", "shape": "rect", "type": "person",
      "points": [[10, 20], [110, 220]] },
    { "id": "obj_xyz34", "shape": "polygon", "type": "car",
      "points": [[300, 400], [500, 400], [500, 600], [300, 600]] }
  ],
  "bindings": [
    { "id": "b_aaa", "from": "obj_abc12", "to": "obj_xyz34", "type": "same_group" }
  ]
}
```

### 3.3 字段语义

| 字段        | 类型          | 含义                                                         |
|-------------|---------------|--------------------------------------------------------------|
| `img_name`  | string        | 原始视频/图片文件名（保留扩展名）                            |
| `frames`    | number[]      | 该 JSON 适用于哪些帧（空数组 = 适用于所有帧 / 图像模式）     |
| `infos`     | object[]      | 标注对象列表，结构与图像模式完全相同                         |
| `bindings`  | object[]      | 关联，与图像模式完全相同                                     |

### 3.4 `frames` 规则的隐含约定

- **单文件多帧**：当前 MVP 模式。视频中**第 N 帧对应的标注**存放在
  `Label@<dataset>/<basename>.json` 的 `frames: [N, ...]` 子集里。
  1 个视频默认对应 1 个 JSON，标注可以分多次存，每次存的是"当前帧的标注"。
- **同帧合并**：当 `frames` 数组里出现重复帧号时，读取端做集合去重。
- **未列出帧**：未在 `frames` 内的帧没有该标注（即"无标注"状态）。
- **空 `frames`**：视为图像模式。视频读取端把"当前帧"默认为 0，并展示
  `frames: []` 的全部内容；写入端会保留 `frames: []`。

> 升级路径：未来如果要支持"按帧区间"或"轨迹"，
> 在 `frames` 上方加 `tracks: [{ id, start, end, infos: [...] }]`，向后兼容。

## 4. 帧↔标注绑定策略

打开一个视频，UI 维护两套关键状态：

```
state.currentFrame      // 当前帧号 (number)
state.frameLabels       // Map<frame, { infos, bindings, dirty }>
                         // 当前文件的"按帧"标注缓存
state.diskJson          // 上次从磁盘加载（或 save 之后）的 JSON 快照
```

### 4.1 切帧流程

```
用户拖动 timeline / 上一帧/下一帧
  → selectFrame(idx)
    → 切帧时如有 dirty → flushSave()
    → loadLabelForFrame(idx)
      → 在 state.frameLabels 找 idx
        - 命中：渲染之
        - 未命中：从 state.diskJson 过滤 frames.includes(idx) 的条目
                 装到 state.frameLabels[idx] 再渲染
```

### 4.2 标注完成 / autosave 流程

```
用户标完一个对象
  → markDirty()
    → state.frameLabels[state.currentFrame] = 当前帧标注
    → 触发 autosave
      → saveLabel()
        → 合并 state.frameLabels 中所有 dirty 帧到 state.diskJson
        → 写盘
```

### 4.3 "复制到下一帧"

```
click 工具栏"复制到下一帧"
  → 把 state.frameLabels[state.currentFrame] 的 infos / bindings
    浅拷贝到 state.frameLabels[state.currentFrame + 1]
  → selectFrame(currentFrame + 1)
  → markDirty()
```

> 浅拷贝而不是新生成 id——这样下游消费方仍能按 id 跟踪同一物体跨帧的轨迹。

## 5. 后端 IPC 契约

| Op                | Request                                | Reply                                |
|-------------------|----------------------------------------|--------------------------------------|
| `list_videos`     | `{ path: string, extensions?: string[] }` | `{ folder, videos: VideoEntry[] }` |
| `read_video_info` | `{ path: string }`                      | `{ path, durationMs, fps, width, height, frameCount, codec }` |
| `read_video_frame`| `{ path, frame: number, mime?: string }` | `{ path, frame, base64, mime, width, height }` |

`VideoEntry` 字段：

```jsonc
{
  "name": "clip_001.mp4",   // 文件名
  "path": "D:/.../clip_001.mp4",
  "ext": ".mp4",
  "sizeBytes": 12345678      // 用于排序/筛选
}
```

> 注：本 MVP **不缓存**抽帧结果。每次切帧都过 ffmpeg 抽一张 JPG。
> 对于 1080p 视频抽 1 帧 ≤ 50ms，体验可接受。后续要快可以加
> `frame_cache` op + 本地 JPEG 目录缓存。

## 6. 抽帧命令

```bash
ffmpeg -ss <seconds> -i <video> -frames:v 1 -q:v 3 -y <out.jpg>
```

`-ss <seconds>`：把帧号换算成秒，公式 `t = frame / fps`。
`-q:v 3`：JPEG 质量（2~5 较平衡）。返回的 base64 mime 固定 `image/jpeg`。

## 7. UI 增量（视频模式）

底部增加 `Timeline 组件`（不替换 statusbar）：

```
[ ◀上一帧 ] [ ▶下一帧 ] [ 00:01.234 / 00:30.000 ] [●━━━○━━━━━━━]
                                                      帧 37/900
[ ⎘ 复制此帧到下一帧 ]   [ ✓ 已标注 8 帧 / 总 900 帧 ]
```

`Timeline` 用 `<input type="range">` 实现就够。文件列表中视频条目带一个
▶ 角标，区分 JPG / PNG / MP4。
