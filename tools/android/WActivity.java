package org.wlang.androiddemo;

import android.app.Activity;
import android.os.Bundle;
import android.text.Editable;
import android.text.TextWatcher;
import android.util.Log;
import android.view.View;
import android.view.WindowInsets;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;

/** Small UI-thread-only native-controls host. W owns application state. */
public final class WActivity extends Activity {
    static { System.loadLibrary("wandroid"); }
    private native void nativeSetup();
    private native void nativeEvent(long handle, long kind, byte[] text);
    private native void nativeLifecycle(long phase);
    private native void nativeProbes(String root);
    private final ArrayList<View> controls = new ArrayList<>();
    private LinearLayout form;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        ScrollView scroll = new ScrollView(this);
        form = new LinearLayout(this);
        form.setOrientation(LinearLayout.VERTICAL);
        int pad = (int) (24 * getResources().getDisplayMetrics().density);
        form.setPadding(pad, pad, pad, pad);
        scroll.addView(form);
        scroll.setOnApplyWindowInsetsListener((view, insets) -> {
            if (android.os.Build.VERSION.SDK_INT >= 30) {
                android.graphics.Insets bars = insets.getInsets(
                    WindowInsets.Type.systemBars() | WindowInsets.Type.ime());
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom);
            } else {
                view.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(),
                    insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            }
            return insets;
        });
        setContentView(scroll);
        if (getIntent().getBooleanExtra("w_probes", false)) {
            try {
                File root = new File(getFilesDir(), "w-src");
                extractSources("w-src", root);
                nativeProbes(root.getAbsolutePath());
                Log.i("WAndroid", "android compiler and ABI: ok " + getIntent().getStringExtra("w_smoke_token"));
            } catch (IOException error) {
                throw new IllegalStateException("Cannot extract compiler fixture sources", error);
            }
        }
        nativeSetup();
        if (getIntent().getBooleanExtra("w_smoke", false)) form.post(this::smoke);
    }

    private void extractSources(String asset, File destination) throws IOException {
        String[] children = getAssets().list(asset);
        if (children != null && children.length > 0) {
            if (!destination.isDirectory() && !destination.mkdirs()) throw new IOException("Cannot create " + destination);
            for (String child : children) extractSources(asset + "/" + child, new File(destination, child));
        } else {
            try (InputStream input = getAssets().open(asset); FileOutputStream output = new FileOutputStream(destination)) {
                byte[] buffer = new byte[8192];
                int count;
                while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
            }
        }
    }

    @Override protected void onResume() {
        super.onResume();
        nativeLifecycle(1);
    }

    @Override protected void onPause() {
        nativeLifecycle(2);
        super.onPause();
    }

    // These methods are called synchronously from W through host.c.
    public long addControl(int kind, byte[] bytes) {
        String text = new String(bytes, StandardCharsets.UTF_8);
        final long handle = controls.size() + 1;
        TextView control;
        if (kind == 2) {
            Button button = new Button(this);
            button.setText(text);
            button.setOnClickListener(v -> nativeEvent(handle, 1, new byte[0]));
            control = button;
        } else if (kind == 3) {
            EditText field = new EditText(this);
            field.setSingleLine(true);
            field.setHint(text);
            field.addTextChangedListener(new TextWatcher() {
                @Override public void beforeTextChanged(CharSequence s, int start, int count, int after) {}
                @Override public void onTextChanged(CharSequence s, int start, int before, int count) {
                    nativeEvent(handle, 2, s.toString().getBytes(StandardCharsets.UTF_8));
                }
                @Override public void afterTextChanged(Editable value) {}
            });
            control = field;
        } else {
            control = new TextView(this);
            control.setText(text);
            control.setTextSize(20);
        }
        control.setId(View.generateViewId());
        controls.add(control);
        form.addView(control, new LinearLayout.LayoutParams(-1, -2));
        return handle;
    }

    public void setLabel(long handle, byte[] bytes) {
        if (handle <= 0 || handle > controls.size()) throw new IllegalArgumentException("Invalid W handle");
        View view = controls.get((int) handle - 1);
        if (!(view instanceof TextView) || view instanceof EditText || view instanceof Button)
            throw new IllegalArgumentException("W handle does not name a label");
        ((TextView) view).setText(new String(bytes, StandardCharsets.UTF_8));
    }

    private boolean hasLabel(String text) {
        for (View view : controls)
            if (view instanceof TextView && !(view instanceof EditText) && !(view instanceof Button)
                    && ((TextView) view).getText().toString().equals(text)) return true;
        return false;
    }

    // Opt-in integration test for graphics/android/demo.w, including 4-byte UTF-8.
    private void smoke() {
        boolean clicked = false, edited = false;
        for (View view : controls) {
            if (!clicked && view instanceof Button) { view.performClick(); clicked = true; }
            if (!edited && view instanceof EditText) {
                ((EditText) view).setText("W × 😀 世界");
                edited = true;
            }
        }
        if (!clicked || !edited || !hasLabel("1") || !hasLabel("W × 😀 世界") || !hasLabel("Active"))
            throw new IllegalStateException("Android W native callback smoke failed");
        Log.i("WAndroid", "android demo native: ok " + getIntent().getStringExtra("w_smoke_token"));
    }
}
