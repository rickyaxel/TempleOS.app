# lit.py <png>: prints 1 when the screenshot shows anything (a powered display), else 0.
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert('L').resize((40, 40))
print(1 if max(im.get_flattened_data() if hasattr(im, 'get_flattened_data') else im.getdata()) > 8 else 0)
