# 交接说明：文件夹浏览器、旗标与文件夹记录（feature/folder-library）

> 开发用的交接文档。向上游提交 PR 前删除本文件和 `.github/workflows/folder-library.yml`。

## 目标

把 SpektraLab macOS 版的照片管理从"一次性导入、关掉就忘"改成按文件夹管理：

1. 软件里有一个文件夹浏览器，点文件夹就显示其中所有照片。
2. 用旗标（留用 / 排除）选片，并按旗标筛选。
3. 编辑、导出。
4. 在照片文件夹里生成一个记录文件，记下所有选片和编辑；下次打开软件选这个文件夹时自动恢复。

## 仓库与分支

- fork：`https://github.com/Broksd/SpektraLab`，上游：`JamesQiu2005/SpektraLab`（macOS 版在 `main`）
- 分支：`feature/folder-library`，基于上游 `main` 的 `213741f`（1.3.6 (21)）
- 提交（从旧到新）：
  1. `3cc7e59` 文件夹记录文件（FolderRecord）+ 接入 Sidecar / FrameOrder + 设置开关
  2. `17289f4` 旗标、筛选、重新打开文件夹时恢复状态 + 测试
  3. `c522a88` 左侧文件夹浏览器
  4. `17a7adf` 文档（ARCHITECTURE / AGENTS / README 中英文）
  5. `8c134c8` CI：GitHub 托管 Mac 上编译和测试（仅开发用）
  6. `afe6df1` 修复：图库菜单拆成独立的 `LibraryCommands`
  7. `5de8ffc` CI：改进错误汇报（仅开发用）

## 当前状态

- **代码在 Linux 云端写成，从未在 Mac 上完整编译通过。**
- `Spektrafilm.xcodeproj/project.pbxproj` **还没重新生成**，新文件不在工程里。本地必须先运行 `Tools/gen-project.py`，生成后的 pbxproj 要一起提交。
- GitHub CI（`.github/workflows/folder-library.yml`）情况：
  - 第 1 次：编译错误 `SpektrafilmApp.swift:289 extra argument in call`。原因是 `EditorCommands` 原本已有 10 个菜单组，加上图库菜单超过了 `CommandsBuilder` 的上限。已在 `afe6df1` 修复。
  - 第 2 次：失败，退出码 65，但汇报步骤有 bug，没拿到具体错误。从退出码看，可能是程序已编译通过、失败出在测试阶段，尚未确认。
  - 第 3 次（`5de8ffc`）：**程序编译通过**；新测试 11 个里 10 个通过，1 个失败：`testARecordRoundTripsAndToleratesMissingFields` 用 `==` 比较整条记录，但 ISO 8601 日期会丢掉秒的小数部分，Sidecar 的编解码也不是完全对等。之后已改成逐字段比较。完整测试套件这次没跑完（被下一次推送取消），还需要在本地跑一遍。

## 改动的文件

| 文件 | 内容 |
|---|---|
| `modern_UI/Spektrafilm/Spektrafilm/Model/FolderRecord.swift`（新） | `FrameFlag`、`FlagFilter`、`FolderRecord`（JSON 结构）、`FolderRecordStore`（读写、缓存、按文件修改时间失效） |
| `.../Model/Sidecar.swift` | `save` 时同步写入文件夹记录；`load` 比较应用存储和文件夹记录，用较新的一份，并把文件夹里的那份写回应用存储；`remove` 同步清除 |
| `.../Model/FrameOrder.swift` | 拖动排序同时写入记录；本机没有排序时用记录里的 |
| `.../Model/Session.swift` | `libraryFolder`、`flags`、`flagFilter`、`visibleFrames`、`toggleFlag` / `setFlag`、`restoreFolderRecord`、`rememberOpenFrame`、`browserCollapsed` / `showsFolderBrowser`；`open(urls:)` 恢复记录；方向键和 ⌘A 按筛选结果工作 |
| `.../Panels/FolderBrowser.swift`（新） | `FolderTree`（根：个人文件夹、图片、已挂载卷、用户添加的文件夹；展开时才读取）、`FolderBrowser`、`FlagFilterList` |
| `.../Panels/Filmstrip.swift` | 显示 `visibleFrames`；旗标角标、排除变暗；右键菜单设置旗标；"没有符合筛选条件的照片"提示 |
| `.../Windows/EditorWindow.swift` | 最左侧加浏览器栏（可拖宽，`editor.browser`） |
| `.../Windows/TopBar.swift`、`.../Panels/LeftPanel.swift` | 浏览器打开时由它的标题栏为窗口红绿灯按钮留位 |
| `.../SpektrafilmApp.swift` | `LibraryCommands`：⇧⌘L 显示或隐藏浏览器，P / X / U，⌥⌘1–4 筛选 |
| `.../Windows/SettingsWindow.swift` | 设置 → 通用 → 图库："在每个文件夹中保存记录"（`library.folderRecord`，默认开） |
| `modern_UI/Spektrafilm/SpektrafilmTests/FolderRecordTests.swift`（新） | 记录读写、历史合并、旗标与筛选恢复、P/X 开关、⌘A、跨存储读取、新旧比较、重置保留旗标、排序、关闭开关 |
| `ARCHITECTURE.md`、`AGENTS.md`、`README.md`、`README.zh-CN.md` | 文档 |

## 记录文件格式（`SpektraLab.folder.json`）

```json
{
  "format": "spektralab.folder",
  "version": 1,
  "updated": "2026-11-07T10:00:00Z",
  "filter": "all",
  "current": "DSC_0417.NEF",
  "order": ["DSC_0417.NEF", "DSC_0412.NEF"],
  "photos": {
    "DSC_0417.NEF": { "flag": "flagged", "edited": "…", "sidecar": { "…": "完整的 Sidecar，不含 source" } }
  },
  "history": [{ "time": "…", "file": "DSC_0417.NEF", "action": "flag" }]
}
```

- `flag`：`flagged` 或 `rejected`，没有这个字段表示未标记。
- `sidecar`：包含白平衡、胶片和相纸参数、调色、裁剪等全部编辑。
- 照片按文件名对应，所以移动或复制文件夹后记录仍然有效。
- `history` 最多 2000 条；对同一张照片 2 分钟内的连续编辑合并成一条。

## 设计决定（已确认或需要知道的）

- 这是对 AGENTS.md trap 35"sidecar 不放在照片旁边"的例外：默认开启，可以在设置里关闭。应用自身的存储照常写入。
- 在 XCTest 下默认关闭，测试需要时调用 `FolderRecordStore.useForTests(true)` 打开。
- 只打开文件夹不会生成记录；第一次打旗标或编辑时才会创建。
- 半格拼接（`.spektrapair`）不进文件夹记录。
- 截图测试模式（`snapshotPanelWidths`）下不显示文件夹浏览器。
- 不保存撤销历史和导出记录。

## 本地接下来要做的

```bash
cd ~/SpektraLab-test        # 或者你 clone 到的位置
git pull
xcodebuild -version
xcrun -sdk macosx metal --version || xcodebuild -downloadComponent MetalToolchain
engine/build.sh bundle
cd modern_UI/Spektrafilm
python3 Tools/gen-project.py
xcodebuild -project Spektrafilm.xcodeproj -scheme Spektrafilm -configuration Debug -derivedDataPath build/DerivedData build
xcodebuild -project Spektrafilm.xcodeproj -scheme SpektrafilmTests -configuration Debug -derivedDataPath build/DerivedData test -only-testing:SpektrafilmTests/FolderRecordTests
xcodebuild -project Spektrafilm.xcodeproj -scheme SpektrafilmTests -configuration Debug -derivedDataPath build/DerivedData test
open build/DerivedData/Build/Products/Debug/SpektraLab.app
```

1. 修完所有编译错误和测试失败，把重新生成的 `project.pbxproj` 一起提交，推到 `feature/folder-library`。
2. 完整测试在没有相机样本时约有 25 个用例会跳过（AGENTS.md trap 26），属于正常情况。
3. 用**复制出来的**照片文件夹手动测试：
   1. 文件夹浏览器能显示，点文件夹后胶片条出现照片（看不到就按 ⇧⌘L）；
   2. P / X / U 打旗标，角标和变暗正确，再按一次 P 或 X 会取消；
   3. 筛选和张数正确；筛选后 ⌘A 再 ⌘E 只导出筛选出的照片；
   4. 编辑后文件夹里出现 `SpektraLab.folder.json`；
   5. ⌘Q 退出再打开同一个文件夹，旗标、筛选、上次那张照片和编辑参数都能恢复；
   6. 移动整个文件夹后再打开，记录仍然有效；
   7. 在设置里关掉开关后，新文件夹里不再生成记录。
4. 向上游提交前：删除本文件和 `.github/workflows/folder-library.yml`；按上游规则，每个提交只做一件事，并在提交信息里写明跑过了哪些测试。上游的 macOS 改动 PR 提到 `main`。

## 界面示意

https://claude.ai/artifact/KFB3AKt4p5LnzjSfMpn8fx （网页示意，不是真实截图）
