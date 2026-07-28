# MoonBit Labeler

> 一个轻量、纯本地的图像标注工具，基于 [MoonBit](https://www.moonbitlang.com/) + [Proton](https://github.com/jiaqiyuan/proton-runtime) 桌面架构。
>
> 原型参考自 MOlabeler（X 光安检图像标注软件），并向 *股骨图像标注软件 v1.0.1.3* 的特性集演进。

支持四种标注形态：**矩形 / 多边形 / 关键点 / 关联**（binding：两个物体间画一条质心连线）。
标签数据存为自定义 JSON，向后兼容已有的 `Image@X/<basename>.jpg` ↔ `Label@X/<basename>.json` 双文件夹布局。

---

## 核心特性

- 🟢 **纯本地** — 所有数据存在本机文件夹，没有任何云端依赖
- 📦 **单文件便携 exe** — `proton_cli package app` 出来的目录自带 `proton.dll` / `libcef.dll`，无需安装
- ⚡ **快速标注** — 1–9 数字键直接选中前 9 个类，回车闭合多边形，Ctrl+Z 撤销
- 🧠 **自动类别发现** — 扫 `Label@<name>/` 下的所有 JSON，按出现频次排序展示
- 🔒 **opaque-origin 兼容** — Proton 把页面当 `proton://app/` 的 opaque origin 处理，CORS 限制靠 **Vite post-build inline 插件**把 JS/CSS 嵌进单个 `index.html` 绕过
- 🔎 **BOM 容错** — 老 CARS 数据集用 UTF-8 BOM 写 JSON，解析时自动剥离

---

## 架构

```
moonbit_labeler/
├── app/main.mbt              ← @proton.config("moon.proton").extension(...)
├── extensions/labeler/
│   └── labeler.mbt           ← 8 个 IPC 操作：list_images/read_image/read_text/
│                                write_text/read_label/write_label/pick_folder/
│                                scan_classes
├── frontend/
│   ├── index.html
│   ├── src/
│   │   ├── main.js           ← 状态机、IPC、autosave、键盘快捷键
│   │   ├── canvas.js         ← SVG overlay + 鼠标事件
│   │   ├── label.js          ← 标签 JSON 解析 / 序列化 / 标准化
│   │   └── style.css         ← UI 样式
│   └── vite.config.js        ← inlineEntryAssetsPlugin（post-build 内联资源）
├── moon.proton               ← 窗口配置、bundle targets
└── data/                     ← .gitignore 掉的运行时数据
    ├── Image@<name>/         ← 原始图片
    └── Label@<name>/         ← 对应 JSON
```

---

## 快速上手

### 1. 准备运行时

```sh
moon update
proton_cli cef setup    # 一次性下载 ~150MB Chromium 内核
```

### 2. 跑起来（开发模式）

```sh
proton_cli dev
```

`dev` 启动 Vite + Proton + CEF，自动打开桌面窗口。

### 3. 打便携包

```sh
proton_cli package app
# → target/proton-dist/moonbit-labeler/moonbit-labeler.exe
```

整个目录就是可发版的可执行 bundle，发给同事双击即跑。

---

## 数据格式

### 文件夹布局

```
<project>/
├── Image@CARS.Part.01/
│   ├── 1800003_0.jpg
│   ├── 1834694_0.jpg
│   └── ...
└── Label@CARS.Part.01/
    ├── 1800003_0.json
    ├── 1834694_0.json
    └── ...
```

> 文件名约定：`Image@X/<basename>.<ext>` ↔ `Label@X/<stem>.json`
> 其中 `<basename>` 可能带 `_0` 这种 index 后缀，写标签时会自动剥离。

### JSON 标签格式

```json
{
  "img_name": "1800003_0.jpg",
  "infos": [
    {
      "id": "obj_abc1234",
      "shape": "rect",
      "type": "scissors",
      "points": [[14, 230], [120, 350]]
    }
  ],
  "bindings": [
    {
      "id": "b_def5678",
      "from": "obj_abc1234",
      "to": "obj_ghi9012",
      "type": "same_group"
    }
  ]
}
```

`shape` 必须是 `rect` / `polygon` / `keypoint`；`points` 是 `[[x, y], ...]` 的内嵌数组（也兼容旧的 `x,y;x,y;...` 字符串）。
`bindings` 是顶层数组，存的是物体对之间的关联（运行时画连线）。

---

## IPC 接口

全部以 `ext:labeler/<op>` 调用，返回 JSON：

| Op              | 入参                          | 出参                                                   |
|-----------------|-------------------------------|--------------------------------------------------------|
| `list_images`   | `{ path }`                    | `{ folder, images: [{name, path, ext}] }`              |
| `read_image`    | `{ path }`                    | `{ path, base64, mime }`                                |
| `read_label`    | `{ image_path }`              | `{ image_path, label_path, content, found }`           |
| `write_label`   | `{ image_path, content }`     | `{ image_path, label_path, bytes }`                     |
| `scan_classes`  | `{ image_path }`              | `{ label_dir, classes: [{name, count}] }`              |
| `pick_folder`   | `{ title, initial? }`         | `{ path, cancelled }`                                   |
| `read_text`     | `{ path }`                    | `{ path, content, found }`                              |
| `write_text`    | `{ path, content }`           | `{ path, bytes }`                                       |

---

## 调试小贴士

- 后端扫描流程：日志写在 `C:\Windows\Temp\moonbit-labeler-scan-classes.log`
- 文件选择对话框日志：`C:\Windows\Temp\moonbit-labeler-pick-folder.log`
- CEF 浏览器侧按 **F12** 打开 DevTools
- `proton_cli dev` 时 Vite 用 127.0.0.1:5173，Proton 通过 `proton://app/` 加载页面

---

## License

Apache-2.0（继承自脚手架默认）。
