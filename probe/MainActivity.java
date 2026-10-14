package dev.wxcvm.panvkprobe;

import android.app.Activity;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;
import android.view.PixelCopy;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.TextView;
import dev.zenithblue.panvktest.Native;
import java.io.File;
import java.io.FileWriter;
import java.io.IOException;

/** Local-only display test. No network permission or game access. */
public final class MainActivity extends Activity implements SurfaceHolder.Callback {
    private final Handler ui = new Handler(Looper.getMainLooper());
    private SurfaceView surface;
    private TextView status;
    private volatile boolean running;
    private boolean started, copying;
    private int goodFrames, badFrames, copyErrors;
    private int previousCode = -1, codeChanges, mixedFrames, orderErrors;
    private String nativeResult;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        getWindow().getDecorView().setSystemUiVisibility(5894);
        FrameLayout root = new FrameLayout(this);
        surface = new SurfaceView(this);
        surface.getHolder().addCallback(this);
        root.addView(surface);
        status = new TextView(this);
        status.setTextColor(Color.WHITE);
        status.setBackgroundColor(0x99000000);
        status.setText("PanVK display probe — tap to start");
        root.addView(status, new FrameLayout.LayoutParams(-1, -2));
        root.setOnClickListener(v -> start());
        setContentView(root);
    }

    @Override public void surfaceCreated(SurfaceHolder holder) {
        if (getIntent().getBooleanExtra("auto", false)) {
            int delay = Math.max(0, Math.min(30000, getIntent().getIntExtra("delay_ms", 3000)));
            ui.postDelayed(this::start, delay);
        }
    }
    @Override public void surfaceChanged(SurfaceHolder holder, int format, int w, int h) {}
    @Override public void surfaceDestroyed(SurfaceHolder holder) {
        // Never tear down a Surface concurrently with an in-flight native test.
        if (running) android.os.Process.killProcess(android.os.Process.myPid());
    }

    private void start() {
        if (started || !surface.getHolder().getSurface().isValid()) return;
        started = running = true;
        String mode = getIntent().getStringExtra("driver");
        String driver = "system".equals(mode) ? "/system/lib64/libvulkan.so"
            : getApplicationInfo().nativeLibraryDir + "/libvulkan_panfrost.so";
        status.setText("Testing " + driver);
        Log.i("MoveCertPresent", "START driver=" + driver);
        new Thread(() -> {
            String result;
            try {
                result = Native.swapchainTest(driver, surface.getHolder().getSurface(),
                    new File(getFilesDir(), "native.log").getAbsolutePath());
            } catch (Throwable error) {
                result = "FAIL " + error;
            }
            final String value = result;
            ui.post(() -> { running = false; nativeResult = value; finishResult(); });
        }, "present-probe").start();
        ui.postDelayed(this::sample, 250);
        ui.postDelayed(() -> {
            if (running) {
                save("FAIL watchdog exceeded 55 seconds");
                android.os.Process.killProcess(android.os.Process.myPid());
            }
        }, 55000);
    }

    private void sample() {
        if (!running) return;
        String phase = Native.swapchainPhase();
        if (!copying && phase.startsWith("present_main ") && surface.getWidth() > 0) {
            // PixelCopy reads this test's Surface; it never captures other applications.
            Bitmap bitmap = Bitmap.createBitmap(surface.getWidth(), surface.getHeight(), Bitmap.Config.ARGB_8888);
            copying = true;
            try {
                PixelCopy.request(surface, bitmap, result -> {
                    if (Native.swapchainPhase().startsWith("present_main ")) {
                        if (result == PixelCopy.SUCCESS) checkFrame(bitmap);
                        else copyErrors++;
                    }
                    bitmap.recycle();
                    copying = false;
                    if (!running) finishResult();
                }, ui);
            } catch (IllegalArgumentException error) {
                copying = false;
                bitmap.recycle();
                copyErrors++;
            }
        }
        ui.postDelayed(this::sample, 150);
    }

    private void checkFrame(Bitmap bitmap) {
        int tested = 0, bad = 0;
        int transform = Native.swapchainTransform();
        if (transform != 1 && transform != 2 && transform != 4 && transform != 8) {
            badFrames++;
            Log.e("MoveCertPresent", "Unsupported calibration transform=" + transform);
            return;
        }
        // Decode the frame from its background, not the CPU's newest submission.
        // The bottom-left render-space corner stays outside the moving triangle.
        float anchorU = .05f, anchorV = .95f;
        if (transform == 2) { anchorU = .95f; anchorV = .95f; }
        if (transform == 4) { anchorU = .95f; anchorV = .05f; }
        if (transform == 8) { anchorU = .05f; anchorV = .05f; }
        int anchor = bitmap.getPixel((int)(anchorU * bitmap.getWidth()), (int)(anchorV * bitmap.getHeight()));
        int low = Math.round((Color.red(anchor) - 32) / 12f);
        int high = Math.round((Color.green(anchor) - 32) / 12f);
        if (low < 0 || low > 15 || high < 0 || high > 15) {
            badFrames++;
            Log.e("MoveCertPresent", "Invalid frame code color=" + Integer.toHexString(anchor));
            return;
        }
        int code = low | (high << 4);
        int expectedR = 32 + low * 12, expectedG = 32 + high * 12, expectedB = 255 - expectedR;
        float shift = ((code & 7) - 3.5f) * .025f;
        // Numbered background and matching moving geometry reveal cross-frame mixing.
        for (int y = 1; y < 32; y++) for (int x = 1; x < 32; x++) {
            float u = x / 32f, v = y / 32f;
            // Android applies the inverse of the declared swapchain preTransform.
            // Map the displayed pixel back into the original render coordinates.
            float sx = u, sy = v;
            if (transform == 2) { sx = 1f - v; sy = u; }
            if (transform == 4) { sx = 1f - u; sy = 1f - v; }
            if (transform == 8) { sx = v; sy = 1f - u; }
            float edge = 1f - sy - Math.abs(2f * (sx - shift) - 1f);
            if (Math.abs(edge) < 0.06f) continue;
            int color = bitmap.getPixel((int)(u * bitmap.getWidth()), (int)(v * bitmap.getHeight()));
            int r = Color.red(color), g = Color.green(color), b = Color.blue(color);
            boolean okay = edge > 0 ? r > 210 && g < 40 && b < 40
                : Math.abs(r - expectedR) <= 5 && Math.abs(g - expectedG) <= 5 && Math.abs(b - expectedB) <= 5;
            tested++;
            if (!okay) bad++;
        }
        if (bad == 0) {
            goodFrames++;
            if (previousCode >= 0 && previousCode != code) {
                codeChanges++;
                // Samples are 150 ms apart. A backwards code is reported for review;
                // scheduling gaps could also exceed half the 256-frame code cycle.
                if (((code - previousCode) & 255) > 128) orderErrors++;
            }
            previousCode = code;
        } else { badFrames++; mixedFrames++; }
        Log.i("MoveCertPresent", "PIXELS code=" + code + " transform=" + transform + " checked=" + tested + " mismatches=" + bad);
    }

    private void finishResult() {
        if (copying || nativeResult == null) return;
        boolean pass = nativeResult.equals("exit:0") && goodFrames >= 3 && codeChanges >= 3
            && badFrames == 0 && copyErrors == 0 && orderErrors == 0;
        String text = "RESULT " + (pass ? "PASS" : "FAIL") + " native=" + nativeResult
            + " goodFrames=" + goodFrames + " badFrames=" + badFrames + " copyErrors=" + copyErrors
            + " codeChanges=" + codeChanges + " mixedFrames=" + mixedFrames + " orderErrors=" + orderErrors;
        status.setText(text);
        save(text);
    }

    private void save(String value) {
        Log.i("MoveCertPresent", value);
        try (FileWriter file = new FileWriter(new File(getFilesDir(), "result.txt"))) {
            file.write(value + "\n");
        } catch (IOException error) { Log.e("MoveCertPresent", "Cannot save result", error); }
    }
}
