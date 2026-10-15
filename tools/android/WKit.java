package org.wlang.androiddemo;

import android.app.AlertDialog;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.res.ColorStateList;
import android.content.res.Configuration;
import android.content.res.TypedArray;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.ColorFilter;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.text.Editable;
import android.text.InputType;
import android.text.Spannable;
import android.text.SpannableStringBuilder;
import android.text.TextUtils;
import android.text.TextWatcher;
import android.text.style.ForegroundColorSpan;
import android.text.style.LineBackgroundSpan;
import android.text.style.StyleSpan;
import android.util.Base64;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowInsets;
import android.view.inputmethod.InputMethodManager;
import android.widget.BaseAdapter;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageButton;
import android.widget.LinearLayout;
import android.widget.ListView;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Iterator;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicLong;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/**
 * Optional IDE-companion controls for W apps: a screen stack with a top bar,
 * bottom tabs, rows, lists, monospace/log text views, multi-line text areas,
 * dialogs, timers, asynchronous HTTP, Keystore-backed secrets and deep links.
 * W reaches it through tools/android/kit.c. Everything runs on the UI thread;
 * HTTP alone uses worker threads and posts results back. Operation codes and
 * event kinds start at 32, leaving lower numbers to the basic control API.
 */
final class WKit {
    // Event kinds delivered through wandroid_event; 1 (click) and 2 (text) are shared.
    static final int EVENT_CLICK = 1, EVENT_TEXT = 2, EVENT_BACK = 32, EVENT_ITEM = 33,
        EVENT_DIALOG = 34, EVENT_TIMER = 35, EVENT_HTTP = 36, EVENT_URI = 37;
    // Keep in sync with kit.c.
    static final int OP_SCREEN = 32, OP_POP = 33, OP_CLEAR = 34, OP_DEPTH = 35, OP_ACTION = 36,
        OP_TAB = 37, OP_TAB_SELECT = 38, OP_ROW = 39, OP_ROW_END = 40, OP_LIST = 41,
        OP_LIST_CLEAR = 42, OP_LIST_ADD = 43, OP_LIST_SET = 44, OP_TEXT_VIEW = 45,
        OP_TEXT_AREA = 46, OP_TEXT_SET = 47, OP_TEXT_APPEND = 48, OP_ENABLE = 49, OP_SHOW = 50,
        OP_STYLE = 51, OP_FOCUS = 52, OP_KEYBOARD_HIDE = 53, OP_DIALOG = 54, OP_CHOOSE = 55,
        OP_TOAST = 56, OP_TIMER = 57, OP_TIMER_CANCEL = 58, OP_HTTP = 59, OP_SECURE_PUT = 60,
        OP_SECURE_DELETE = 61, OP_LOG = 62;
    static final int GET_TEXT = 1, GET_SECURE = 2, GET_URI = 3;
    // Flags and roles, mirrored in graphics/android/kit.w.
    static final int SCREEN_SCROLL = 1;
    static final int TEXT_WRAP = 1, TEXT_DIFF = 2, TEXT_TAIL = 4, TEXT_PROPORTIONAL = 8;
    static final int AREA_MONOSPACE = 1, AREA_FILL = 2, AREA_PLAIN = 4;
    static final int ROLE_BODY = 1, ROLE_TITLE = 2, ROLE_SECONDARY = 3, ROLE_ERROR = 4,
        ROLE_MONOSPACE = 5, ROLE_PRIMARY = 6, ROLE_DESTRUCTIVE = 7, ROLE_URL = 8, ROLE_SECRET = 9,
        ROLE_HEADING = 10;
    private static final int LOG_LIMIT = 200000, HTTP_LIMIT = 8 << 20;
    private static final String SECURE_ALIAS = "w_secure_v1", SECURE_PREFS = "w_secure";

    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static final ExecutorService HTTP = Executors.newFixedThreadPool(3);
    private static final AtomicLong IDS = new AtomicLong();
    // Results that arrive while no Activity is attached (e.g. during recreation).
    private static final ArrayList<Object[]> PENDING = new ArrayList<>();
    private static WKit current;

    private final WActivity activity;
    private boolean installed, destroyed;
    private int background, ink, muted, accent, error, divider, added, removed, addedText, removedText;
    private boolean dark;
    private LinearLayout root, bar, actions, tabs;
    private FrameLayout stage;
    private TextView title;
    private ImageButton up;
    private final ArrayList<Screen> screens = new ArrayList<>();
    private final ArrayList<TextView> tabLabels = new ArrayList<>();
    private final HashMap<Long, Part> parts = new HashMap<>();
    private final HashMap<Long, Runnable> timers = new HashMap<>();
    private final HashMap<Long, AlertDialog> dialogs = new HashMap<>();
    private LinearLayout target;
    private Column column;

    WKit(WActivity activity) {
        this.activity = activity;
        current = this;
        MAIN.post(this::flush);
    }

    private final class Screen {
        View view;
        Column column;
        String title;
        long titleHandle;
        boolean bound;
        final ArrayList<View> actions = new ArrayList<>();
        final ArrayList<Long> parts = new ArrayList<>();
    }

    /** Lists, text views and areas: outer is placed in the layout, inner is the handle's view. */
    private static class Part {
        View outer, inner;
        Screen screen;
        boolean fill, bleed;
        int flags;
    }

    private final class ListPart extends Part {
        final ArrayList<String[]> items = new ArrayList<>();
        BaseAdapter adapter;
    }

    private final class TextPart extends Part {
        ScrollView scroll;
        boolean muted;
    }

    /** Vertical screen content. Children get standard margins; fill parts share free height. */
    private final class Column extends LinearLayout {
        final boolean fixed;
        Column(boolean fixed) {
            super(activity);
            this.fixed = fixed;
            setOrientation(VERTICAL);
            setPadding(0, dp(4), 0, dp(fixed ? 8 : 24));
        }
        @Override public void addView(View child, int index, ViewGroup.LayoutParams params) {
            Part part = partFor(child);
            LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(-1, -2);
            if (part != null && part.bleed) p.setMargins(0, dp(4), 0, 0);
            else p.setMargins(dp(16), dp(10), dp(16), 0);
            if (fixed && part != null && part.fill) { p.height = 0; p.weight = 1; }
            if (params instanceof LinearLayout.LayoutParams && params.width == LinearLayout.LayoutParams.WRAP_CONTENT)
                p.width = LinearLayout.LayoutParams.WRAP_CONTENT;
            super.addView(child, index, p);
        }
    }

    /** Horizontal group with equal-width children, e.g. Allow / Deny / Always. */
    private final class Row extends LinearLayout {
        Row() { super(activity); setOrientation(HORIZONTAL); setGravity(Gravity.CENTER_VERTICAL); }
        @Override public void addView(View child, int index, ViewGroup.LayoutParams params) {
            super.addView(child, index, new LinearLayout.LayoutParams(0, -2, 1));
            // Equal widths, except that a text input takes the space beside its buttons.
            boolean input = false;
            for (int i = 0; i < getChildCount(); i++) input |= getChildAt(i) instanceof EditText;
            for (int i = 0; i < getChildCount(); i++) {
                View view = getChildAt(i);
                boolean grow = !input || view instanceof EditText;
                LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(grow ? 0 : -2, -2, grow ? 1 : 0);
                if (i > 0) p.setMarginStart(dp(8));
                view.setLayoutParams(p);
            }
        }
    }

    private Part partFor(View outer) {
        for (Part part : parts.values()) if (part.outer == outer) return part;
        return null;
    }

    int dp(float value) { return Math.round(value * activity.getResources().getDisplayMetrics().density); }

    private static String str(byte[] bytes) { return bytes == null ? "" : new String(bytes, StandardCharsets.UTF_8); }

    // ---- Entry points from kit.c (synchronous, UI thread) ----

    long call(int op, long a, long b, byte[] s, byte[] t, byte[] u, byte[] v) {
        switch (op) {
            case OP_SCREEN: return push(str(s), (int) a);
            case OP_POP: pop(); return screens.size();
            case OP_CLEAR: while (!screens.isEmpty()) pop(); return 0;
            case OP_DEPTH: return screens.size();
            case OP_ACTION: return action(str(s));
            case OP_TAB: return tab(str(s));
            case OP_TAB_SELECT: selectTab(a); return 0;
            case OP_ROW: return row();
            case OP_ROW_END: rowEnd(); return 0;
            case OP_LIST: return list((int) a);
            case OP_LIST_CLEAR: return listClear(a);
            case OP_LIST_ADD: return listPut(a, -1, str(s), str(t));
            case OP_LIST_SET: return listPut(a, (int) b, str(s), str(t));
            case OP_TEXT_VIEW: return textView(str(s), (int) a);
            case OP_TEXT_AREA: return textArea(str(s), (int) a);
            case OP_TEXT_SET: textSet(a, str(s)); return 0;
            case OP_TEXT_APPEND: textAppend(a, str(s), (int) b); return 0;
            case OP_ENABLE: enable(a, b != 0); return 0;
            case OP_SHOW: show(a, b != 0); return 0;
            case OP_STYLE: style(a, (int) b); return 0;
            case OP_FOCUS: focus(a); return 0;
            case OP_KEYBOARD_HIDE: hideKeyboard(); return 0;
            case OP_DIALOG: return dialog(str(s), str(t), str(u), false);
            case OP_CHOOSE: return dialog(str(s), "", str(t), true);
            case OP_TOAST: Toast.makeText(activity, str(s), Toast.LENGTH_SHORT).show(); return 0;
            case OP_TIMER: return timer(a, b != 0);
            case OP_TIMER_CANCEL: cancelTimer(a); return 0;
            case OP_HTTP: return http(str(s), str(t), str(u), v);
            case OP_SECURE_PUT: return securePut(str(s), t == null ? new byte[0] : t) ? 1 : 0;
            case OP_SECURE_DELETE: prefs().edit().remove(str(s)).apply(); return 0;
            case OP_LOG: Log.i("WAndroid", str(s)); return 0;
            default: throw new IllegalArgumentException("Unknown W kit operation " + op);
        }
    }

    byte[] bytes(int op, long a, byte[] s) {
        if (op == GET_TEXT) {
            View view = viewFor(a);
            return view instanceof TextView ? ((TextView) view).getText().toString().getBytes(StandardCharsets.UTF_8) : null;
        }
        if (op == GET_SECURE) return secureGet(str(s));
        if (op == GET_URI) {
            Uri data = activity.getIntent() == null ? null : activity.getIntent().getData();
            return data == null ? new byte[0] : data.toString().getBytes(StandardCharsets.UTF_8);
        }
        throw new IllegalArgumentException("Unknown W kit query " + op);
    }

    // ---- Activity hooks ----

    /** Back press: W decides once screens are stacked. Returns false to let Android handle it. */
    boolean back() {
        if (screens.size() < 2) return false;
        event(0, EVENT_BACK, new byte[0]);
        return true;
    }

    void newIntent(Intent intent) {
        Uri data = intent == null ? null : intent.getData();
        if (data != null) event(0, EVENT_URI, data.toString().getBytes(StandardCharsets.UTF_8));
    }

    void destroy() {
        destroyed = true;
        for (Runnable timer : timers.values()) MAIN.removeCallbacks(timer);
        timers.clear();
        for (AlertDialog dialog : dialogs.values()) dialog.dismiss();
        dialogs.clear();
        if (current == this) current = null;
    }

    private void event(long handle, int kind, byte[] value) {
        if (!destroyed) activity.kitEvent(handle, kind, value);
    }

    /** Deliver an asynchronous result to whichever Activity is current, or keep it until one is. */
    private static void deliver(long id, int kind, byte[] value) {
        WKit kit = current;
        if (kit == null || kit.destroyed) { PENDING.add(new Object[]{id, kind, value}); return; }
        kit.event(id, kind, value);
    }

    private void flush() {
        if (current != this || destroyed) return;
        ArrayList<Object[]> ready = new ArrayList<>(PENDING);
        PENDING.clear();
        for (Object[] item : ready) event((Long) item[0], (Integer) item[1], (byte[]) item[2]);
    }

    // ---- Window, top bar and tabs ----

    private int attr(int id) {
        TypedArray values = activity.getTheme().obtainStyledAttributes(new int[]{id});
        try { return values.getColor(0, 0); } finally { values.recycle(); }
    }

    private Drawable attrDrawable(int id) {
        TypedArray values = activity.getTheme().obtainStyledAttributes(new int[]{id});
        try { return values.getDrawable(0); } finally { values.recycle(); }
    }

    private static int mix(int color, int alpha) { return (color & 0x00ffffff) | (alpha << 24); }

    private void colors() {
        dark = (activity.getResources().getConfiguration().uiMode & Configuration.UI_MODE_NIGHT_MASK)
            == Configuration.UI_MODE_NIGHT_YES;
        background = attr(android.R.attr.colorBackground);
        ink = attr(android.R.attr.textColorPrimary);
        muted = attr(android.R.attr.textColorSecondary);
        accent = attr(android.R.attr.colorAccent);
        if (background == 0) background = dark ? Color.BLACK : Color.WHITE;
        if (ink == 0) ink = dark ? Color.WHITE : 0xff1f1f1f;
        if (muted == 0) muted = dark ? 0xffb0b0b0 : 0xff5f6368;
        if (accent == 0) accent = dark ? 0xff8ab4f8 : 0xff1a73e8;
        divider = mix(ink, 0x1f);
        error = dark ? 0xffff8a80 : 0xffc5221f;
        added = dark ? 0x3328a745 : 0x2228a745;
        removed = dark ? 0x33e5534b : 0x22d73a49;
        addedText = dark ? 0xff7ee2a8 : 0xff116329;
        removedText = dark ? 0xffffa198 : 0xff82071e;
    }

    /** Replace the basic form with the screen-stack layout on first use. */
    private void install() {
        if (installed) return;
        installed = true;
        colors();
        if (activity.getActionBar() != null) activity.getActionBar().hide();
        root = new LinearLayout(activity);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(background);
        bar = new LinearLayout(activity);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        bar.setMinimumHeight(dp(64));
        bar.setBackgroundColor(background);
        up = new ImageButton(activity);
        up.setImageDrawable(new Arrow(ink, dp(2), dp(24)));
        up.setScaleType(android.widget.ImageView.ScaleType.CENTER);
        up.setPadding(0, 0, 0, 0);
        up.setBackground(attrDrawable(android.R.attr.selectableItemBackgroundBorderless));
        up.setContentDescription("Navigate up");
        up.setOnClickListener(view -> back());
        bar.addView(up, new LinearLayout.LayoutParams(dp(48), dp(48)));
        title = new TextView(activity);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22);
        title.setTextColor(ink);
        title.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        title.setSingleLine(true);
        title.setEllipsize(TextUtils.TruncateAt.END);
        title.setAccessibilityHeading(true);
        LinearLayout.LayoutParams titleParams = new LinearLayout.LayoutParams(0, -2, 1);
        titleParams.setMarginStart(dp(4));
        bar.addView(title, titleParams);
        actions = new LinearLayout(activity);
        actions.setOrientation(LinearLayout.HORIZONTAL);
        actions.setGravity(Gravity.CENTER_VERTICAL);
        bar.addView(actions, new LinearLayout.LayoutParams(-2, -2));
        bar.setPadding(dp(4), 0, dp(4), 0);
        root.addView(bar, new LinearLayout.LayoutParams(-1, -2));
        stage = new FrameLayout(activity);
        root.addView(stage, new LinearLayout.LayoutParams(-1, 0, 1));
        tabs = new LinearLayout(activity);
        tabs.setOrientation(LinearLayout.HORIZONTAL);
        tabs.setBackgroundColor(background);
        View rule = new View(activity);
        rule.setBackgroundColor(divider);
        LinearLayout bottom = new LinearLayout(activity);
        bottom.setOrientation(LinearLayout.VERTICAL);
        bottom.addView(rule, new LinearLayout.LayoutParams(-1, Math.max(1, dp(0.5f))));
        bottom.addView(tabs, new LinearLayout.LayoutParams(-1, -2));
        bottom.setVisibility(View.GONE);
        root.addView(bottom, new LinearLayout.LayoutParams(-1, -2));
        edgeToEdge();
        root.setOnApplyWindowInsetsListener((view, insets) -> {
            int left, top, right, bottomBar, ime;
            if (Build.VERSION.SDK_INT >= 30) {
                android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                left = bars.left; top = bars.top; right = bars.right; bottomBar = bars.bottom;
                ime = insets.getInsets(WindowInsets.Type.ime()).bottom;
            } else {
                left = insets.getSystemWindowInsetLeft(); top = insets.getSystemWindowInsetTop();
                right = insets.getSystemWindowInsetRight(); bottomBar = insets.getStableInsetBottom();
                ime = insets.getSystemWindowInsetBottom() > bottomBar ? insets.getSystemWindowInsetBottom() : 0;
            }
            boolean typing = ime > bottomBar;
            bar.setPadding(left + dp(4), top, right + dp(4), 0);
            boolean showTabs = !tabLabels.isEmpty() && !typing;
            ((View) tabs.getParent()).setVisibility(showTabs ? View.VISIBLE : View.GONE);
            tabs.setPadding(left, 0, right, bottomBar);
            stage.setPadding(left, 0, right, typing ? ime : showTabs ? 0 : bottomBar);
            return insets;
        });
        activity.setContentView(root);
        root.requestApplyInsets();
    }

    private void edgeToEdge() {
        Window window = activity.getWindow();
        window.getDecorView(); // Samsung needs the decor before the insets controller.
        window.setStatusBarColor(Color.TRANSPARENT);
        window.setNavigationBarColor(background);
        if (Build.VERSION.SDK_INT >= 29) {
            window.setStatusBarContrastEnforced(false);
            window.setNavigationBarContrastEnforced(false);
        }
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false);
            int light = android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
                | android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
            window.getInsetsController().setSystemBarsAppearance(dark ? 0 : light, light);
        } else {
            window.getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                | (dark ? 0 : View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR));
        }
    }

    /** Navigate-up arrow drawn as a path; the platform exposes no public arrow drawable. */
    private static final class Arrow extends Drawable {
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final int size;
        Arrow(int color, int width, int size) {
            this.size = size;
            paint.setColor(color);
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(width);
            paint.setStrokeCap(Paint.Cap.ROUND);
            paint.setStrokeJoin(Paint.Join.ROUND);
        }
        @Override public void draw(Canvas canvas) {
            Rect b = getBounds();
            float cx = b.exactCenterX(), cy = b.exactCenterY(), h = Math.min(b.width(), b.height()) * 0.33f;
            Path path = new Path();
            path.moveTo(cx + h, cy);
            path.lineTo(cx - h, cy);
            path.moveTo(cx - h * 0.1f, cy - h * 0.9f);
            path.lineTo(cx - h, cy);
            path.lineTo(cx - h * 0.1f, cy + h * 0.9f);
            canvas.drawPath(path, paint);
        }
        @Override public int getIntrinsicWidth() { return size; }
        @Override public int getIntrinsicHeight() { return size; }
        @Override public void setAlpha(int alpha) { paint.setAlpha(alpha); }
        @Override public void setColorFilter(ColorFilter filter) { paint.setColorFilter(filter); }
        @Override public int getOpacity() { return PixelFormat.TRANSLUCENT; }
    }

    private void refreshBar() {
        Screen top = screens.isEmpty() ? null : screens.get(screens.size() - 1);
        title.setText(top == null ? "" : top.title);
        up.setVisibility(screens.size() > 1 ? View.VISIBLE : View.GONE);
        title.setPadding(screens.size() > 1 ? 0 : dp(12), 0, 0, 0);
        actions.removeAllViews();
        if (top != null) for (View action : top.actions) actions.addView(action, new LinearLayout.LayoutParams(-2, dp(48)));
    }

    // ---- Screens ----

    private long push(String text, int flags) {
        install();
        hideKeyboard();
        Screen screen = new Screen();
        screen.title = text;
        boolean scroll = (flags & SCREEN_SCROLL) != 0;
        screen.column = new Column(!scroll);
        if (scroll) {
            ScrollView scrollView = new ScrollView(activity);
            scrollView.setFillViewport(true);
            scrollView.addView(screen.column, new FrameLayout.LayoutParams(-1, -2));
            screen.view = scrollView;
        } else screen.view = screen.column;
        if (!screens.isEmpty()) screens.get(screens.size() - 1).view.setVisibility(View.GONE);
        screens.add(screen);
        stage.addView(screen.view, new FrameLayout.LayoutParams(-1, -1));
        screen.view.setAlpha(0f);
        screen.view.animate().alpha(1f).setDuration(120).start();
        // The title is a label: wandroid_label_set renames the screen.
        TextView proxy = new TextView(activity) {
            @Override public void setText(CharSequence value, BufferType type) {
                super.setText(value, type);
                if (screen != null && screen.bound) {
                    screen.title = value.toString();
                    if (!screens.isEmpty() && screens.get(screens.size() - 1) == screen) title.setText(value);
                }
            }
        };
        screen.titleHandle = activity.kitRegister(proxy);
        screen.bound = true;
        setTarget(screen.column);
        refreshBar();
        return screen.titleHandle;
    }

    private void pop() {
        if (screens.isEmpty()) return;
        hideKeyboard();
        Screen screen = screens.remove(screens.size() - 1);
        stage.removeView(screen.view);
        // Drop retained text and items; handles stay valid but detached.
        for (Long handle : screen.parts) {
            Part part = parts.remove(handle);
            if (part instanceof ListPart) ((ListPart) part).items.clear();
            if (part instanceof TextPart && !(part.inner instanceof EditText)) ((TextView) part.inner).setText("");
        }
        if (!screens.isEmpty()) {
            Screen top = screens.get(screens.size() - 1);
            top.view.setVisibility(View.VISIBLE);
            setTarget(top.column);
        } else setTarget(null);
        refreshBar();
    }

    private void setTarget(LinearLayout container) {
        if (container == null || container instanceof Column) column = (Column) container;
        target = container;
        if (container != null) activity.kitTarget(container);
    }

    private Screen top() {
        if (screens.isEmpty()) throw new IllegalStateException("Push a W screen first");
        return screens.get(screens.size() - 1);
    }

    private Button textButton(String text) {
        Button button = new Button(activity, null, android.R.attr.borderlessButtonStyle);
        button.setText(text);
        button.setAllCaps(false);
        button.setTextColor(accent);
        button.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        button.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        button.setMinWidth(dp(48));
        button.setMinimumWidth(dp(48));
        button.setPadding(dp(12), 0, dp(12), 0);
        return button;
    }

    private long action(String text) {
        Screen screen = top();
        Button button = textButton(text);
        long handle = activity.kitRegister(button);
        button.setOnClickListener(view -> event(handle, EVENT_CLICK, new byte[0]));
        screen.actions.add(button);
        refreshBar();
        return handle;
    }

    private long tab(String text) {
        install();
        FrameLayout cell = new FrameLayout(activity);
        cell.setBackground(attrDrawable(android.R.attr.selectableItemBackground));
        TextView label = new TextView(activity);
        label.setText(text);
        label.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        label.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        label.setTextColor(muted);
        label.setGravity(Gravity.CENTER);
        label.setPadding(dp(16), dp(6), dp(16), dp(6));
        label.setSingleLine(true);
        cell.addView(label, new FrameLayout.LayoutParams(-2, -2, Gravity.CENTER));
        long handle = activity.kitRegister(label);
        cell.setOnClickListener(view -> event(handle, EVENT_CLICK, new byte[0]));
        cell.setContentDescription(text);
        tabs.addView(cell, new LinearLayout.LayoutParams(0, dp(64), 1));
        tabLabels.add(label);
        root.requestApplyInsets();
        return handle;
    }

    private void selectTab(long handle) {
        View selected = viewFor(handle);
        for (TextView label : tabLabels) {
            boolean on = label == selected;
            label.setTextColor(on ? ink : muted);
            label.setBackground(on ? shape(mix(accent, dark ? 0x40 : 0x26), 0, 16) : null);
            ((View) label.getParent()).setSelected(on);
        }
    }

    private long row() {
        top();
        Row row = new Row();
        long handle = activity.kitRegister(row);
        column.addView(row);
        setTarget(row);
        return handle;
    }

    private void rowEnd() {
        if (column != null) setTarget(column);
    }

    private void place(Part part, long handle) {
        Screen screen = top();
        part.screen = screen;
        parts.put(handle, part);
        screen.parts.add(handle);
        target.addView(part.outer);
    }

    // ---- Lists ----

    private final class ExpandingList extends ListView {
        final boolean fixed;
        ExpandingList(boolean fixed) { super(activity); this.fixed = fixed; }
        @Override protected void onMeasure(int width, int height) {
            // Inside a scrolling screen, show every row and let the screen scroll.
            if (!fixed) height = View.MeasureSpec.makeMeasureSpec(Integer.MAX_VALUE >> 2, View.MeasureSpec.AT_MOST);
            super.onMeasure(width, height);
        }
    }

    private long list(int flags) {
        Screen screen = top();
        ListPart part = new ListPart();
        ListView view = new ExpandingList(screen.column.fixed && target == screen.column);
        view.setDivider(new android.graphics.drawable.ColorDrawable(divider));
        view.setDividerHeight(Math.max(1, dp(0.5f)));
        view.setClipToPadding(false);
        view.setPadding(0, 0, 0, dp(8));
        part.adapter = new BaseAdapter() {
            @Override public int getCount() { return part.items.size(); }
            @Override public Object getItem(int position) { return part.items.get(position); }
            @Override public long getItemId(int position) { return position; }
            @Override public View getView(int position, View reuse, ViewGroup parent) {
                LinearLayout cell = reuse instanceof LinearLayout ? (LinearLayout) reuse : listCell();
                String[] item = part.items.get(position);
                TextView first = (TextView) cell.getChildAt(0), second = (TextView) cell.getChildAt(1);
                first.setText(item[0]);
                second.setText(item[1]);
                second.setVisibility(item[1].isEmpty() ? View.GONE : View.VISIBLE);
                cell.setMinimumHeight(dp(item[1].isEmpty() ? 56 : 72));
                return cell;
            }
        };
        view.setAdapter(part.adapter);
        part.outer = part.inner = view;
        part.fill = true;
        part.bleed = true;
        part.flags = flags;
        long handle = activity.kitRegister(view);
        view.setOnItemClickListener((parent, item, position, id) ->
            event(handle, EVENT_ITEM, Integer.toString(position).getBytes(StandardCharsets.UTF_8)));
        place(part, handle);
        return handle;
    }

    private LinearLayout listCell() {
        LinearLayout cell = new LinearLayout(activity);
        cell.setOrientation(LinearLayout.VERTICAL);
        cell.setGravity(Gravity.CENTER_VERTICAL);
        cell.setPadding(dp(20), dp(10), dp(20), dp(10));
        TextView first = new TextView(activity), second = new TextView(activity);
        first.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        first.setTextColor(ink);
        first.setMaxLines(2);
        first.setEllipsize(TextUtils.TruncateAt.MIDDLE);
        second.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        second.setTextColor(muted);
        second.setMaxLines(2);
        second.setEllipsize(TextUtils.TruncateAt.END);
        second.setPadding(0, dp(2), 0, 0);
        cell.addView(first, new LinearLayout.LayoutParams(-1, -2));
        cell.addView(second, new LinearLayout.LayoutParams(-1, -2));
        return cell;
    }

    private long listClear(long handle) {
        Part part = parts.get(handle);
        if (!(part instanceof ListPart)) return 0;
        ((ListPart) part).items.clear();
        ((ListPart) part).adapter.notifyDataSetChanged();
        return 0;
    }

    private long listPut(long handle, int index, String first, String second) {
        Part part = parts.get(handle);
        if (!(part instanceof ListPart)) return -1;
        ArrayList<String[]> items = ((ListPart) part).items;
        String[] item = new String[]{first, second};
        if (index < 0) { items.add(item); index = items.size() - 1; }
        else if (index < items.size()) items.set(index, item);
        else return -1;
        ((ListPart) part).adapter.notifyDataSetChanged();
        return index;
    }

    // ---- Text views and areas ----

    private long textView(String text, int flags) {
        Screen screen = top();
        boolean fixed = screen.column.fixed && target == screen.column;
        TextPart part = new TextPart();
        TextView view = new TextView(activity);
        view.setTextIsSelectable(true);
        view.setTextColor(ink);
        boolean mono = (flags & TEXT_PROPORTIONAL) == 0;
        view.setTypeface(mono ? Typeface.MONOSPACE : Typeface.DEFAULT);
        view.setTextSize(TypedValue.COMPLEX_UNIT_SP, mono ? 13 : 16);
        view.setLineSpacing(dp(mono ? 2 : 4), 1);
        view.setPadding(dp(16), dp(12), dp(16), dp(16));
        view.setHorizontallyScrolling((flags & TEXT_WRAP) == 0);
        View content = view;
        if ((flags & TEXT_WRAP) == 0) {
            HorizontalScrollView sideways = new HorizontalScrollView(activity);
            sideways.setFillViewport(true);
            sideways.addView(view, new FrameLayout.LayoutParams(-2, -2));
            content = sideways;
        }
        if (fixed) {
            ScrollView scroll = new ScrollView(activity);
            scroll.setFillViewport(true);
            scroll.addView(content, new FrameLayout.LayoutParams(-1, -2));
            part.scroll = scroll;
            content = scroll;
        }
        part.outer = content;
        part.inner = view;
        part.fill = true;
        part.bleed = true;
        part.flags = flags;
        view.setText("", TextView.BufferType.EDITABLE);
        long handle = activity.kitRegister(view);
        place(part, handle);
        textSet(handle, text);
        return handle;
    }

    private long textArea(String hint, int flags) {
        Screen screen = top();
        TextPart part = new TextPart();
        EditText area = new EditText(activity);
        area.setHint(hint);
        area.setGravity(Gravity.TOP | Gravity.START);
        int type = InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE;
        if ((flags & (AREA_MONOSPACE | AREA_PLAIN)) == 0) type |= InputType.TYPE_TEXT_FLAG_CAP_SENTENCES | InputType.TYPE_TEXT_FLAG_AUTO_CORRECT;
        else type |= InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS;
        area.setInputType(type);
        area.setHorizontallyScrolling(false);
        area.setMinLines(2);
        if ((flags & AREA_FILL) == 0) area.setMaxLines(6);
        if ((flags & AREA_MONOSPACE) != 0) {
            area.setTypeface(Typeface.MONOSPACE);
            area.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        } else area.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        area.setTextColor(ink);
        area.setHintTextColor(muted);
        area.setPadding(dp(14), dp(12), dp(14), dp(12));
        android.graphics.drawable.StateListDrawable states = new android.graphics.drawable.StateListDrawable();
        states.addState(new int[]{android.R.attr.state_focused}, shape(0, accent, 12, 2));
        states.addState(new int[]{}, shape(0, mix(ink, 0x50), 12, 1));
        area.setBackground(states);
        part.outer = part.inner = area;
        part.fill = (flags & AREA_FILL) != 0;
        part.flags = flags;
        long handle = activity.kitRegister(area);
        area.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int start, int count, int after) {}
            @Override public void onTextChanged(CharSequence s, int start, int before, int count) {
                if (!part.muted) event(handle, EVENT_TEXT, s.toString().getBytes(StandardCharsets.UTF_8));
            }
            @Override public void afterTextChanged(Editable value) {}
        });
        place(part, handle);
        return handle;
    }

    private View viewFor(long handle) {
        Part part = parts.get(handle);
        return part != null ? part.inner : activity.kitView(handle);
    }

    private View outerFor(long handle) {
        Part part = parts.get(handle);
        return part != null ? part.outer : activity.kitView(handle);
    }

    private void textSet(long handle, String text) {
        Part part = parts.get(handle);
        View view = viewFor(handle);
        if (!(view instanceof TextView)) return;
        if (part instanceof TextPart && !(view instanceof EditText)) {
            TextView textView = (TextView) view;
            CharSequence value = (part.flags & TEXT_DIFF) != 0 ? diff(text) : text;
            textView.setText(value, TextView.BufferType.EDITABLE);
            TextPart textPart = (TextPart) part;
            if (textPart.scroll != null) {
                if ((part.flags & TEXT_TAIL) != 0) textPart.scroll.post(() -> textPart.scroll.scrollTo(0, Integer.MAX_VALUE >> 2));
                else textPart.scroll.scrollTo(0, 0);
            }
            return;
        }
        if (part instanceof TextPart) ((TextPart) part).muted = true;
        try {
            ((TextView) view).setText(text);
            if (view instanceof EditText) ((EditText) view).setSelection(((EditText) view).length());
        } finally {
            if (part instanceof TextPart) ((TextPart) part).muted = false;
        }
    }

    private void textAppend(long handle, String text, int role) {
        Part part = parts.get(handle);
        if (!(part instanceof TextPart) || part.inner instanceof EditText) return;
        TextView view = (TextView) part.inner;
        ScrollView scroll = ((TextPart) part).scroll;
        boolean follow = scroll != null && scroll.getChildCount() > 0
            && scroll.getScrollY() + scroll.getHeight() >= scroll.getChildAt(0).getHeight() - dp(64);
        Editable buffer = view.getEditableText();
        if (buffer == null) { view.setText(view.getText(), TextView.BufferType.EDITABLE); buffer = view.getEditableText(); }
        int start = buffer.length();
        buffer.append(text);
        int end = buffer.length();
        if (role == ROLE_HEADING || role == ROLE_TITLE) {
            buffer.setSpan(new StyleSpan(Typeface.BOLD), start, end, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
            if (role == ROLE_TITLE) buffer.setSpan(new ForegroundColorSpan(accent), start, end, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
        } else if (role == ROLE_SECONDARY) buffer.setSpan(new ForegroundColorSpan(muted), start, end, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
        else if (role == ROLE_ERROR) buffer.setSpan(new ForegroundColorSpan(error), start, end, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
        if (buffer.length() > LOG_LIMIT) {
            int cut = buffer.length() - LOG_LIMIT * 9 / 10;
            while (cut < buffer.length() && buffer.charAt(cut - 1) != '\n') cut++;
            buffer.delete(0, cut);
        }
        if ((part.flags & TEXT_TAIL) != 0 && scroll != null && (follow || start == 0))
            scroll.post(() -> scroll.scrollTo(0, Integer.MAX_VALUE >> 2));
    }

    /** Full-width tint behind added/removed diff lines. */
    private static final class LineTint implements LineBackgroundSpan {
        private final int color;
        LineTint(int color) { this.color = color; }
        @Override public void drawBackground(Canvas canvas, Paint paint, int left, int right, int top, int baseline,
                                             int bottom, CharSequence text, int start, int end, int line) {
            int saved = paint.getColor();
            paint.setColor(color);
            canvas.drawRect(left, top, Math.max(right, canvas.getWidth()), bottom, paint);
            paint.setColor(saved);
        }
    }

    private CharSequence diff(String text) {
        SpannableStringBuilder styled = new SpannableStringBuilder(text);
        int start = 0, length = text.length();
        while (start < length) {
            int end = text.indexOf('\n', start);
            if (end < 0) end = length;
            int stop = Math.min(end + 1, length);
            if (text.startsWith("+++", start) || text.startsWith("---", start) || text.startsWith("diff ", start)
                    || text.startsWith("index ", start)) {
                styled.setSpan(new ForegroundColorSpan(muted), start, end, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
                styled.setSpan(new StyleSpan(Typeface.BOLD), start, end, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
            } else if (text.startsWith("@@", start)) {
                styled.setSpan(new ForegroundColorSpan(accent), start, end, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
            } else if (end > start && text.charAt(start) == '+') {
                styled.setSpan(new ForegroundColorSpan(addedText), start, end, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
                styled.setSpan(new LineTint(added), start, stop, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
            } else if (end > start && text.charAt(start) == '-') {
                styled.setSpan(new ForegroundColorSpan(removedText), start, end, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
                styled.setSpan(new LineTint(removed), start, stop, Spannable.SPAN_EXCLUSIVE_EXCLUSIVE);
            }
            start = end + 1;
        }
        return styled;
    }

    // ---- Generic view operations ----

    private void enable(long handle, boolean enabled) {
        View view = viewFor(handle);
        if (view == null) return;
        view.setEnabled(enabled);
        if (view instanceof Button && view.getTag() instanceof Integer) view.setAlpha(enabled ? 1f : 0.45f);
    }

    private void show(long handle, boolean visible) {
        View view = outerFor(handle);
        if (view != null) view.setVisibility(visible ? View.VISIBLE : View.GONE);
    }

    private GradientDrawable shape(int fill, int stroke, int radius) { return shape(fill, stroke, radius, 1); }

    private GradientDrawable shape(int fill, int stroke, int radius, int width) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(fill);
        drawable.setCornerRadius(dp(radius));
        if (stroke != 0) drawable.setStroke(dp(width), stroke);
        return drawable;
    }

    private static double luminance(int color) {
        return (0.2126 * Color.red(color) + 0.7152 * Color.green(color) + 0.0722 * Color.blue(color)) / 255;
    }

    private void style(long handle, int role) {
        View view = viewFor(handle);
        if (!(view instanceof TextView)) return;
        TextView text = (TextView) view;
        if (view instanceof Button) {
            Button button = (Button) view;
            button.setAllCaps(false);
            button.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
            button.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
            button.setMinHeight(dp(48));
            button.setMinimumHeight(dp(48));
            button.setStateListAnimator(null);
            button.setPadding(dp(16), dp(10), dp(16), dp(10));
            int fill = role == ROLE_PRIMARY ? accent : mix(role == ROLE_DESTRUCTIVE ? error : accent, dark ? 0x33 : 0x1c);
            int label = role == ROLE_PRIMARY ? (luminance(accent) > 0.6 ? 0xff101010 : Color.WHITE)
                : role == ROLE_DESTRUCTIVE ? error : dark ? ink : accent;
            button.setTextColor(new ColorStateList(new int[][]{{-android.R.attr.state_enabled}, {}},
                new int[]{mix(label, 0x80), label}));
            button.setBackground(new RippleDrawable(ColorStateList.valueOf(mix(label, 0x30)),
                shape(fill, 0, 24), shape(Color.WHITE, 0, 24)));
            button.setTag(role);
            return;
        }
        if (view instanceof EditText) {
            EditText field = (EditText) view;
            if (role == ROLE_URL) field.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI
                | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
            else if (role == ROLE_SECRET) {
                field.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
                field.setTypeface(Typeface.MONOSPACE);
            } else if (role == ROLE_MONOSPACE) field.setTypeface(Typeface.MONOSPACE);
            return;
        }
        text.setTypeface(Typeface.DEFAULT);
        text.setTextColor(ink);
        switch (role) {
            case ROLE_TITLE: text.setTextSize(TypedValue.COMPLEX_UNIT_SP, 20);
                text.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
                text.setAccessibilityHeading(true); break;
            case ROLE_HEADING: text.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
                text.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
                text.setTextColor(accent); text.setAccessibilityHeading(true); break;
            case ROLE_SECONDARY: text.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14); text.setTextColor(muted); break;
            case ROLE_ERROR: text.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14); text.setTextColor(error);
                text.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE); break;
            case ROLE_MONOSPACE: text.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13); text.setTypeface(Typeface.MONOSPACE); break;
            default: text.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        }
    }

    private void focus(long handle) {
        View view = viewFor(handle);
        if (view == null || !view.requestFocus()) return;
        if (view instanceof EditText)
            ((InputMethodManager) activity.getSystemService(Context.INPUT_METHOD_SERVICE)).showSoftInput(view, 0);
    }

    private void hideKeyboard() {
        View focused = activity.getCurrentFocus();
        if (focused == null) return;
        ((InputMethodManager) activity.getSystemService(Context.INPUT_METHOD_SERVICE))
            .hideSoftInputFromWindow(focused.getWindowToken(), 0);
        focused.clearFocus();
    }

    // ---- Dialogs ----

    private long dialog(String heading, String message, String choices, boolean list) {
        long id = IDS.incrementAndGet();
        String[] labels = choices.isEmpty() ? new String[]{"OK"} : choices.split("\n", -1);
        AlertDialog.Builder builder = new AlertDialog.Builder(activity);
        if (!heading.isEmpty()) builder.setTitle(heading);
        final boolean[] answered = {false};
        android.content.DialogInterface.OnClickListener answer = (d, which) -> {
            if (answered[0]) return;
            answered[0] = true;
            int index = list ? which : which == AlertDialog.BUTTON_POSITIVE ? 0 : which == AlertDialog.BUTTON_NEGATIVE ? 1 : 2;
            dialogs.remove(id);
            event(id, EVENT_DIALOG, Integer.toString(index).getBytes(StandardCharsets.UTF_8));
        };
        if (list) {
            builder.setItems(labels, answer);
            builder.setNegativeButton("Cancel", null);
        } else {
            if (!message.isEmpty()) builder.setMessage(message);
            builder.setPositiveButton(labels[0], answer);
            if (labels.length > 1) builder.setNegativeButton(labels[1], answer);
            if (labels.length > 2) builder.setNeutralButton(labels[2], answer);
        }
        AlertDialog dialog = builder.create();
        dialog.setOnDismissListener(d -> {
            dialogs.remove(id);
            if (answered[0] || destroyed) return;
            answered[0] = true;
            event(id, EVENT_DIALOG, "-1".getBytes(StandardCharsets.UTF_8));
        });
        dialogs.put(id, dialog);
        dialog.show();
        return id;
    }

    // ---- Timers ----

    private long timer(long ms, boolean repeat) {
        long id = IDS.incrementAndGet();
        long delay = Math.max(0, ms);
        Runnable tick = new Runnable() {
            @Override public void run() {
                if (repeat) MAIN.postDelayed(this, Math.max(16, delay));
                else timers.remove(id);
                event(id, EVENT_TIMER, new byte[0]);
            }
        };
        timers.put(id, tick);
        MAIN.postDelayed(tick, delay);
        return id;
    }

    private void cancelTimer(long id) {
        Runnable tick = timers.remove(id);
        if (tick != null) MAIN.removeCallbacks(tick);
    }

    // ---- HTTP ----

    /** Value delivered to W: "STATUS\nBODY". Status 0 means no HTTP response; BODY explains why. */
    private long http(String method, String url, String headers, byte[] body) {
        long id = IDS.incrementAndGet();
        HTTP.execute(() -> {
            int status = 0;
            byte[] payload;
            HttpURLConnection connection = null;
            try {
                connection = (HttpURLConnection) new URL(url).openConnection();
                connection.setInstanceFollowRedirects(false); // Never forward credentials elsewhere.
                connection.setUseCaches(false);
                connection.setConnectTimeout(10000);
                connection.setReadTimeout(30000);
                connection.setRequestMethod(method.isEmpty() ? "GET" : method);
                for (String line : headers.split("\n")) {
                    int colon = line.indexOf(':');
                    if (colon > 0) connection.setRequestProperty(line.substring(0, colon).trim(), line.substring(colon + 1).trim());
                }
                if (body != null && (body.length > 0 || "POST".equals(method) || "PUT".equals(method))) {
                    connection.setDoOutput(true);
                    connection.setFixedLengthStreamingMode(body.length);
                    try (OutputStream output = connection.getOutputStream()) { output.write(body); }
                }
                status = connection.getResponseCode();
                InputStream input = status >= 400 ? connection.getErrorStream() : connection.getInputStream();
                payload = read(input);
                if (payload == null) { status = 0; payload = "Response exceeds 8 MiB".getBytes(StandardCharsets.UTF_8); }
            } catch (IOException | RuntimeException failure) {
                status = 0;
                String message = failure.getMessage();
                payload = (failure.getClass().getSimpleName() + (message == null ? "" : ": " + message)).getBytes(StandardCharsets.UTF_8);
            } finally {
                if (connection != null) connection.disconnect();
            }
            byte[] prefix = (status + "\n").getBytes(StandardCharsets.UTF_8);
            byte[] value = new byte[prefix.length + payload.length];
            System.arraycopy(prefix, 0, value, 0, prefix.length);
            System.arraycopy(payload, 0, value, prefix.length, payload.length);
            MAIN.post(() -> deliver(id, EVENT_HTTP, value));
        });
        return id;
    }

    private static byte[] read(InputStream input) throws IOException {
        if (input == null) return new byte[0];
        try (InputStream in = input) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buffer = new byte[16384];
            int count;
            while ((count = in.read(buffer)) != -1) {
                if (out.size() + count > HTTP_LIMIT) return null;
                out.write(buffer, 0, count);
            }
            return out.toByteArray();
        }
    }

    // ---- Secrets: AES-GCM key in AndroidKeyStore, ciphertext in private SharedPreferences ----

    private SharedPreferences prefs() { return activity.getSharedPreferences(SECURE_PREFS, Context.MODE_PRIVATE); }

    private static SecretKey secureKey() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        if (store.containsAlias(SECURE_ALIAS)) return (SecretKey) store.getKey(SECURE_ALIAS, null);
        KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(SECURE_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256).build());
        return generator.generateKey();
    }

    private boolean securePut(String name, byte[] value) {
        try {
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.ENCRYPT_MODE, secureKey());
            cipher.updateAAD(name.getBytes(StandardCharsets.UTF_8)); // Bind ciphertext to its name.
            byte[] sealed = cipher.doFinal(value);
            String stored = Base64.encodeToString(cipher.getIV(), Base64.NO_WRAP) + ":"
                + Base64.encodeToString(sealed, Base64.NO_WRAP);
            return prefs().edit().putString(name, stored).commit();
        } catch (Exception failure) {
            Log.w("WAndroid", "secure store failed: " + failure);
            return false;
        }
    }

    private byte[] secureGet(String name) {
        String stored = prefs().getString(name, null);
        if (stored == null) return null;
        try {
            int colon = stored.indexOf(':');
            byte[] iv = Base64.decode(stored.substring(0, colon), Base64.NO_WRAP);
            byte[] sealed = Base64.decode(stored.substring(colon + 1), Base64.NO_WRAP);
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, secureKey(), new GCMParameterSpec(128, iv));
            cipher.updateAAD(name.getBytes(StandardCharsets.UTF_8));
            return cipher.doFinal(sealed);
        } catch (Exception failure) {
            Log.w("WAndroid", "secure read failed: " + failure);
            return null;
        }
    }
}
