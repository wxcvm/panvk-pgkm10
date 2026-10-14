"""Adapt the pinned upstream lifecycle test for objective Surface pixel checks."""
from pathlib import Path
import sys

source = Path(sys.argv[1])
text = source.read_text()
changes = {
    '#include <stdarg.h>': '#include <stdarg.h>\n#include <stdatomic.h>',
    'static void *g_icd;': 'static void *g_icd;\nstatic _Atomic int g_surface_transform = 1;',
    '    if (banner)\n        lg(c, "SWAPCHAIN %ux%u images=%u format=%u", ext.width, ext.height, im.n,\n           (unsigned)c->format);':
        '    if (banner) {\n'
        '        g_surface_transform = (int)pre;\n'
        '        lg(c, "SWAPCHAIN %ux%u images=%u format=%u transform=%u", ext.width, ext.height, im.n,\n'
        '           (unsigned)c->format, (unsigned)pre);\n    }',
    "VkClearValue clear = {.color = {{t, 0.15f, 1.f - t, 1.f}}};":
        "unsigned code = (unsigned)index & 255u;\n"
        "    float red = (32.f + (code & 15u) * 12.f) / 255.f;\n"
        "    float green = (32.f + (code >> 4) * 12.f) / 255.f;\n"
        "    VkClearValue clear = {.color = {{red, green, 1.f - red, 1.f}}};\n"
        "    vp.x = ((float)(code & 7u) - 3.5f) * 0.025f * vp.width;",
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
text += '''
JNIEXPORT jint JNICALL
Java_dev_zenithblue_panvktest_Native_swapchainTransform(JNIEnv *env, jclass cls)
{
    (void)env;
    (void)cls;
    return atomic_load(&g_surface_transform);
}
'''
source.write_text(text)
