import os
import argparse
from PIL import Image

# Standard 16-color ComputerCraft palette RGB values
CC_PALETTE = [
    (240, 240, 240),  # 0: white
    (242, 178, 51),   # 1: orange
    (229, 127, 216),  # 2: magenta
    (153, 178, 242),  # 3: light blue
    (222, 222, 108),  # 4: yellow
    (127, 204, 25),   # 5: lime
    (242, 178, 204),  # 6: pink
    (76, 76, 76),     # 7: gray
    (153, 153, 153),  # 8: light gray
    (76, 153, 178),   # 9: cyan
    (178, 102, 229),  # a: purple
    (51, 102, 204),   # b: blue
    (127, 102, 76),   # c: brown
    (87, 166, 78),    # d: green
    (204, 76, 76),    # e: red
    (17, 17, 17)      # f: black
]

HEX_CHARS = "0123456789abcdef"

def closest_color(rgb):
    r, g, b = rgb[:3]
    min_dist = float("inf")
    best_index = 0
    for i, (cr, cg, cb) in enumerate(CC_PALETTE):
        dist = (r - cr) ** 2 + (g - cg) ** 2 + (b - cb) ** 2
        if dist < min_dist:
            min_dist = dist
            best_index = i
    return HEX_CHARS[best_index]

def convert_image_to_nfp(image_path, output_path, max_width=None, max_height=None):
    img = Image.open(image_path).convert("RGB")
    
    if max_width or max_height:
        img.thumbnail((max_width or img.width, max_height or img.height))
        
    width, height = img.size
    pixels = img.load()
    
    lines = []
    for y in range(height):
        line = [closest_color(pixels[x, y]) for x in range(width)]
        lines.append("".join(line))
        
    with open(output_path, "w") as f:
        f.write("\n".join(lines))
    print(f"Converted: {image_path} -> {output_path} ({width}x{height})")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Convert images to ComputerCraft .nfp format.")
    parser.add_argument("images", nargs="+", help="Paths to input image files (PNG/JPG)")
    parser.add_argument("-mw", "--max-width", type=int, default=None, help="Maximum width constraint")
    parser.add_argument("-mh", "--max-height", type=int, default=None, help="Maximum height constraint")
    parser.add_argument("-o", "--output-dir", type=str, default=None, help="Directory to save generated .nfp files")

    args = parser.parse_args()

    for img_path in args.images:
        if not os.path.exists(img_path):
            print(f"Error: File not found: {img_path}")
            continue
        
        base_name = os.path.splitext(os.path.basename(img_path))[0]
        out_filename = base_name + ".nfp"
        
        if args.output_dir:
            os.makedirs(args.output_dir, exist_ok=True)
            out_path = os.path.join(args.output_dir, out_filename)
        else:
            out_path = out_filename
            
        convert_image_to_nfp(img_path, out_path, args.max_width, args.max_height)
