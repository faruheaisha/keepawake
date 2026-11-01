# KeepAwake 品牌与晨光插画

生成工具：Codex 内置 `image_gen`，按 imagegen 技能工作流执行。不是界面截图生成；实际界面由原生 WinForms 绘制。

最终图像：`desktop/assets/keepawake-brand.png`，1280×1280，透明背景。桌面图标：`desktop/assets/keepawake.ico`。ICO 只进行保留透明度的尺寸转换，未更改设计。

## 晨光状态卡插画

使用内置 `image_gen` 生成；最终素材保存为 `desktop/assets/keepawake-dawn.png`，1536×1024，保留 Alpha 透明通道。作为原生 GUI 的装饰素材使用，原有品牌图与 ICO 保持不变。以下为最终生成提示词：

Use case: stylized-concept
Asset type: transparent decorative illustration for the status card of an existing native Windows KeepAwake app.
Primary request: a premium, understated illustration that adds visual warmth to an elegant Google Play / Material inspired mint-green desktop app.
Subject: a small ivory ceramic coffee cup and saucer in the foreground, gently rising steam, a rounded abstract emerald sunrise disc behind it, one soft mint ribbon-like leaf and a small warm gold sun accent. A single cohesive still-life, not an icon sheet.
Style/medium: refined soft 3D clay and porcelain with lightly sculpted shapes, believable soft ambient lighting and subtle shadows, polished editorial app illustration.
Composition/framing: landscape 3:2 composition, self-contained compact group centered, all shapes fully inside the canvas with generous transparent margin. Designed to remain readable at 220 x 145 pixels. No background rectangle or tile.
Color palette: emerald #01875F, sage, pale mint #DDF4E8, warm ivory, small muted butter-yellow accents. Avoid saturated blue or purple.
Lighting/mood: quiet morning energy, soft warm light from upper left, delicate depth, gentle and calm.
Text: none.
Constraints: genuine transparent background; no typography, no UI, no logos, no watermark, no photorealistic clutter, no border, no gradients extending outside the object group. Preserve the existing app's calm light-green character.

## 品牌图标最终生成提示词

Use case: logo-brand. Asset type: production Windows desktop application icon for KeepAwake, a utility that keeps a computer awake during work. Create ONE square app icon, not a presentation or icon grid. Elegant Google Play / Material visual language, original artwork. A rich emerald green rounded-square tile with generous smoothly curved corners, containing a bold warm ivory coffee cup with a simple handle and a rising sun / awake halo in golden yellow behind the cup. Restrained flat vector-like shapes with a very subtle layered paper shadow; premium, clean, warm, legible at 16px, 32px, 48px and 256px. Centered composition, the tile occupies about 88% of the square canvas. Use emerald #01875F, mint #DDF4E8, ivory #FFFDF6 and a small warm yellow #F8C65B accent. Strong silhouette, wide clear shapes, no fine details. Transparent outside the rounded tile, genuine alpha. No text, no letters, no watermark, no extra icons, no border frame, no Google logos, no play triangle. Export a crisp high-resolution square icon.
