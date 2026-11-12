# 视频标注 Schema 与工作流

> 本文档描述 **Proton / CEF 版本**（`frontend/` + `extensions/labeler/`）的视频标注实现。
> `app_moui/` 是另一个原生实验分支，尚未进入生产路径。

## 1. 设计原则

- **一个视频一个 JSON**。标注不按帧拆成多个文件，全部落在
  `Label@<dataset>/<basename>.json` 里。
- **每帧一套标注**。这是核心：早期实现把"当前帧的标注"合并进一个扁平集合再写盘，
  结果第 5 帧画的框会悄悄出现在第 9 帧上，两帧永远无法不同。
- **归一化与投影在后端**。`extensions/labeler/video_label.mbt` 拥有磁盘 schema，
  前端只负责"哪一帧"和"画什么"。这样 schema 只有一个真相来源，也能被 CI 测到。

## 2. 文件约定

| 布局 | 视频 | 标注 |
|---|---|---|
| 数据集布局 | `Video@demo/clip_001.mp4` | `Label@demo/clip_001.json` |
| 扁平布局 | `D:/photos/clip_001.mp4` | `D:/photos/clip_001.json` |

判定规则与图像模式一致（见 `labeler.mbt` 的 `label_path_for`）：先看目录名前缀
`Video@`，再退化到扩展名嗅探（`.mp4/.mov/.mkv/.avi/.webm/.m4v`）。

## 3. JSON schema

### 3.1 图像模式（不变）

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

### 3.2 视频模式（`frame_labels`）

```json
{
  "img_name": "clip_001.mp4",
  "infos": [],
  "bindings": [],
  "frame_labels": [
    { "frames": [12], "infos": [ ... ], "bindings": [ ... ] },
    { "frames": [24, 25], "infos": [ ... ], "bindings": [ ... ] }
  ]
}
```

### 3.3 字段语义

| 字段          | 类型     | 含义                                                        |
|---------------|----------|-------------------------------------------------------------|
| `img_name`    | string   | 原始视频文件名（保留扩展名）                                |
| `infos`       | object[] | **默认标注集**，见下方说明                                   |
| `bindings`    | object[] | 默认集里的关联                                              |
| `frames`      | number[] | 默认集适用于哪些帧（缺省 / 空 = 适用于所有帧）              |
| `frame_labels`| object[] | **按帧的标注集**，每项自带 `frames` / `infos` / `bindings`   |

### 3.4 默认集 vs 按帧集

- 顶层的 `infos` / `bindings` / `frames` 组成**默认集**，永远是第一个集合。
  默认集 `frames` 为空表示"适用于所有帧"；非空表示"只适用于这些帧"。
- `frame_labels` 里每一项是**按帧集**。一个帧最多属于一个按帧集；
  投影时按帧集优先于默认集。
- **向后兼容**：早期版本写出的"扁平单集合"文件，顶层就是默认集，
  `frames` 列了哪些帧就适用于哪些帧——读出来行为完全一致，不需要迁移。

> 将来若要支持"按帧区间"或"轨迹"，可以在 `frame_labels` 之上再加
> `tracks: [{ id, start, end, infos: [...] }]`，向后兼容。

## 4. 帧↔标注绑定策略

前端只持有**当前帧**的一套标注：

```
state.currentVideo       // 当前视频 { name, path, ext, sizeBytes }
state.currentFrame       // 当前帧号 (number)
state.label              // 当前帧的标注集（与图像模式同一个结构）
state.annotatedFrames    // 该视频已标注的帧号列表（时间轴打点用）
```

### 4.1 切帧流程

```
用户拖动 timeline / 上一帧 / 下一帧
  → selectFrame(idx)
    → 切帧前若有 dirty → flushCurrentFrame()（把当前帧写回）
    → loadLabelForFrame(video, idx)
      → 后端 read_video_label 按帧投影出该帧的标注集
      → setState({ label, annotatedFrames })
    → loadAndShowFrame(video, idx)
      → 后端 read_video_frame 抽帧 → data: URL → <img>
```

### 4.2 标注完成 / autosave 流程

```
用户标完一个对象
  → markDirty() → autosave 定时器
    → flushCurrentFrame()
      → serializeLabel(当前帧的 infos / bindings)   // 前端
      → write_video_label { path, frame, content }    // 后端
        → 后端把这一帧的集合替换进整个文档，其余帧原样保留
```

关键点在后端：合并逻辑在 `merge_video_frame_label`，前端不碰文档结构。

### 4.3 "复制到下一帧"

```
click 工具栏"复制到下一帧"
  → 把当前帧的 infos / bindings 浅拷贝
  → write_video_label { path, frame: next, content }   // 写到下一帧
  → selectFrame(next)
```

> 浅拷贝而不是新生成 id——这样下游消费方仍能按 id 跟踪同一物体跨帧的轨迹。
> 但两帧的坐标互相独立：在第 5 帧拖动一个点，不会移动第 9 帧的同一个点。

### 4.4 类别修订（重命名）作用于所有帧

工具菜单的「重命名类别」走后端 `rename_class` op。重写跑在**归一化后的文档**上，
因此顶层默认集和 `frame_labels[*].infos` 都会被改到——视频的每一帧都会跟着改名，
不会出现"默认集改了、某一帧还是旧名字"的分裂。详见 README 的 Features 一节。

## 5. 后端 IPC 契约

| Op                 | Request                                     | Reply                                                        |
|--------------------|---------------------------------------------|--------------------------------------------------------------|
| `list_videos`      | `{ path, extensions? }`                     | `{ folder, videos: VideoEntry[] }`                           |
| `read_video_info`  | `{ path }`                                  | `{ path, durationMs, fps, width, height, frameCount, codec, ok, error, message }` |
| `read_video_frame` | `{ path, frame, quality? }`                 | `{ path, frame, base64, mime, width, height, ok, error, message }` |
| `read_video_label` | `{ path, frame }`                           | `{ path, labelPath, found, content, annotatedFrames, setCount }` |
| `write_video_label`| `{ path, frame, content }`                  | `{ path, labelPath, bytes, setCount }`                       |

`VideoEntry` 字段：

```jsonc
{
  "name": "clip_001.mp4",   // 文件名
  "path": "D:/.../clip_001.mp4",
  "ext": ".mp4",
  "sizeBytes": 12345678     // 用于排序/筛选
}
```

`read_video_label` 的 `content` 是**该帧的投影结果**（一个普通标注文档，
`frames` 固定为 `[frame]`），不是整个视频文档；`annotatedFrames` 是该视频
所有已标注帧号的升序数组；`setCount` 是集合总数（默认集 + 按帧集），仅供诊断。

> 注：本实现 **不缓存**抽帧结果。每次切帧都过 ffmpeg 抽一张 JPG。
> 后续要快可以加 `frame_cache` op + 本地 JPEG 目录缓存。

## 6. ffmpeg / ffprobe 依赖

视频解码走外部工具，**不内置、不自动下载**。缺失时 op 不会抛异常，而是返回
结构化错误，前端据此提示用户：

| `error`       | 含义                                       |
|---------------|--------------------------------------------|
| `tool_not_found` | 找不到 ffmpeg / ffprobe                 |
| `tool_failed`   | 工具跑起来了但失败（退出码非 0 等）     |
| `bad_request`   | 请求本身不合法（例如负帧号）           |

查找顺序（`extensions/labeler/media_tool.mbt`）：

1. 环境变量 `MOONBIT_LABELER_FFMPEG` / `MOONBIT_LABELER_FFPROBE`（指定可执行文件）
2. 环境变量 `MOONBIT_LABELER_FFMPEG_DIR`（指定目录）
3. 常见安装目录（Windows 与 POSIX 各一组）
4. 裸名交给系统 loader 在 `PATH` 上解析

结果缓存在 `Ref[Map[String, String]]` 里，所以一次进程内只探测一次。

## 7. 抽帧命令

```bash
ffmpeg -loglevel error -ss <seconds> -i <video> -frames:v 1 -q:v <q> -y <out.jpg>
```

- `-ss <seconds>`：把帧号换算成秒，`t = frame / fps`；`fps` 来自 ffprobe，探测失败时按 25 处理。
- `-q:v`：JPEG 质量（默认 3，调用方可在 1..31 之间指定）。返回的 base64 mime 固定 `image/jpeg`。
- 临时文件写在系统临时目录（`@fs.tmpdir`），读完立刻删除。

## 8. UI 增量（视频模式）

底部增加 `Timeline 组件`（不替换 statusbar）：

```
[ ◀上一帧 ] [ ▶下一帧 ] [ 00:01.234 / 00:30.000 ] [●━━━○━━━━━━━]
                                                      帧 37/900
[ ⎘ 复制此帧到下一帧 ]   [ ✓ 已标注 8 帧 / 总 900 帧 ]
```

`Timeline` 用 `<input type="range">` 实现就够。文件列表中视频条目带一个
▶ 角标，区分 JPG / PNG / MP4。

## 9. 测试

- `extensions/labeler/video_label_test.mbt` —— 帧隔离、合并语义、旧扁平格式兼容、
  `frame_labels` 在归一化后存活、悬空 binding 被丢弃（15 个）。
- `extensions/labeler/video_op_test.mbt` —— dispatcher 公布了这些 op。
- `tests/stdio/video_stdio_blackbox.test.mjs` —— 通过真实 `--stdio` 桥跑完整链路：
  逐帧隔离、`annotated_frames`、磁盘上的 `frame_labels` 形状。CI 装了 ffmpeg，
  因此带 `--expect-ffmpeg` 参数运行，会额外断言抽帧成功。
