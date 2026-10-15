/* Optional IDE-companion controls for W (see graphics/android/kit.w).
 * Every export forwards to WActivity.kitCall/kitBytes and from there to
 * WKit.java. Call only during a W callback on the UI thread; host.c supplies
 * that callback's JNI context. Text crosses JNI as UTF-8 byte arrays. */
#include <jni.h>
#include <stdint.h>
#include <string.h>

JNIEnv *wandroid_jni_env(void);
jobject wandroid_jni_activity(void);

/* Keep in sync with WKit.java. */
enum {
    OP_SCREEN = 32, OP_POP, OP_CLEAR, OP_DEPTH, OP_ACTION, OP_TAB, OP_TAB_SELECT, OP_ROW, OP_ROW_END,
    OP_LIST, OP_LIST_CLEAR, OP_LIST_ADD, OP_LIST_SET, OP_TEXT_VIEW, OP_TEXT_AREA, OP_TEXT_SET,
    OP_TEXT_APPEND, OP_ENABLE, OP_SHOW, OP_STYLE, OP_FOCUS, OP_KEYBOARD_HIDE, OP_DIALOG, OP_CHOOSE,
    OP_TOAST, OP_TIMER, OP_TIMER_CANCEL, OP_HTTP, OP_SECURE_PUT, OP_SECURE_DELETE, OP_LOG
};
enum { GET_TEXT = 1, GET_SECURE = 2, GET_URI = 3 };

static jmethodID kit_call, kit_bytes;

static JNIEnv *ready(jobject *activity) {
    JNIEnv *env = wandroid_jni_env();
    *activity = wandroid_jni_activity();
    if (!env || !*activity || (*env)->ExceptionCheck(env)) return NULL;
    if (!kit_call || !kit_bytes) {
        jclass cls = (*env)->GetObjectClass(env, *activity);
        kit_call = (*env)->GetMethodID(env, cls, "kitCall", "(IJJ[B[B[B[B)J");
        if (kit_call) kit_bytes = (*env)->GetMethodID(env, cls, "kitBytes", "(IJ[B)[B");
        (*env)->DeleteLocalRef(env, cls);
        if (!kit_call || !kit_bytes) return NULL;
    }
    return env;
}

static jbyteArray utf8(JNIEnv *env, const char *text) {
    if (!text) return NULL;
    size_t size = strlen(text);
    if (size > INT32_MAX) return NULL;
    jbyteArray bytes = (*env)->NewByteArray(env, (jsize)size);
    if (bytes) (*env)->SetByteArrayRegion(env, bytes, 0, (jsize)size, (const jbyte *)text);
    return bytes;
}

static intptr_t call(int op, intptr_t a, intptr_t b, const char *s, const char *t, const char *u, const char *v) {
    jobject activity;
    JNIEnv *env = ready(&activity);
    if (!env) return 0;
    jbyteArray texts[4] = {utf8(env, s), utf8(env, t), utf8(env, u), utf8(env, v)};
    jlong result = 0;
    if (!(*env)->ExceptionCheck(env))
        result = (*env)->CallLongMethod(env, activity, kit_call, (jint)op, (jlong)a, (jlong)b,
                                        texts[0], texts[1], texts[2], texts[3]);
    for (int i = 0; i < 4; i++) if (texts[i]) (*env)->DeleteLocalRef(env, texts[i]);
    return (intptr_t)result;
}

/* Copies into a W-owned buffer (always NUL-terminated when capacity > 0).
 * Returns the full byte length, or -1 when there is no value. */
static intptr_t query(int op, intptr_t a, const char *s, char *buffer, intptr_t capacity) {
    jobject activity;
    JNIEnv *env = ready(&activity);
    if (!env) return -1;
    jbyteArray key = utf8(env, s);
    jbyteArray value = NULL;
    if (!(*env)->ExceptionCheck(env))
        value = (jbyteArray)(*env)->CallObjectMethod(env, activity, kit_bytes, (jint)op, (jlong)a, key);
    if (key) (*env)->DeleteLocalRef(env, key);
    if (!value || (*env)->ExceptionCheck(env)) return -1;
    jsize size = (*env)->GetArrayLength(env, value);
    if (buffer && capacity > 0) {
        jsize copy = size < capacity ? size : (jsize)(capacity - 1);
        (*env)->GetByteArrayRegion(env, value, 0, copy, (jbyte *)buffer);
        buffer[copy] = 0;
    }
    (*env)->DeleteLocalRef(env, value);
    return size;
}

intptr_t wandroid_screen(const char *title, intptr_t flags) { return call(OP_SCREEN, flags, 0, title, 0, 0, 0); }
void wandroid_screen_pop(void) { call(OP_POP, 0, 0, 0, 0, 0, 0); }
void wandroid_screen_clear(void) { call(OP_CLEAR, 0, 0, 0, 0, 0, 0); }
intptr_t wandroid_screen_depth(void) { return call(OP_DEPTH, 0, 0, 0, 0, 0, 0); }
intptr_t wandroid_action(const char *label) { return call(OP_ACTION, 0, 0, label, 0, 0, 0); }
intptr_t wandroid_tab(const char *label) { return call(OP_TAB, 0, 0, label, 0, 0, 0); }
void wandroid_tab_select(intptr_t tab) { call(OP_TAB_SELECT, tab, 0, 0, 0, 0, 0); }
intptr_t wandroid_row(void) { return call(OP_ROW, 0, 0, 0, 0, 0, 0); }
void wandroid_row_end(void) { call(OP_ROW_END, 0, 0, 0, 0, 0, 0); }
intptr_t wandroid_list(intptr_t flags) { return call(OP_LIST, flags, 0, 0, 0, 0, 0); }
void wandroid_list_clear(intptr_t list) { call(OP_LIST_CLEAR, list, 0, 0, 0, 0, 0); }
intptr_t wandroid_list_add(intptr_t list, const char *title, const char *detail) {
    return call(OP_LIST_ADD, list, 0, title, detail, 0, 0);
}
void wandroid_list_set(intptr_t list, intptr_t index, const char *title, const char *detail) {
    call(OP_LIST_SET, list, index, title, detail, 0, 0);
}
intptr_t wandroid_text_view(const char *text, intptr_t flags) { return call(OP_TEXT_VIEW, flags, 0, text, 0, 0, 0); }
intptr_t wandroid_text_area(const char *hint, intptr_t flags) { return call(OP_TEXT_AREA, flags, 0, hint, 0, 0, 0); }
void wandroid_text_set(intptr_t handle, const char *text) { call(OP_TEXT_SET, handle, 0, text, 0, 0, 0); }
void wandroid_text_append(intptr_t handle, const char *text, intptr_t role) {
    call(OP_TEXT_APPEND, handle, role, text, 0, 0, 0);
}
intptr_t wandroid_text_get(intptr_t handle, char *buffer, intptr_t capacity) {
    return query(GET_TEXT, handle, 0, buffer, capacity);
}
void wandroid_enable(intptr_t handle, intptr_t enabled) { call(OP_ENABLE, handle, enabled, 0, 0, 0, 0); }
void wandroid_show(intptr_t handle, intptr_t visible) { call(OP_SHOW, handle, visible, 0, 0, 0, 0); }
void wandroid_style(intptr_t handle, intptr_t role) { call(OP_STYLE, handle, role, 0, 0, 0, 0); }
void wandroid_focus(intptr_t handle) { call(OP_FOCUS, handle, 0, 0, 0, 0, 0); }
void wandroid_keyboard_hide(void) { call(OP_KEYBOARD_HIDE, 0, 0, 0, 0, 0, 0); }
intptr_t wandroid_dialog(const char *title, const char *message, const char *buttons) {
    return call(OP_DIALOG, 0, 0, title, message, buttons, 0);
}
intptr_t wandroid_choose(const char *title, const char *items) { return call(OP_CHOOSE, 0, 0, title, items, 0, 0); }
void wandroid_toast(const char *text) { call(OP_TOAST, 0, 0, text, 0, 0, 0); }
intptr_t wandroid_timer(intptr_t milliseconds, intptr_t repeat) { return call(OP_TIMER, milliseconds, repeat, 0, 0, 0, 0); }
void wandroid_timer_cancel(intptr_t timer) { call(OP_TIMER_CANCEL, timer, 0, 0, 0, 0, 0); }
intptr_t wandroid_http(const char *method, const char *url, const char *headers, const char *body) {
    return call(OP_HTTP, 0, 0, method, url, headers ? headers : "", body ? body : "");
}
intptr_t wandroid_secure_put(const char *key, const char *value) {
    return call(OP_SECURE_PUT, 0, 0, key, value ? value : "", 0, 0);
}
intptr_t wandroid_secure_get(const char *key, char *buffer, intptr_t capacity) {
    return query(GET_SECURE, 0, key, buffer, capacity);
}
void wandroid_secure_delete(const char *key) { call(OP_SECURE_DELETE, 0, 0, key, 0, 0, 0); }
intptr_t wandroid_intent_uri(char *buffer, intptr_t capacity) { return query(GET_URI, 0, 0, buffer, capacity); }
void wandroid_log(const char *text) { call(OP_LOG, 0, 0, text, 0, 0, 0); }
