#!/usr/bin/env python3
"""生成 App 图标源图 Resources/AppIcon.png（1024x1024）。

画一个 macOS 风格的圆角方块 + 八分音符。想换图标的话，直接用自己的
1024x1024 PNG 覆盖 Resources/AppIcon.png 即可，不必跑这个脚本。

依赖：Pillow（pip install Pillow）
"""

from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 1024
# Big Sur 之后的图标规范：内容占画布约 80%，四周留白由系统统一处理
MARGIN = 100
RADIUS = 185

TOP_COLOR = (108, 92, 231)     # 靛紫
BOTTOM_COLOR = (214, 93, 177)  # 品红


def vertical_gradient(width: int, height: int, top: tuple, bottom: tuple) -> Image.Image:
    """竖直线性渐变。逐行填色，1024 行的开销可以忽略。"""
    image = Image.new("RGB", (width, height))
    draw = ImageDraw.Draw(image)
    for y in range(height):
        t = y / max(1, height - 1)
        color = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        draw.line([(0, y), (width, y)], fill=color)
    return image


def rounded_mask(width: int, height: int, box: tuple, radius: int) -> Image.Image:
    mask = Image.new("L", (width, height), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    return mask


def quadratic_bezier(p0, p1, p2, steps: int = 40):
    points = []
    for i in range(steps + 1):
        t = i / steps
        u = 1 - t
        x = u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0]
        y = u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1]
        points.append((x, y))
    return points


def draw_note(canvas: Image.Image) -> None:
    """画一个白色八分音符：符头（斜椭圆）+ 符干 + 符尾（两条贝塞尔曲线围成）。"""
    white = (255, 255, 255, 255)

    stem_x = 482
    stem_w = 46
    stem_top = 290
    stem_bottom = 700

    # 符干
    ImageDraw.Draw(canvas).rounded_rectangle(
        [stem_x, stem_top, stem_x + stem_w, stem_bottom],
        radius=stem_w // 2,
        fill=white,
    )

    # 符头：先在独立图层上画正椭圆再旋转，得到倾斜的实心符头
    head_w, head_h = 300, 216
    head_layer = Image.new("RGBA", (head_w + 80, head_h + 80), (0, 0, 0, 0))
    ImageDraw.Draw(head_layer).ellipse([40, 40, 40 + head_w, 40 + head_h], fill=white)
    head_layer = head_layer.rotate(20, resample=Image.BICUBIC, expand=True)
    head_pos = (
        stem_x + stem_w // 2 - head_layer.width // 2,
        stem_bottom - head_layer.height // 2 + 10,
    )
    canvas.alpha_composite(head_layer, dest=head_pos)

    # 符尾：外弧向右下甩出，内弧收回，两条曲线首尾相接成一个填充区域。
    # 末端要停在符头上方，否则两块白色会糊成一团。
    tip = (stem_x + stem_w, stem_top)
    flag_end = (stem_x + 118, stem_top + 210)
    outer = quadratic_bezier(tip, (stem_x + 218, stem_top + 40), (stem_x + 118, stem_top + 210))
    inner = quadratic_bezier(flag_end, (stem_x + 158, stem_top + 100), (stem_x + stem_w, stem_top + 118))
    ImageDraw.Draw(canvas).polygon(outer + inner, fill=white)


def main() -> None:
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    box = (MARGIN, MARGIN, SIZE - MARGIN, SIZE - MARGIN)
    gradient = vertical_gradient(SIZE, SIZE, TOP_COLOR, BOTTOM_COLOR).convert("RGBA")
    canvas.paste(gradient, (0, 0), rounded_mask(SIZE, SIZE, box, RADIUS))

    draw_note(canvas)

    out = Path(__file__).resolve().parent.parent / "Resources" / "AppIcon.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(out)
    print(f"已生成 {out} ({canvas.width}x{canvas.height})")


if __name__ == "__main__":
    main()
