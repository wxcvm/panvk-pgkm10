// Minimal Vulkan driver benchmark: submit round-trip overhead and clear throughput.
// Loads a specific Vulkan HAL/ICD in this process only; never touches system mounts.
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan_core.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
typedef struct { int version, numFds, numInts; int data[]; } native_handle_t;
#include "gpu-hal-loader.h"

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1e6;
}

struct procs {
    PFN_vkDestroyInstance destroy_instance;
    PFN_vkEnumeratePhysicalDevices enumerate_physical;
    PFN_vkGetPhysicalDeviceProperties physical_props;
    PFN_vkGetPhysicalDeviceQueueFamilyProperties queue_family_props;
    PFN_vkGetPhysicalDeviceMemoryProperties memory_props;
    PFN_vkCreateDevice create_device;
    PFN_vkGetDeviceProcAddr get_device_proc;
    PFN_vkDestroyDevice destroy_device;
    PFN_vkGetDeviceQueue get_queue;
    PFN_vkCreateImage create_image;
    PFN_vkDestroyImage destroy_image;
    PFN_vkGetImageMemoryRequirements image_memory_reqs;
    PFN_vkAllocateMemory allocate_memory;
    PFN_vkFreeMemory free_memory;
    PFN_vkBindImageMemory bind_image_memory;
    PFN_vkCreateCommandPool create_pool;
    PFN_vkDestroyCommandPool destroy_pool;
    PFN_vkAllocateCommandBuffers allocate_command;
    PFN_vkBeginCommandBuffer begin_command;
    PFN_vkEndCommandBuffer end_command;
    PFN_vkCmdPipelineBarrier cmd_barrier;
    PFN_vkCmdClearColorImage cmd_clear;
    PFN_vkCreateFence create_fence;
    PFN_vkDestroyFence destroy_fence;
    PFN_vkResetFences reset_fences;
    PFN_vkQueueSubmit queue_submit;
    PFN_vkWaitForFences wait_fences;
};

#define DEV_PROC(member, fn) do { p.member = (PFN_##fn)get_dpa(device, #fn); if (!p.member) { fprintf(stderr, "missing %s\n", #fn); return 1; } } while (0)

static int bench_size(const struct procs *p, VkDevice dev, VkQueue queue, VkCommandPool pool,
                      VkFence fence, VkPhysicalDevice phys, uint32_t width, uint32_t height,
                      int iterations, int warmup, const char *label) {
    VkImage image = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkCommandBuffer command = VK_NULL_HANDLE;
    int failed = 1;
    VkImageCreateInfo image_info = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = VK_FORMAT_R8G8B8A8_UNORM,
        .extent = {width, height, 1},
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    VkResult result = p->create_image(dev, &image_info, NULL, &image);
    if (result != VK_SUCCESS) { fprintf(stderr, "%s: CreateImage=%d\n", label, result); goto done; }
    VkMemoryRequirements reqs;
    p->image_memory_reqs(dev, image, &reqs);
    VkPhysicalDeviceMemoryProperties mem;
    p->memory_props(phys, &mem);
    uint32_t type = UINT32_MAX;
    for (uint32_t i = 0; i < mem.memoryTypeCount; i++) {
        if ((reqs.memoryTypeBits & (1u << i)) && (mem.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)) {
            type = i;
            break;
        }
    }
    if (type == UINT32_MAX) { fprintf(stderr, "%s: no device-local memory type\n", label); goto done; }
    VkMemoryAllocateInfo alloc = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = reqs.size, .memoryTypeIndex = type};
    result = p->allocate_memory(dev, &alloc, NULL, &memory);
    if (result != VK_SUCCESS) { fprintf(stderr, "%s: AllocateMemory=%d\n", label, result); goto done; }
    result = p->bind_image_memory(dev, image, memory, 0);
    if (result != VK_SUCCESS) { fprintf(stderr, "%s: BindImageMemory=%d\n", label, result); goto done; }
    VkCommandBufferAllocateInfo cai = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
    result = p->allocate_command(dev, &cai, &command);
    if (result != VK_SUCCESS) { fprintf(stderr, "%s: AllocateCommandBuffers=%d\n", label, result); goto done; }
    VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    p->begin_command(command, &begin);
    VkImageSubresourceRange range = {.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .levelCount = 1, .layerCount = 1};
    VkImageMemoryBarrier to_dst = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = image, .subresourceRange = range};
    p->cmd_barrier(command, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &to_dst);
    VkClearColorValue color = {.float32 = {0.25f, 0.5f, 0.75f, 1.0f}};
    p->cmd_clear(command, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &color, 1, &range);
    p->end_command(command);

    VkSubmitInfo submit = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &command};
    for (int i = 0; i < warmup; i++) {
        p->queue_submit(queue, 1, &submit, fence);
        p->wait_fences(dev, 1, &fence, VK_TRUE, 5000000000ULL);
        p->reset_fences(dev, 1, &fence);
    }
    double t0 = now_ms();
    int completed = 0;
    for (int i = 0; i < iterations; i++) {
        VkResult sr = p->queue_submit(queue, 1, &submit, fence);
        if (sr != VK_SUCCESS) { fprintf(stderr, "%s: QueueSubmit=%d at %d\n", label, sr, i); break; }
        VkResult wr = p->wait_fences(dev, 1, &fence, VK_TRUE, 5000000000ULL);
        if (wr != VK_SUCCESS) { fprintf(stderr, "%s: WaitForFences=%d at %d\n", label, wr, i); break; }
        p->reset_fences(dev, 1, &fence);
        completed++;
    }
    double elapsed = now_ms() - t0;
    if (completed) {
        double bytes = (double)width * height * 4.0 * completed;
        printf("%s: iterations=%d elapsed=%.2f ms per_submit=%.3f ms clear_throughput=%.2f GB/s\n",
               label, completed, elapsed, elapsed / completed, bytes / (elapsed * 1e6));
        failed = 0;
    }
done:
    if (command) p->destroy_pool(dev, pool, NULL); /* pool owns command buffers */
    if (image) p->destroy_image(dev, image, NULL);
    if (memory) p->free_memory(dev, memory, NULL);
    return failed;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: gpu-vk-bench <driver.so|icd.so>\n");
        return 2;
    }
    void *lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!lib) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
    PFN_vkGetInstanceProcAddr gipa = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr");
    if (!gipa) gipa = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vk_icdGetInstanceProcAddr");
    if (!gipa) gipa = open_probe_hal(lib);
    if (!gipa) { fprintf(stderr, "no GetInstanceProcAddr\n"); return 2; }
    PFN_vkCreateInstance create_instance = (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
    if (!create_instance) { fprintf(stderr, "no vkCreateInstance\n"); return 2; }
    VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "panvk-bench", .apiVersion = VK_API_VERSION_1_1};
    VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
    VkInstance instance = VK_NULL_HANDLE;
    VkResult result = create_instance(&ici, NULL, &instance);
    printf("CreateInstance=%d\n", result);
    if (result != VK_SUCCESS) return 3;

    struct procs p = {0};
    p.destroy_instance = (PFN_vkDestroyInstance)gipa(instance, "vkDestroyInstance");
    p.enumerate_physical = (PFN_vkEnumeratePhysicalDevices)gipa(instance, "vkEnumeratePhysicalDevices");
    p.physical_props = (PFN_vkGetPhysicalDeviceProperties)gipa(instance, "vkGetPhysicalDeviceProperties");
    p.queue_family_props = (PFN_vkGetPhysicalDeviceQueueFamilyProperties)gipa(instance, "vkGetPhysicalDeviceQueueFamilyProperties");
    p.memory_props = (PFN_vkGetPhysicalDeviceMemoryProperties)gipa(instance, "vkGetPhysicalDeviceMemoryProperties");
    p.create_device = (PFN_vkCreateDevice)gipa(instance, "vkCreateDevice");
    if (!p.destroy_instance || !p.enumerate_physical || !p.create_device || !p.queue_family_props || !p.memory_props) {
        fprintf(stderr, "missing instance procs\n");
        return 4;
    }
    uint32_t count = 0;
    if (p.enumerate_physical(instance, &count, NULL) || !count) { fprintf(stderr, "no physical device\n"); return 4; }
    VkPhysicalDevice physicals[8];
    if (count > 8) count = 8;
    p.enumerate_physical(instance, &count, physicals);
    VkPhysicalDevice physical = physicals[0];
    VkPhysicalDeviceProperties props;
    p.physical_props(physical, &props);
    printf("Device=%s API=%u.%u.%u driver=%u\n", props.deviceName,
           VK_VERSION_MAJOR(props.apiVersion), VK_VERSION_MINOR(props.apiVersion), VK_VERSION_PATCH(props.apiVersion),
           props.driverVersion);

    uint32_t family_count = 0;
    p.queue_family_props(physical, &family_count, NULL);
    VkQueueFamilyProperties families[32];
    if (family_count > 32) family_count = 32;
    p.queue_family_props(physical, &family_count, families);
    uint32_t family = UINT32_MAX;
    for (uint32_t i = 0; i < family_count; i++) {
        if (families[i].queueCount && (families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT)) { family = i; break; }
    }
    if (family == UINT32_MAX) { fprintf(stderr, "no graphics queue\n"); return 4; }
    float priority = 1.0f;
    VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = family, .queueCount = 1, .pQueuePriorities = &priority};
    VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci};
    VkDevice device = VK_NULL_HANDLE;
    result = p.create_device(physical, &dci, NULL, &device);
    printf("CreateDevice=%d\n", result);
    if (result != VK_SUCCESS) return 5;
    p.destroy_device = (PFN_vkDestroyDevice)gipa(instance, "vkDestroyDevice");
    p.get_device_proc = (PFN_vkGetDeviceProcAddr)gipa(instance, "vkGetDeviceProcAddr");
    if (!p.get_device_proc) { fprintf(stderr, "no vkGetDeviceProcAddr\n"); return 4; }
    PFN_vkGetDeviceProcAddr get_dpa = p.get_device_proc;
    DEV_PROC(get_queue, vkGetDeviceQueue);
    DEV_PROC(create_image, vkCreateImage);
    DEV_PROC(destroy_image, vkDestroyImage);
    DEV_PROC(image_memory_reqs, vkGetImageMemoryRequirements);
    DEV_PROC(allocate_memory, vkAllocateMemory);
    DEV_PROC(free_memory, vkFreeMemory);
    DEV_PROC(bind_image_memory, vkBindImageMemory);
    DEV_PROC(create_pool, vkCreateCommandPool);
    DEV_PROC(destroy_pool, vkDestroyCommandPool);
    DEV_PROC(allocate_command, vkAllocateCommandBuffers);
    DEV_PROC(begin_command, vkBeginCommandBuffer);
    DEV_PROC(end_command, vkEndCommandBuffer);
    DEV_PROC(cmd_barrier, vkCmdPipelineBarrier);
    DEV_PROC(cmd_clear, vkCmdClearColorImage);
    DEV_PROC(create_fence, vkCreateFence);
    DEV_PROC(destroy_fence, vkDestroyFence);
    DEV_PROC(reset_fences, vkResetFences);
    DEV_PROC(queue_submit, vkQueueSubmit);
    DEV_PROC(wait_fences, vkWaitForFences);

    VkQueue queue = VK_NULL_HANDLE;
    p.get_queue(device, family, 0, &queue);
    VkCommandPoolCreateInfo pool_info = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = family};
    VkCommandPool pool = VK_NULL_HANDLE;
    result = p.create_pool(device, &pool_info, NULL, &pool);
    if (result != VK_SUCCESS) { fprintf(stderr, "CreateCommandPool=%d\n", result); return 6; }
    VkFenceCreateInfo fence_info = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    VkFence fence = VK_NULL_HANDLE;
    result = p.create_fence(device, &fence_info, NULL, &fence);
    if (result != VK_SUCCESS) { fprintf(stderr, "CreateFence=%d\n", result); return 6; }

    int rc = 0;
    rc |= bench_size(&p, device, queue, pool, fence, physical, 512, 512, 400, 20, "small_clear_512x512");
    /* bench_size destroys the command pool; recreate for the second size. */
    result = p.create_pool(device, &pool_info, NULL, &pool);
    if (result == VK_SUCCESS) {
        rc |= bench_size(&p, device, queue, pool, fence, physical, 2048, 2048, 60, 10, "large_clear_2048x2048");
    }
    p.destroy_fence(device, fence, NULL);
    p.destroy_device(device, NULL);
    p.destroy_instance(instance, NULL);
    return rc;
}
