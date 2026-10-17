// Minimal LP64 Android Vulkan HAL ABI used only by this local standalone probe.
// Verified against AOSP hardware.h and frameworks/native/vulkan/include/hardware/hwvulkan.h.
struct probe_hw_module;
struct probe_hw_device {
    uint32_t tag, version;
    struct probe_hw_module *module;
    uint64_t reserved[12];
    int (*close)(struct probe_hw_device *);
};
struct probe_hw_methods {
    int (*open)(const struct probe_hw_module *, const char *, struct probe_hw_device **);
};
struct probe_hw_module {
    uint32_t tag;
    uint16_t module_version, hal_version;
    const char *id, *name, *author;
    struct probe_hw_methods *methods;
    void *dso;
    uint64_t reserved[25];
};
struct probe_vk_hal {
    struct probe_hw_device common;
    PFN_vkEnumerateInstanceExtensionProperties enumerate;
    PFN_vkCreateInstance create;
    PFN_vkGetInstanceProcAddr gipa;
};
static struct probe_vk_hal *probe_hal;
static PFN_vkGetInstanceProcAddr open_probe_hal(void *library) {
    struct probe_hw_module *module=dlsym(library,"HMI");
    if (!module || module->tag!=0x48574d54 || !module->id || strcmp(module->id,"vulkan") || !module->methods || !module->methods->open) return NULL;
    struct probe_hw_device *device=NULL;
    if(module->methods->open(module,"vk0",&device) || !device) return NULL;
    if(device->tag!=0x48574454) { if(device->close) device->close(device); return NULL; }
    probe_hal=(struct probe_vk_hal *)device;
    return probe_hal->gipa;
}
