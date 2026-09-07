# NAI CasRand Forge

NAI CasRand Forge 是 [NAI CasRand](https://github.com/Exception0x0194/NAI-Generator-Flutter) 的社区跨平台 Fork。项目保留原有的级联随机 Prompt 与 NovelAI 图像生成能力，并持续完善 macOS、Windows 和 Android 支持。

## 下载与平台状态

| 平台 | 状态 | 获取方式 |
| --- | --- | --- |
| macOS | 0.9.6 正式版 build 88，支持 Apple Silicon 与 Intel | 从 [GitHub Releases](https://github.com/khkjdfkjhdsfakhds/CasRand-Forge/releases) 下载 DMG |
| Windows | 0.9.6 正式版 build 88 | 从 0.9.6 Release 下载 Windows ZIP |
| Android | 0.9.6 正式版 build 88 | 从 0.9.6 Release 下载 APK |

macOS 用户推荐下载 DMG，将 App 拖入“应用程序”。本项目的公开 macOS 构建使用临时签名且尚未经过 Apple 公证；首次打开时若 macOS 提示无法验证开发者，请在 Finder 中右键应用并选择“打开”。Windows 用户解压完整 ZIP 后运行 `NAICasRandForge.exe`。Android 0.9.5 起使用固定发布签名，后续若签名变化，可能需要先卸载旧 Beta 再安装新版。

0.9.6（build 88）冻结为 NovelAI V4.5 的最后稳定基线，也是后续 NovelAI V5 适配的起点。成品继续沿用既有应用标识；软件名称为 NAI CasRand Forge，以延续配置和覆盖升级兼容性。

本 Fork 使用独立的应用标识；macOS Beta 也能与稳定版及原版并存。详细版本演进与改动历史请参见 [更新日志 (CHANGELOG.md)](CHANGELOG.md)。GitHub Release 标签同时提供自动生成的源码 ZIP 和 TAR。

## 简介

NAI CasRand Forge 是一个按照指定模式生成随机提示词（prompt），并将其和其他生成参数发送至 API 以获取生成图片的软件。对于不同种类的需求，如：

- 我想从很多喜欢的风格中找到/统计出一个最合适的搭配；
- 我想得到某个/某些角色在不同场景下的图片；
- 不说没用的哥们就是想要各种姿势的涩图🥵

在合适的设置下，NAI CasRand Forge 可以满足上述需求。

### 界面展示

| 图像生成                | 提示词设置              |
| ----------------------- | ----------------------- |
| ![](docs/imgs/0001.jpg) | ![](docs/imgs/0002.jpg) |

| I2I / Vibe Transfer 设置 | Director Tools          | 生成参数和用户选项      |
| ------------------------ | ----------------------- | ----------------------- |
| ![](docs/imgs/0003.jpg)  | ![](docs/imgs/0005.jpg) | ![](docs/imgs/0004.jpg) |

<!-- 
<style>
.grid-container {
    display: grid;
    grid-template-columns: repeat(2, 1fr);
    gap: 5px;
    text-align: center;
    margin-left: 20px;
}

.grid-container .grid-element {
    display: grid;
    grid-template-rows: repeat(2, auto);
    margin-right: -6px;
    gap: 5px;
    border: 1px solid gray; 
}
</style>

<div class="grid-container">
    <div class="grid-element">
        <span>图像生成界面</span>
        <img src="docs/imgs/0001.jpg"/>
    </div>
    <div class="grid-element">
        <span>提示词设置界面</span>
        <img src="docs/imgs/0002.jpg"/>
    </div>
    <div class="grid-element">
        <span>I2I / Vibe Transfer 设置界面</span>
        <img src="docs/imgs/0003.jpg"/>
    </div>
    <div class="grid-element">
        <span>Director Tools 界面</span>
        <img src="docs/imgs/0005.jpg"/>
    </div>
    <div class="grid-element">
        <span>生成参数和用户选项界面</span>
        <img src="docs/imgs/0004.jpg"/>
    </div>
</div>
-->

## 相对原版的新增功能说明

以下功能在原版 NAI CasRand 0.9.1 中不存在、或与原版用法差别较大，使用前建议先阅读对应说明。图生图等基础概念不做重复介绍。

### 双提示词方案：随机提示词 / 固定提示词

原版只有简单的「覆盖随机 prompts」：用一段文字直接盖掉随机生成结果。Forge 将其升级为两套完全独立的完整配置：

- **随机提示词**：保留原版的级联随机生成方式。
- **固定提示词**：手动输入正面、负面和可选角色提示词，不参与随机抽取。

两套方案各自拥有完整的生成配置（Prompt 元数据、角色、已保存 Prompt、模型、尺寸、steps、采样器、seed 模式与值等），任何一边的修改都不会写入另一边。导入 NovelAI 官网图片的 metadata，或把图片送入 Enhance 时，会自动把可用参数写入固定方案并切换到固定模式（原随机配置原样保留）；手动切换模式有确认提示，可勾选「后续不再提示」，软件选项中可重新开启确认。

### 级联负面内容（Negative Prompt）

原版只在生成页提供简单的反向提示词输入。Forge 的负面内容升级为与正面提示词同级、可级联的完整配置：支持随机、顺序遍历（轮询）、指定数量 / 概率、嵌套、变量替换、括号权重和 `|||` 语法，与 Base Prompt、Character Prompt 分区管理。

### Precise Reference

上传一张或多张参考图，选择参考类型（角色 / 风格 / 角色与风格），并分别调整 Strength（强度）与 Fidelity（保真度）。仅在 V4.5 模型生成时启用；与 Vibe Transfer 互斥（开启一方会关闭另一方，但不会删除已导入资源），可与图生图同时使用。每张生成图片额外消耗 5 Anlas，界面会先给出预估。与官网结果肉眼基本一致，但因参考图处理细节不同，不保证逐像素完全相同。

### 多 API Token 并发

软件选项 → 多 Token 管理可以添加多个 NovelAI 账号（最多同时启用 6 个），支持重命名、排序（顺序即派发优先级）、启停、脱敏显示和单独查询余额。生成时多个账号并行请求；某个账号失败时任务回到队列由其他账号重试，连续失败只暂停该账号当前批次。停止生成立即禁止新任务并取消等待，但会等在途请求结算后再收尾。每个账号按自己的生成间隔独立运行。

### 生成数量与生成间隔

原版按旧批次逻辑一次生成固定数量。Forge 改为逐张控制：「生成数量」为 `0` 时无限生成直到手动停止；「生成间隔」控制每张之间的等待时间（`0` 表示不等待）。失败自动重试后仍按间隔继续，适合长时间批量「roll 图」。

### 结果画廊与桌面文件集成

结果详情升级为画廊：左右方向键、图片两侧按钮和横向滑动都可以切换相邻结果，AppBar 显示当前位置；退出后自动定位回最后查看的图片。点击图片进入全屏查看器（支持 1–8 倍缩放拖动，空格键放大 / 退出，Esc 返回）。

桌面端（macOS / Windows）还支持把结果直接拖到 Finder 或其他应用、右键复制原始 PNG、在 Finder 中显示；拖拽与复制使用磁盘原始 PNG，不重新编码，保留 NovelAI metadata。

### NovelAI metadata 导入增强

原版已支持把官网图片拖入恢复参数，Forge 统一并增强了恢复逻辑：可恢复 seed、完整 prompt、`use_coords` 以及隐藏采样兼容参数（`deliberate_euler_ancestral_bug`、`prefer_brownian` 等），并把恢复结果写入固定提示词方案、自动切换到固定模式。手动修改模型、采样器或噪声计划后，相应的导入兼容值会被清除，避免旧参数误用。

### Anlas 点数预估与余额显示

文生图、图生图、局部重绘、Enhance 和 Director Tools 在请求前都会按实际尺寸 / 计划给出点数预估，生成后显示本次实际消耗与账号剩余 Anlas。订阅状态会自动刷新：只有普通文生图可能使用有效 Opus 的免费窗口，图生图、局部重绘、Enhance 和 Director Tools 按付费计算。多 Token 时每个账号独立显示余额，单个慢账号不会阻塞其他账号更新。

### 自适应导航与设置功能目录

顶层导航共 7 个区域：图片生成、生成参数、图生图 / 局部重绘、Vibe Transfer / Precise Reference、Enhance、Director Tools、软件选项。

软件选项 → 设置功能目录用一张统一列表管理全部入口：图片生成、生成参数、设置三个必备入口不可关闭但可拖动排序；图生图 / 局部重绘、Vibe Transfer / Precise Reference、Enhance、Director Tools 四个可选入口可独立开关常驻、拖动排序，关闭后重新开启会回到原顺序位置。点击功能名称可以「临时打开」该功能页而不改变常驻状态，退出后回到设置页并恢复滚动位置。新安装默认只常驻三个必备入口，高级功能从功能目录临时打开或按需开启。

### 恢复初始设置

软件选项 → 保存的配置 → 恢复初始设置可以一键回到初始配置（含默认质量词与负面词），并可选先备份当前活动配置；不会删除或覆盖已保存的配置存档，同时会重置 I2I、Vibe Transfer 等未保存在存档中的临时状态。

### Vibe Transfer 新工作流

原版需要 `.naiv4vibe` / 嵌入 vibe 的 PNG 等专用参考文件。Forge 对齐当前 NovelAI 官网：普通 PNG / JPG / JPEG / WebP 可直接作为参考图导入，生成时按需调用官方提取接口，每张未缓存图片消耗 2 Anlas。Reference Strength 与 Information Extracted 可分别调整；提取结果按模型和 Information Extracted 缓存，并发请求会合并，避免重复扣费。

### 图生图高级能力：Focus Inpainting 与蒙版分块

（基础图生图概念不在此说明）Forge 的局部重绘按官网 Focus Inpainting 语义实现：绘制蒙版后以蒙版为中心自动选择上下文框重绘，再按原坐标回贴，框外像素保持原图（可关闭「保留未蒙版区域原图」）。大蒙版无法放入单个 Focus 框时会自动拆成多个重绘块（重叠块串行、互不重叠可并发），最后合成为一张结果。支持手动 Focus 框直接指定重绘范围，以及 Alpha / 亮度通道、阈值、反相、替换或合并的蒙版导入（桌面端还可从剪贴板粘贴）；分块按实际请求块数消耗 Anlas，生成前会给出合计预估。

## 快速上手

### 生成图片和保存/读取配置

- **填写 Token**

    在使用现有的设置开始生成图片前，应当在 `参数设置` 页面填写使用的 API Token。如果没有填写 API Token，或填写了错误的 Token，在生成图片时将会收到 `Unauthorized` 错误。

    - NAI 使用的 API Token 可以在 `主页 → 设置 → Account → Get Persistent API Token` 找到。

- **生成图片**

    在 `图像生成` 页面可以控制生成图片并浏览生成结果。点击开始按钮即可按照设置的模式生成随机 prompts，交由 API 生成图片；点击停止按钮即可停止生成。生成的图片将被下载（Web 端），或被保存到相册（安卓端）。
    
    在页面的设置菜单中，也可以对页面显示内容、每次生成的图片数量等参数进行设置。

- **保存/读取配置**

    在 `参数设置` 页面，点击保存按钮即可将当前设置保存为 json 文件；点击导入按钮即可读取先前保存的设置。

    - 导出的 JSON 文件可以在各个平台上使用，因此可以在 PC 上经 Web 端对配置进行详细编辑，再导出到手机端进行高强度 roll 图。 

### Prompts 设置

- **设置参数**

    NAI CasRand Forge 由级联的配置定义随机抽取的模式和内容。每一项 prompt 设置（`Config`）都具有多个可设置的内容，包括：

    | 属性           | 作用                                                              | 内容                                                 |
    | -------------- | ----------------------------------------------------------------- | ---------------------------------------------------- |
    | `选取方式`     | 指示选取下属内容的方式                                            | `单个（随机/顺序）`、`多个（指定数量/概率）`、`全部` |
    | `打乱顺序`     | 在选取方式为`多个-指定概率`或`全部`时，指定是否打乱选中内容的顺序 | `是`、`否`                                           |
    | `选中数量`     | 在选取方式为`多个-指定数量`时，指定选中的数量                     | 任意整数（应当不大于下属设置长度）                   |
    | `选中概率`     | 在选取方式为`多个-指定概率`时，指定选中的概率                     | 任意浮点数（应当在 0~1 之间）                        |
    | `随机括号数量` | 对每个选中的配置，添加指定范围内数量的括号，从而调整权重大小      | 两个整数，分别代表用括号修改权重的上下限             |
    | `下属设置类型` | 指定下属的设置类型：直接选取字符串，或指定进一步的抽取模式        | `字符串内容`、`嵌套 Config`                          |
    | `下属设置内容` | 下属设置的内容                                                    | 字符串内容，每行一个；或者一个配置列表               |


    - 当选取方式为 `单个-顺序遍历（轮询）` 时，每个 `Config` 都会按照各自的计数器从开头向最后遍历内容，并在到达末尾时回到开头重新开始遍历。因此，在有多个单个遍历的 `Config` 的场合，可能会出现某些内容组合永远不会出现的情况。
    - “跑完全部组合”的数量计算中，`单个-随机`（包括嵌套 Config）只按一次选择处理，不把随机候选项相加；`单个-顺序遍历（轮询）` 才会按候选项或子组合数量展开。因此该功能不会承诺随机候选项全部出现。
    - 当字符串内容由 `|||`（三个竖杠）分隔时，软件会将字符串按照分隔符分为两部分，并将前部分添加到当前 prompt 的开头，将后一部分添加到 prompt 的末尾，从而实现在一段 prompts 中间插入额外内容的功能。
    - 可以在生成页面的设置中生成 prompt（而不生成图片），对现有设置进行预览和调试。

- **默认设置**

    在每次启动时，NAI CasRand Forge 将读取一个较简单的默认 prompt 生成配置。

<div style="margin-left: 40px;"><details>

<summary> 对默认配置含义和作用的解释 </summary>


- **示例提示词**

    `示例提示词`是最外层的 config，后续的 config 都是它的子设置。它将选取下属的所有 config（因为`选取方法`是`全部`），并将它们顺序（因为`打乱次序`是`禁用`）地拼接在一起，得到所需的正向提示词。

    - **角色**

        作用：随机选择一个角色。

        说明：`角色`这一 config 从下属的字符串中随机选择一个（因为`选取方法`是`单个 - 随机选择`）作为给出的结果。

    - **画师**

        作用：随机选择 4 个画师，并给每个画师随机添加 0~2 个括号。

        说明：`画师`这一 config 从下属的字符串中随机选择 4 个（因为`选取方法`是`多个 - 指定数量`，且`选中数量`是`4`），并对每个字符串随机添加 0~2 个权重括号（因为`随机括号数量`是`2`），作为给出的结果。

    - **特殊风格**

        作用：按照 3% 的概率，向画面中添加特殊风格，如线稿、3D模型等。

        说明：`特殊风格`这一 config 按照 3% 的概率抽取下属的字符串（因为因为`选取方法`是`多个 - 指定概率`，且`选中概率`是`0.03`），作为给出的结果。

    - **前缀** 

        作用：必须是萝莉🤤

        说明：`前缀`这一 config 选取下属的所有字符串，并将它们顺序地拼接在一起，作为给出的结果。

    - **内容**

        作用：给角色随机选择一个动作/场景。

        说明：`内容` 这一 config 从下属的字符串中随机选择一个字符串作为给出的结果。

    - **背景**

        作用：使用一个统一的背景。

        说明：`背景` 这一 config 选取下属的所有字符串，并将它们顺序地拼接在一起，作为给出的结果。

    - **质量**

        作用：叠 buff。

        说明：`质量` 这一 config 选取下属的所有字符串，并将它们顺序地拼接在一起，作为给出的结果。

</details></div>

## 开源许可与致谢

NAI CasRand Forge 继承原项目的 [GNU GPL-3.0](LICENSE) 许可。原项目由 [Exception0x0194](https://github.com/Exception0x0194) 开发；本 Fork 保留原许可证、版权与权利说明。NovelAI 是 Anlatan 的商标，本项目与 NovelAI/Anlatan 没有官方隶属关系。

## 支持作者

☕ 请作者喝杯咖。。。<br>
不，还是接济点 token 钱吧，实在太烧了。。

<p align="center">
  <img src="assets/donation/wechat-pay.png" alt="微信支付收款码" width="320">
  <img src="assets/donation/alipay.jpg" alt="支付宝收款码" width="320">
</p>
