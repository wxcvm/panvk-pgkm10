package dev.zenithblue.panvktest;

import android.view.Surface;

/** JNI declarations for the pinned upstream swapchain lifecycle probe. */
public final class Native {
    static { System.loadLibrary("presentprobe"); }
    public static native String swapchainTest(String driver, Surface surface, String log);
    public static native String swapchainPhase();
    public static native int swapchainTransform();
}
