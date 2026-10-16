package org.wlang.androiddemo;

import android.app.Activity;
import android.os.Bundle;
import android.content.res.ColorStateList;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.graphics.drawable.StateListDrawable;
import android.view.Gravity;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.FrameLayout;
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
    // The embedded compiler probe is a one-shot entry point per process.
    // Configuration changes recreate the Activity without unloading its native library.
    private static boolean probesPassed;
    private boolean smokeRecreated;
    private native void nativeSetup();
    private native void nativeEvent(long handle, long kind, byte[] text);
    private native void nativeLifecycle(long phase);
    private native void nativeProbes(String root);
    private final ArrayList<View> controls = new ArrayList<>();
    private LinearLayout form, section;
    private int background, surface, ink, muted, accent, accentText, tint, border;

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private GradientDrawable shape(int fill, int stroke, int radius) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(fill);
        drawable.setCornerRadius(dp(radius));
        if (stroke != 0) drawable.setStroke(dp(1), stroke);
        return drawable;
    }

    private void colors() {
        boolean dark = (getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK)
            == Configuration.UI_MODE_NIGHT_YES;
        background = Color.parseColor(dark ? "#121B17" : "#F4F3ED");
        surface = Color.parseColor(dark ? "#1D2922" : "#FFFFFF");
        ink = Color.parseColor(dark ? "#F1F4ED" : "#202D25");
        muted = Color.parseColor(dark ? "#B5C2B8" : "#59665D");
        accent = Color.parseColor(dark ? "#D5EDB8" : "#245B42");
        accentText = Color.parseColor(dark ? "#1B3625" : "#FFFFFF");
        tint = Color.parseColor(dark ? "#2B3D30" : "#EDF3E7");
        border = Color.parseColor(dark ? "#7A8D7D" : "#7D8E7E");
        getWindow().setStatusBarColor(Color.TRANSPARENT);
        getWindow().setNavigationBarColor(background);
        if (android.os.Build.VERSION.SDK_INT >= 29) getWindow().setStatusBarContrastEnforced(false);
        if (android.os.Build.VERSION.SDK_INT >= 30) {
            getWindow().setDecorFitsSystemWindows(false);
            // Samsung's PhoneWindow needs its decor created before requesting the controller.
            getWindow().getDecorView();
            int light = android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
                | android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
            getWindow().getInsetsController().setSystemBarsAppearance(dark ? 0 : light, light);
        } else {
            getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                | (dark ? 0 : View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR));
        }
    }

    private TextView text(String value, int size, int color, boolean medium) {
        TextView label = new TextView(this);
        label.setText(value);
        label.setTextSize(size);
        label.setTextColor(color);
        label.setTypeface(Typeface.create(medium ? "sans-serif-medium" : "sans-serif", Typeface.NORMAL));
        label.setIncludeFontPadding(false);
        label.setLineSpacing(dp(3), 1);
        return label;
    }

    private void attach(LinearLayout parent, View child, int top, int bottom) {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(-1, -2);
        params.setMargins(0, dp(top), 0, dp(bottom));
        parent.addView(child, params);
    }

    private void startSection() {
        section = new LinearLayout(this);
        section.setOrientation(LinearLayout.VERTICAL);
        section.setPadding(dp(20), dp(22), dp(20), dp(20));
        section.setBackground(shape(surface, 0, 24));
        attach(form, section, 20, 0);
    }


    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        smokeRecreated = state != null && state.getBoolean("w_smoke_recreated", false);
        colors();
        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(background);
        if (android.os.Build.VERSION.SDK_INT >= 29) scroll.setForceDarkAllowed(false);
        scroll.setFillViewport(true);
        scroll.setClipToPadding(true);
        // Center the content on tablets while allowing all text to grow with font scale.
        FrameLayout content = new FrameLayout(this);
        form = new LinearLayout(this) {
            @Override protected void onMeasure(int width, int height) {
                int available = View.MeasureSpec.getSize(width);
                super.onMeasure(View.MeasureSpec.makeMeasureSpec(Math.min(available, dp(560)),
                    View.MeasureSpec.EXACTLY), height);
            }
        };
        form.setOrientation(LinearLayout.VERTICAL);
        form.setPadding(dp(24), dp(28), dp(24), dp(28));
        form.setFocusableInTouchMode(true);
        content.addView(form, new FrameLayout.LayoutParams(-1, -2, Gravity.TOP | Gravity.CENTER_HORIZONTAL));
        scroll.addView(content);
        scroll.setOnApplyWindowInsetsListener((view, insets) -> {
            if (android.os.Build.VERSION.SDK_INT >= 30) {
                android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars()
                    | WindowInsets.Type.displayCutout() | WindowInsets.Type.ime());
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom);
            } else {
                android.view.DisplayCutout cutout = insets.getDisplayCutout();
                view.setPadding(Math.max(insets.getSystemWindowInsetLeft(), cutout == null ? 0 : cutout.getSafeInsetLeft()),
                    Math.max(insets.getSystemWindowInsetTop(), cutout == null ? 0 : cutout.getSafeInsetTop()),
                    Math.max(insets.getSystemWindowInsetRight(), cutout == null ? 0 : cutout.getSafeInsetRight()),
                    Math.max(insets.getSystemWindowInsetBottom(), cutout == null ? 0 : cutout.getSafeInsetBottom()));
            }
            return insets;
        });
        setContentView(scroll);
        scroll.requestApplyInsets();
        if (getIntent().getBooleanExtra("w_probes", false)) {
            try {
                if (!probesPassed) {
                    File root = new File(getFilesDir(), "w-src");
                    extractSources("w-src", root);
                    nativeProbes(root.getAbsolutePath());
                    probesPassed = true;
                }
                Log.i("WAndroid", "android compiler and ABI: ok " + getIntent().getStringExtra("w_smoke_token"));
            } catch (IOException error) {
                throw new IllegalStateException("Cannot extract compiler fixture sources", error);
            }
        }
        nativeSetup();
        kit.launched(getIntent(), state != null);
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

    // Optional screen/list/dialog/HTTP controls (kinds and events from 32) live in WKit.java.
    private final WKit kit = new WKit(this);
    public long kitCall(int op, long a, long b, byte[] s, byte[] t, byte[] u, byte[] v) { return kit.call(op, a, b, s, t, u, v); }
    public byte[] kitBytes(int op, long a, byte[] s) { return kit.bytes(op, a, s); }
    long kitRegister(View view) { controls.add(view); return controls.size(); }
    View kitView(long handle) { return handle > 0 && handle <= controls.size() ? controls.get((int) handle - 1) : null; }
    void kitTarget(LinearLayout container) { form = container; section = null; }
    void kitEvent(long handle, long kind, byte[] value) { nativeEvent(handle, kind, value); }
    @Override protected void onNewIntent(android.content.Intent intent) { super.onNewIntent(intent); setIntent(intent); kit.newIntent(intent); }
    @Override protected void onDestroy() { kit.destroy(); super.onDestroy(); }
    @Override public void onRequestPermissionsResult(int request, String[] names, int[] results) { kit.permissionResult(request, results); }
    @Override protected void onRestoreInstanceState(Bundle state) { super.onRestoreInstanceState(state); kit.restore(state); }

    // Back: Android 13+ dispatches it to an OnBackInvokedCallback, registered only
    // while W owns Back (two or more kit screens) so predictive back-to-home still
    // works from a root screen. Android 9-12 use the onBackPressed fallback.
    private Object backCallback;
    void kitBackEnabled(boolean enabled) {
        if (android.os.Build.VERSION.SDK_INT < 33 || enabled == (backCallback != null)) return;
        backCallback = Back33.set(this, backCallback, enabled, kit);
    }
    private static final class Back33 {
        static Object set(Activity activity, Object current, boolean enabled, WKit kit) {
            android.window.OnBackInvokedDispatcher dispatcher = activity.getOnBackInvokedDispatcher();
            if (!enabled) {
                dispatcher.unregisterOnBackInvokedCallback((android.window.OnBackInvokedCallback) current);
                return null;
            }
            android.window.OnBackInvokedCallback callback = kit::back;
            dispatcher.registerOnBackInvokedCallback(android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT, callback);
            return callback;
        }
    }
    @SuppressWarnings("deprecation")
    @Override public void onBackPressed() { if (!kit.back()) super.onBackPressed(); }

    @Override protected void onResume() {
        super.onResume();
        nativeLifecycle(1);
    }

    @Override protected void onPause() {
        nativeLifecycle(2);
        super.onPause();
    }

    @Override protected void onSaveInstanceState(Bundle state) {
        state.putBoolean("w_smoke_recreated", smokeRecreated);
        kit.save(state);
        super.onSaveInstanceState(state);
    }

    // These methods are called synchronously from W through host.c.
    public long addControl(int kind, byte[] bytes) {
        String text = new String(bytes, StandardCharsets.UTF_8);
        final long handle = controls.size() + 1;
        // Kinds 1..3 are the original API. Presentation roles are additive.
        if (kind == 10) { section = null; return 0; }
        if (kind == 6) startSection();
        LinearLayout parent = section == null ? form : section;
        TextView control;
        View item;
        int top = 12;
        if (kind == 2 || kind == 8) {
            Button button = new Button(this);
            button.setText(text);
            button.setAllCaps(false);
            button.setTextSize(16);
            button.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
            button.setTextColor(kind == 2 ? accentText : accent);
            button.setMinHeight(dp(52));
            button.setMinimumHeight(dp(52));
            button.setPadding(dp(20), dp(14), dp(20), dp(14));
            button.setStateListAnimator(null);
            StateListDrawable states = new StateListDrawable();
            GradientDrawable focused = shape(kind == 2 ? accent : tint, 0, 16);
            focused.setStroke(dp(3), kind == 2 ? accentText : accent);
            states.addState(new int[]{android.R.attr.state_focused}, focused);
            states.addState(new int[]{}, shape(kind == 2 ? accent : tint, 0, 16));
            button.setBackground(new RippleDrawable(ColorStateList.valueOf(
                kind == 2 ? (accentText & 0x00ffffff) | 0x30000000 : (accent & 0x00ffffff) | 0x20000000),
                states, shape(Color.WHITE, 0, 16)));
            button.setBackgroundTintList(null);
            button.setOnClickListener(v -> nativeEvent(handle, 1, new byte[0]));
            control = button;
            item = button;
        } else if (kind == 3) {
            LinearLayout group = new LinearLayout(this);
            group.setOrientation(LinearLayout.VERTICAL);
            TextView label = text(text, 14, ink, true);
            group.addView(label);
            EditText field = new EditText(this);
            field.setSingleLine(true);
            field.setTextSize(17);
            field.setTextColor(ink);
            field.setHintTextColor(muted);
            field.setHint(text);
            field.setPadding(dp(16), dp(14), dp(16), dp(14));
            field.setMinHeight(dp(56));
            field.setSelectAllOnFocus(false);
            field.setImeOptions(EditorInfo.IME_ACTION_DONE);
            StateListDrawable states = new StateListDrawable();
            GradientDrawable focused = shape(surface, 0, 14);
            focused.setStroke(dp(2), accent);
            states.addState(new int[]{android.R.attr.state_focused}, focused);
            states.addState(new int[]{}, shape(surface, border, 14));
            field.setBackground(states);
            field.setBackgroundTintList(null);
            field.setOnEditorActionListener((view, action, event) -> {
                if (action != EditorInfo.IME_ACTION_DONE) return false;
                ((InputMethodManager) getSystemService(INPUT_METHOD_SERVICE))
                    .hideSoftInputFromWindow(field.getWindowToken(), 0);
                form.requestFocus();
                return true;
            });
            field.addTextChangedListener(new TextWatcher() {
                @Override public void beforeTextChanged(CharSequence s, int start, int count, int after) {}
                @Override public void onTextChanged(CharSequence s, int start, int before, int count) {
                    nativeEvent(handle, 2, s.toString().getBytes(StandardCharsets.UTF_8));
                }
                @Override public void afterTextChanged(Editable value) {}
            });
            field.setId(View.generateViewId());
            label.setLabelFor(field.getId());
            attach(group, field, 8, 0);
            control = field;
            item = group;
            top = 20;
        } else {
            int size = kind == 4 ? 36 : kind == 7 ? 64 : kind == 5 || kind == 6 || kind == 9 ? 12 : 16;
            control = text(text, size, kind == 5 ? muted : kind == 6 || kind == 9 ? accent : ink,
                kind == 4 || kind == 6 || kind == 7 || kind == 9);
            if (kind == 4 || kind == 6) control.setAccessibilityHeading(true);
            if (kind == 5 || kind == 6) control.setLetterSpacing(0.10f);
            if (kind == 4) { control.setLineSpacing(0, 1); top = 16; }
            if (kind == 6) top = 0;
            if (kind == 7) {
                control.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
                control.setLetterSpacing(-0.04f);
            }
            if (kind == 9) {
                control.setPadding(dp(14), dp(9), dp(14), dp(9));
                control.setBackground(shape(tint, 0, 24));
                GradientDrawable dot = shape(accent, 0, 4);
                dot.setBounds(0, 0, dp(6), dp(6));
                control.setCompoundDrawablesRelative(dot, null, null, null);
                control.setCompoundDrawablePadding(dp(8));
                top = 20;
            }
            item = control;
        }
        if (control.getId() == View.NO_ID) control.setId(View.generateViewId());
        controls.add(control);
        attach(parent, item, top, 0);
        if (kind == 9) item.getLayoutParams().width = LinearLayout.LayoutParams.WRAP_CONTENT;
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
        Button primary = null, reset = null;
        EditText field = null;
        for (View view : controls) {
            if (view instanceof Button) {
                if (primary == null) primary = (Button) view;
                else if (reset == null) reset = (Button) view;
            }
            if (view instanceof EditText && field == null) field = (EditText) view;
        }
        if (primary == null || reset == null || field == null)
            throw new IllegalStateException("Android demo controls missing");
        primary.performClick();
        primary.performClick();
        if (!hasLabel("2")) throw new IllegalStateException("Counter did not increment");
        reset.performClick();
        if (!hasLabel("0")) throw new IllegalStateException("Counter did not reset");
        primary.performClick();
        field.setText("W × 😀 世界");
        if (!hasLabel("1") || !hasLabel("W × 😀 世界") || !hasLabel("Active"))
            throw new IllegalStateException("Android W native callback smoke failed");
        field.setText("");
        if (!hasLabel("Hello, friend.")) throw new IllegalStateException("Empty-name fallback missing");
        field.setText("W × 😀 世界");
        if (!smokeRecreated) {
            smokeRecreated = true;
            recreate();
            return;
        }
        Log.i("WAndroid", "android demo native: ok " + getIntent().getStringExtra("w_smoke_token"));
    }
}
