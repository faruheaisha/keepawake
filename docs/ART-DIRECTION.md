# KeepAwake 美术资源体系

生成工具：Codex 内置 `image_gen`，按 imagegen 技能执行。所有输出均复制到项目的 `desktop/assets/`，保留真实透明通道并内嵌桌面 EXE。下面的提示词为实际提交的最终提示词。

| 文件 | 页面与含义 |
| --- | --- |
| `keepawake-dawn.png` | 待机：咖啡与晨光；提示词见 [ICON-PROMPT.md](ICON-PROMPT.md) |
| `keepawake-active.png` | 保护中：清醒的显示器与确认标记 |
| `keepawake-complete.png` | 定时完成：时钟与完成标记 |
| `keepawake-settings.png` | 设置：滑轨与调节旋钮 |
| `keepawake-activity.png` | 活动空状态：等待记录的归档托盘 |
| `keepawake-about.png` | 关于：盾牌、晨光与隐私 |
| `keepawake-focus.png` | 日常工作：阅读书本与书签 |
| `keepawake-presentation.png` | 演示投屏：投影机与演示板 |
| `keepawake-longtask.png` | 长任务：云、服务器与计时 |

同一套象牙白、薄荷绿、柔和金色、瓷质与半透明玻璃材质贯穿页面，但主体随功能变化。小型 SVG 保留导航与操作识别；图片承担场景叙事，不再用重复放大的 SVG 作为装饰。完成插画只在当前定时会话自然结束后出现，重新选择场景或时长会返回准备状态。

原始 PNG 保留 1536 × 1024 分辨率。运行时先准备不超过 512 像素宽的透明纹理，再缓存实际控件尺寸，避免多个高分辨率画面长期占用大块内存或在每帧重复缩放。

## active

```text
Use case: stylized-concept. Asset type: a production transparent illustration for a refined native Windows KeepAwake desktop utility. Style: cohesive premium soft sculptural 3D editorial illustration, porcelain and satin clay with gentle translucent mint glass details, elegant Google Play / Material inspired visual language. Palette: emerald #01875F, pale mint #DDF4E8, sage, warm ivory and one muted butter-gold accent. Lighting: soft warm morning light, delicate ambient shadows, refined sculptural depth. Composition: ONE self-contained centered subject group, landscape 3:2 canvas, generous genuinely transparent margins, all objects fully inside frame, legible at 180–240 px wide, no background tile. No text, letters, numbers, logos, watermark, UI screenshot, icon sheet, busy clutter or bright saturated colors. No haze or shadows extending to the canvas edges.
Primary subject: A compact elegant ivory desktop monitor on a mint sculpted base, with a luminous emerald circular sun and a simple ivory check mark inside its screen. A single soft sage leaf curves beside it; a small warm golden floating orb brings morning energy. Conveys the computer is awake and protection is active. No coffee cup. Not a settings gear.
```

## complete

```text
Use case: stylized-concept. Asset type: a production transparent illustration for a refined native Windows KeepAwake desktop utility. Style: cohesive premium soft sculptural 3D editorial illustration, porcelain and satin clay with gentle translucent mint glass details, elegant Google Play / Material inspired visual language. Palette: emerald #01875F, pale mint #DDF4E8, sage, warm ivory and one muted butter-gold accent. Lighting: soft warm morning light, delicate ambient shadows, refined sculptural depth. Composition: ONE self-contained centered subject group, landscape 3:2 canvas, generous genuinely transparent margins, all objects fully inside frame, legible at 180–240 px wide, no background tile. No text, letters, numbers, logos, watermark, UI screenshot, icon sheet, busy clutter or bright saturated colors. No haze or shadows extending to the canvas edges.
Primary subject: A small satin ivory circular clock with simple emerald hands and no numerals, next to a sculpted translucent mint circle containing a confident ivory check mark, a gentle golden sunrise orb and a single sage leaf. A poised calm completed composition. Conveys a timer has finished and the work is complete. No coffee cup, monitor or settings rail.
```

## settings

```text
Use case: stylized-concept. Asset type: a production transparent illustration for a refined native Windows KeepAwake desktop utility. Style: cohesive premium soft sculptural 3D editorial illustration, porcelain and satin clay with gentle translucent mint glass details, elegant Google Play / Material inspired visual language. Palette: emerald #01875F, pale mint #DDF4E8, sage, warm ivory and one muted butter-gold accent. Lighting: soft warm morning light, delicate ambient shadows, refined sculptural depth. Composition: ONE self-contained centered subject group, landscape 3:2 canvas, generous genuinely transparent margins, all objects fully inside frame, legible at 180–240 px wide, no background tile. No text, letters, numbers, logos, watermark, UI screenshot, icon sheet, busy clutter or bright saturated colors. No haze or shadows extending to the canvas edges.
Primary subject: A refined arrangement of two short rounded ivory slider rails with emerald and mint sculpted knobs, beside a small satin sage settings dial, and a graceful curved leaf. Tactile carefully arranged objects on a small ivory pedestal. Conveys adjusting preferences and finding balance. No monitor, coffee cup, text or screen.
```

## activity

```text
Use case: stylized-concept. Asset type: a production transparent illustration for a refined native Windows KeepAwake desktop utility. Style: cohesive premium soft sculptural 3D editorial illustration, porcelain and satin clay with gentle translucent mint glass details, elegant Google Play / Material inspired visual language. Palette: emerald #01875F, pale mint #DDF4E8, sage, warm ivory and one muted butter-gold accent. Lighting: soft warm morning light, delicate ambient shadows, refined sculptural depth. Composition: ONE self-contained centered subject group, landscape 3:2 canvas, generous genuinely transparent margins, all objects fully inside frame, legible at 180–240 px wide, no background tile. No text, letters, numbers, logos, watermark, UI screenshot, icon sheet, busy clutter or bright saturated colors. No haze or shadows extending to the canvas edges.
Primary subject: A small ivory open archive tray holding two blank rounded mint record cards with sculpted embossed lines (not writing), one folded ivory page resting beside it and a single softly curling sage leaf. A small warm golden orb above. Conveys an elegant quiet history awaiting its first record. No coffee, monitor or gear.
```

## about

```text
Use case: stylized-concept. Asset type: a production transparent illustration for a refined native Windows KeepAwake desktop utility. Style: cohesive premium soft sculptural 3D editorial illustration, porcelain and satin clay with gentle translucent mint glass details, elegant Google Play / Material inspired visual language. Palette: emerald #01875F, pale mint #DDF4E8, sage, warm ivory and one muted butter-gold accent. Lighting: soft warm morning light, delicate ambient shadows, refined sculptural depth. Composition: ONE self-contained centered subject group, landscape 3:2 canvas, generous genuinely transparent margins, all objects fully inside frame, legible at 180–240 px wide, no background tile. No text, letters, numbers, logos, watermark, UI screenshot, icon sheet, busy clutter or bright saturated colors. No haze or shadows extending to the canvas edges.
Primary subject: An elegant sculpted ivory protective shield standing on a small rounded emerald plinth, with a translucent pale mint sunrise disc behind it and two graceful sage leaves curving around its base. A single restrained warm gold sun accent. Conveys care, privacy and a trustworthy desktop utility. No coffee cup, screen, text, lock or gear.
```

## focus

```text
Use case: stylized-concept. Asset type: production transparent artwork for a scenario card in the native Windows KeepAwake app. One coherent, elegant soft 3D sculptural miniature with porcelain, satin clay and restrained translucent mint glass, refined morning light, gentle ambient shadows and clean object edges. Google Play / Material inspired palette of emerald #01875F, mint #DDF4E8, sage, warm ivory and muted butter-gold. One small muted blue accent is allowed for the presentation scene. Landscape 3:2 canvas, genuinely transparent background, all objects fully inside generous transparent margins. A strong readable silhouette at 110 px wide, no text, letters, numerals, logo, watermark, UI screenshot, dark background, icon grid, haze at edges or busy clutter.
Primary subject: A small open ivory book with gently curved sculpted pages, an elegant emerald ribbon bookmark and one delicate sage leaf beside it. A calm golden morning orb above the book. Conveys focused reading and desk work. No monitor or coffee cup.
```

## presentation

```text
Use case: stylized-concept. Asset type: production transparent artwork for a scenario card in the native Windows KeepAwake app. One coherent, elegant soft 3D sculptural miniature with porcelain, satin clay and restrained translucent mint glass, refined morning light, gentle ambient shadows and clean object edges. Google Play / Material inspired palette of emerald #01875F, mint #DDF4E8, sage, warm ivory and muted butter-gold. One small muted blue accent is allowed for the presentation scene. Landscape 3:2 canvas, genuinely transparent background, all objects fully inside generous transparent margins. A strong readable silhouette at 110 px wide, no text, letters, numerals, logo, watermark, UI screenshot, dark background, icon grid, haze at edges or busy clutter.
Primary subject: A compact ivory tabletop projector with a rounded mint lens, beside a floating rounded pale mint presentation board displaying a simple sculptural cornflower-blue rising chart without labels or text. One small golden orb accent. Conveys a presentation being shared. No check mark or coffee cup.
```

## longtask

```text
Use case: stylized-concept. Asset type: production transparent artwork for a scenario card in the native Windows KeepAwake app. One coherent, elegant soft 3D sculptural miniature with porcelain, satin clay and restrained translucent mint glass, refined morning light, gentle ambient shadows and clean object edges. Google Play / Material inspired palette of emerald #01875F, mint #DDF4E8, sage, warm ivory and muted butter-gold. One small muted blue accent is allowed for the presentation scene. Landscape 3:2 canvas, genuinely transparent background, all objects fully inside generous transparent margins. A strong readable silhouette at 110 px wide, no text, letters, numerals, logo, watermark, UI screenshot, dark background, icon grid, haze at edges or busy clutter.
Primary subject: Two short rounded ivory server blocks with subtle mint indicator lights underneath a sculpted translucent mint cloud, beside a tiny warm gold clock with no numerals and one soft sage leaf. Conveys a long background download or compute task. No monitor, book, check mark or coffee cup.
```
