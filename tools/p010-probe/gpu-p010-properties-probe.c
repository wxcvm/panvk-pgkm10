// Independent Vulkan initialization and AHB probe. No mounts or configuration writes.
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan_core.h>
#include <vulkan/vulkan_android.h>
#include <android/hardware_buffer.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>
#include <fcntl.h>
#include <strings.h>
#include <dirent.h>
typedef struct { int version,numFds,numInts; int data[]; } native_handle_t;
#define os_dupfd_cloexec(fd) fcntl((fd),F_DUPFD_CLOEXEC,0)
#include "gpu-hal-loader.h"

static void require_pointer(const void *p, const char *name) {
    if (!p) { fprintf(stderr, "Missing %s: %s\n", name, dlerror()); exit(2); }
}
static int has_extension(VkExtensionProperties *list, uint32_t count, const char *name) {
    for (uint32_t i=0; i<count; ++i) if (!strcmp(list[i].extensionName,name)) return list[i].specVersion;
    return 0;
}
static VKAPI_ATTR VkBool32 VKAPI_CALL debug_message(VkDebugUtilsMessageSeverityFlagBitsEXT severity,VkDebugUtilsMessageTypeFlagsEXT type,const VkDebugUtilsMessengerCallbackDataEXT *data,void *user) {
    (void)severity; (void)type; (void)user;
    fprintf(stderr,"Vulkan debug: %s\n",data->pMessage ? data->pMessage : "(empty)");
    return VK_FALSE;
}
int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    if (argc != 2) { fprintf(stderr, "usage: gpu-probe library-path\n"); return 2; }
    void *library = dlopen(argv[1], RTLD_NOW|RTLD_LOCAL);
    require_pointer(library, "driver dlopen");
    PFN_vkGetInstanceProcAddr gipa = (PFN_vkGetInstanceProcAddr)dlsym(library,"vkGetInstanceProcAddr");
    if (!gipa) gipa=(PFN_vkGetInstanceProcAddr)dlsym(library,"vk_icdGetInstanceProcAddr");
    if (!gipa) gipa=open_probe_hal(library);
    require_pointer((void *)gipa,"GetInstanceProcAddr");
    PFN_vkCreateInstance create_instance=(PFN_vkCreateInstance)gipa(NULL,"vkCreateInstance");
    require_pointer((void *)create_instance,"CreateInstance");
    VkApplicationInfo ai={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.pApplicationName="MoveCertificate-independent-GPU-probe",.apiVersion=VK_API_VERSION_1_1};
    const char *instance_extensions[]={"VK_KHR_surface","VK_KHR_android_surface","VK_EXT_debug_utils"};
    PFN_vkEnumerateInstanceExtensionProperties enumerate_ie=(PFN_vkEnumerateInstanceExtensionProperties)gipa(NULL,"vkEnumerateInstanceExtensionProperties");
    int debug_enabled=0;
    if (enumerate_ie) {
        uint32_t ie_count=0;
        if (enumerate_ie(NULL,&ie_count,NULL)==VK_SUCCESS && ie_count<2048) {
            VkExtensionProperties *ie=calloc(ie_count ? ie_count : 1,sizeof(*ie));
            if (ie) { if (enumerate_ie(NULL,&ie_count,ie)==VK_SUCCESS) debug_enabled=has_extension(ie,ie_count,"VK_EXT_debug_utils")!=0; free(ie); }
        }
    }
    VkDebugUtilsMessengerCreateInfoEXT debug={.sType=VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,.messageSeverity=VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT|VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT|VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT,.messageType=VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT|VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT|VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,.pfnUserCallback=debug_message};
    VkInstanceCreateInfo ici={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.pApplicationInfo=&ai,.enabledExtensionCount=debug_enabled ? 3 : 2,.ppEnabledExtensionNames=instance_extensions,.pNext=debug_enabled ? &debug : NULL};
    VkInstance instance=VK_NULL_HANDLE;
    VkResult result=create_instance(&ici,NULL,&instance);
    printf("CreateInstance result=%d instance=%p\n",result,(void *)instance);
    if (result != VK_SUCCESS) return 3;
    VkDebugUtilsMessengerEXT messenger=VK_NULL_HANDLE;
    PFN_vkCreateDebugUtilsMessengerEXT create_messenger=(PFN_vkCreateDebugUtilsMessengerEXT)gipa(instance,"vkCreateDebugUtilsMessengerEXT");
    PFN_vkDestroyDebugUtilsMessengerEXT destroy_messenger=(PFN_vkDestroyDebugUtilsMessengerEXT)gipa(instance,"vkDestroyDebugUtilsMessengerEXT");
    if (debug_enabled && create_messenger && destroy_messenger) create_messenger(instance,&debug,NULL,&messenger);
#define INSTANCE_PROC(type, name) type name=(type)gipa(instance,#name); require_pointer((void *)name,#name)
    INSTANCE_PROC(PFN_vkDestroyInstance,vkDestroyInstance);
    INSTANCE_PROC(PFN_vkEnumeratePhysicalDevices,vkEnumeratePhysicalDevices);
    INSTANCE_PROC(PFN_vkGetPhysicalDeviceProperties,vkGetPhysicalDeviceProperties);
    INSTANCE_PROC(PFN_vkEnumerateDeviceExtensionProperties,vkEnumerateDeviceExtensionProperties);
    INSTANCE_PROC(PFN_vkGetPhysicalDeviceQueueFamilyProperties,vkGetPhysicalDeviceQueueFamilyProperties);
    INSTANCE_PROC(PFN_vkCreateDevice,vkCreateDevice);
    INSTANCE_PROC(PFN_vkGetDeviceProcAddr,vkGetDeviceProcAddr);
    uint32_t count=0;
    result=vkEnumeratePhysicalDevices(instance,&count,NULL);
    printf("EnumeratePhysicalDevices result=%d count=%u\n",result,count);
    if (result != VK_SUCCESS || !count || count>16) { vkDestroyInstance(instance,NULL); return 4; }
    VkPhysicalDevice physicals[16];
    result=vkEnumeratePhysicalDevices(instance,&count,physicals);
    if (result != VK_SUCCESS) { vkDestroyInstance(instance,NULL); return 4; }
    VkPhysicalDevice physical=physicals[0];
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(physical,&props);
    printf("Device=%s API=%u.%u.%u vendor=%04x device=%04x driver=%u\n",props.deviceName,VK_VERSION_MAJOR(props.apiVersion),VK_VERSION_MINOR(props.apiVersion),VK_VERSION_PATCH(props.apiVersion),props.vendorID,props.deviceID,props.driverVersion);
    uint32_t ec=0;
    result=vkEnumerateDeviceExtensionProperties(physical,NULL,&ec,NULL);
    if (result != VK_SUCCESS || ec>2048) { vkDestroyInstance(instance,NULL); return 5; }
    VkExtensionProperties *extensions=calloc(ec ? ec : 1,sizeof(*extensions));
    if (!extensions) { vkDestroyInstance(instance,NULL); return 5; }
    result=vkEnumerateDeviceExtensionProperties(physical,NULL,&ec,extensions);
    if (result != VK_SUCCESS) { free(extensions); vkDestroyInstance(instance,NULL); return 5; }
    const char *names[]={"VK_ANDROID_native_buffer","VK_KHR_swapchain","VK_ANDROID_external_memory_android_hardware_buffer","VK_KHR_fragment_shading_rate","VK_EXT_fragment_density_map","VK_KHR_external_memory","VK_KHR_dedicated_allocation"};
    for (size_t i=0; i<sizeof(names)/sizeof(names[0]); ++i) printf("Extension %s specVersion=%d\n",names[i],has_extension(extensions,ec,names[i]));
    const char *enabled[12]; uint32_t enabled_count=0;
    int foreign_enabled=has_extension(extensions,ec,"VK_EXT_queue_family_foreign")!=0;
    if (foreign_enabled) enabled[enabled_count++]="VK_EXT_queue_family_foreign";
    PFN_vkGetPhysicalDeviceProperties2 get_props2=(PFN_vkGetPhysicalDeviceProperties2)gipa(instance,"vkGetPhysicalDeviceProperties2");
    if (get_props2 && has_extension(extensions,ec,"VK_KHR_driver_properties")) {
        VkPhysicalDeviceDriverProperties driver={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES};
        VkPhysicalDeviceProperties2 all={.sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,.pNext=&driver};
        get_props2(physical,&all);
        printf("Driver identity: %s / %s\n",driver.driverName,driver.driverInfo);
    }
    for (size_t i=0; i<3; ++i) if (has_extension(extensions,ec,names[i])) enabled[enabled_count++]=names[i];
    const char *fd_extensions[]={"VK_KHR_external_memory_fd","VK_EXT_external_memory_dma_buf","VK_EXT_image_drm_format_modifier"};
    for (size_t i=0; i<3; ++i) if (has_extension(extensions,ec,fd_extensions[i])) enabled[enabled_count++]=fd_extensions[i];
    if (has_extension(extensions,ec,"VK_KHR_external_semaphore_fd")) enabled[enabled_count++]="VK_KHR_external_semaphore_fd";
    free(extensions);
    uint32_t qc=0;
    vkGetPhysicalDeviceQueueFamilyProperties(physical,&qc,NULL);
    if (!qc || qc>64) { vkDestroyInstance(instance,NULL); return 5; }
    VkQueueFamilyProperties queues[64];
    vkGetPhysicalDeviceQueueFamilyProperties(physical,&qc,queues);
    uint32_t queue_index=UINT32_MAX;
    for (uint32_t i=0; i<qc; ++i) if (queues[i].queueCount && (queues[i].queueFlags&VK_QUEUE_GRAPHICS_BIT)) { queue_index=i; break; }
    if (queue_index==UINT32_MAX) { vkDestroyInstance(instance,NULL); return 5; }
    float priority=1.0f;
    VkDeviceQueueCreateInfo qci={.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,.queueFamilyIndex=queue_index,.queueCount=1,.pQueuePriorities=&priority};
    VkDeviceCreateInfo dci={.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,.queueCreateInfoCount=1,.pQueueCreateInfos=&qci,.enabledExtensionCount=enabled_count,.ppEnabledExtensionNames=enabled};
    VkDevice device=VK_NULL_HANDLE;
    result=vkCreateDevice(physical,&dci,NULL,&device);
    printf("CreateDevice result=%d device=%p\n",result,(void *)device);
    if (result!=VK_SUCCESS) { vkDestroyInstance(instance,NULL); return 6; }

#define DP(name) PFN_##name name=(PFN_##name)vkGetDeviceProcAddr(device,#name); require_pointer((void *)name,#name)
    DP(vkDestroyDevice);
    DP(vkGetAndroidHardwareBufferPropertiesANDROID);
    void *nw=dlopen("libnativewindow.so",RTLD_NOW|RTLD_LOCAL);
    require_pointer(nw,"nativewindow");
    int (*allocate)(const AHardwareBuffer_Desc *,AHardwareBuffer **)=(void *)dlsym(nw,"AHardwareBuffer_allocate");
    void (*release)(AHardwareBuffer *)=(void *)dlsym(nw,"AHardwareBuffer_release");
    void (*describe)(const AHardwareBuffer *,AHardwareBuffer_Desc *)=(void *)dlsym(nw,"AHardwareBuffer_describe");
    require_pointer((void *)allocate,"allocate"); require_pointer((void *)release,"release"); require_pointer((void *)describe,"describe");
    const uint32_t formats[]={1,0x36,0x36};
    const uint64_t usages[]={0x100,0x100,4196608};
    int failures=0;
    for (unsigned i=0;i<3;i++) {
        AHardwareBuffer_Desc desc={.width=1272,.height=2772,.layers=1,.format=formats[i],.usage=usages[i]};
        AHardwareBuffer *buffer=NULL;
        int err=allocate(&desc,&buffer);
        printf("AHB case=%u format=%u usage=%#llx allocate=%d\n",i,desc.format,(unsigned long long)desc.usage,err);
        if (err || !buffer) { failures++; continue; }
        describe(buffer,&desc);
        VkAndroidHardwareBufferFormatPropertiesANDROID fp={.sType=VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_FORMAT_PROPERTIES_ANDROID};
        VkAndroidHardwareBufferPropertiesANDROID ap={.sType=VK_STRUCTURE_TYPE_ANDROID_HARDWARE_BUFFER_PROPERTIES_ANDROID,.pNext=&fp};
        VkResult r=vkGetAndroidHardwareBufferPropertiesANDROID(device,buffer,&ap);
        printf("AHB case=%u stride=%u properties=%d size=%llu bits=%#x format=%d external=%llu features=%#x\n",i,desc.stride,r,(unsigned long long)ap.allocationSize,ap.memoryTypeBits,fp.format,(unsigned long long)fp.externalFormat,fp.formatFeatures);
        if (r!=VK_SUCCESS) failures++;
        release(buffer);
    }
    vkDestroyDevice(device,NULL);
    if (messenger) destroy_messenger(instance,messenger,NULL);
    vkDestroyInstance(instance,NULL);
    printf("P010 property probe failures=%d (does not test sampling or composition)\n",failures);
    return failures ? 9 : 0;
}
