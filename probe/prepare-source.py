"""Adapt the pinned upstream lifecycle test for objective Surface pixel checks."""
from pathlib import Path
import sys

source = Path(sys.argv[1])
text = source.read_text()
changes = {
    "VkClearValue clear = {.color = {{t, 0.15f, 1.f - t, 1.f}}};":
        "VkClearValue clear = {.color = {{0.f, 0.f, 1.f, 1.f}}};",
    "for (i = 0; i < frames; i++)\n        if (!draw_frame(c, i))\n            return 0;":
        "for (i = 0; i < frames; i++) {\n"
        "        if (!draw_frame(c, i)) return 0;\n"
        "        struct timespec delay = {0, 10000000};\n"
        "        nanosleep(&delay, NULL);\n    }",
}
for old, new in changes.items():
    if text.count(old) != 1:
        raise SystemExit("Pinned probe source no longer matches adaptation")
    text = text.replace(old, new)
source.write_text(text)
