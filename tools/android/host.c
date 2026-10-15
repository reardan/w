/* UI-thread-only JNI bridge. Exported W adapters use the AAPCS64 C ABI.
 * Pass UTF-8 as byte[]: JNI's modified UTF-8 would corrupt supplementary
 * Unicode characters. No callback retains a JNI local reference or text. */
#include <jni.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void *app;
static void (*setup)(void);
static void (*event)(intptr_t, intptr_t, const char *);
static void (*lifecycle)(intptr_t);
static JNIEnv *active_env;
static jobject active_activity;
static jmethodID add_control, set_label;

#ifdef W_ANDROID_PROBES
int wandroid_abi_probe(void);
int wandroid_compiler_probe(const char *root);
#endif

static void fail(JNIEnv *env, const char *message) {
    jclass cls = (*env)->FindClass(env, "java/lang/IllegalStateException");
    if (cls) (*env)->ThrowNew(env, cls, message ? message : "W native bridge failed");
}

static jbyteArray utf8(const char *text) {
    if (!text) text = "";
    size_t size = strlen(text);
    if (size > INT32_MAX) { fail(active_env, "W text is too large"); return NULL; }
    jbyteArray bytes = (*active_env)->NewByteArray(active_env, (jsize)size);
    if (bytes) (*active_env)->SetByteArrayRegion(active_env, bytes, 0, (jsize)size, (const jbyte *)text);
    return bytes;
}

static intptr_t add(int kind, const char *text) {
    if (!active_env || (*active_env)->ExceptionCheck(active_env)) return 0;
    jbyteArray bytes = utf8(text);
    if (!bytes) return 0;
    jlong handle = (*active_env)->CallLongMethod(active_env, active_activity, add_control, (jint)kind, bytes);
    (*active_env)->DeleteLocalRef(active_env, bytes);
    return (intptr_t)handle;
}

intptr_t wandroid_label(const char *text) { return add(1, text); }
intptr_t wandroid_button(const char *text) { return add(2, text); }
intptr_t wandroid_text_field(const char *text) { return add(3, text); }
void wandroid_label_set(intptr_t handle, const char *text) {
    if (!active_env || (*active_env)->ExceptionCheck(active_env)) return;
    jbyteArray bytes = utf8(text);
    if (!bytes) return;
    (*active_env)->CallVoidMethod(active_env, active_activity, set_label, (jlong)handle, bytes);
    (*active_env)->DeleteLocalRef(active_env, bytes);
}

/* Restore context across nested Java -> W -> Java -> W calls. */
#define ENTER() JNIEnv *saved_env = active_env; jobject saved_activity = active_activity; \
    active_env = env; active_activity = activity
#define LEAVE() active_env = saved_env; active_activity = saved_activity

JNIEXPORT void JNICALL Java_org_wlang_androiddemo_WActivity_nativeSetup(JNIEnv *env, jobject activity) {
    if (!app) {
        app = dlopen("libwapp.so", RTLD_NOW | RTLD_LOCAL);
        if (!app) { fail(env, dlerror()); return; }
        setup = (void (*)(void))dlsym(app, "wandroid_setup");
        event = (void (*)(intptr_t, intptr_t, const char *))dlsym(app, "wandroid_event");
        lifecycle = (void (*)(intptr_t))dlsym(app, "wandroid_lifecycle");
    }
    if (!setup || !event || !lifecycle) { fail(env, "Missing wandroid_setup/event/lifecycle export"); return; }
    jclass cls = (*env)->GetObjectClass(env, activity);
    add_control = (*env)->GetMethodID(env, cls, "addControl", "(I[B)J");
    if (!add_control) return;
    set_label = (*env)->GetMethodID(env, cls, "setLabel", "(J[B)V");
    (*env)->DeleteLocalRef(env, cls);
    if (!set_label) return;
    ENTER();
    setup();
    LEAVE();
}

JNIEXPORT void JNICALL Java_org_wlang_androiddemo_WActivity_nativeEvent(
        JNIEnv *env, jobject activity, jlong handle, jlong kind, jbyteArray bytes) {
    if (!event) { fail(env, "W app is not initialized"); return; }
    jsize size = (*env)->GetArrayLength(env, bytes);
    char *text = malloc((size_t)size + 1);
    if (!text) { fail(env, "Cannot allocate callback text"); return; }
    (*env)->GetByteArrayRegion(env, bytes, 0, size, (jbyte *)text);
    text[size] = 0;
    if (!(*env)->ExceptionCheck(env)) {
        ENTER();
        event((intptr_t)handle, (intptr_t)kind, text);
        LEAVE();
    }
    free(text);
}

JNIEXPORT void JNICALL Java_org_wlang_androiddemo_WActivity_nativeLifecycle(
        JNIEnv *env, jobject activity, jlong phase) {
    if (!lifecycle) return;
    ENTER();
    lifecycle((intptr_t)phase);
    LEAVE();
}

JNIEXPORT void JNICALL Java_org_wlang_androiddemo_WActivity_nativeProbes(
        JNIEnv *env, jobject activity, jstring root) {
    (void)activity;
#ifdef W_ANDROID_PROBES
    int result = wandroid_abi_probe();
    if (result) {
        char message[96];
        snprintf(message, sizeof(message), "Android ABI probe failed: %d", result);
        fail(env, message);
        return;
    }
    const char *directory = (*env)->GetStringUTFChars(env, root, NULL);
    if (!directory) return;
    result = wandroid_compiler_probe(directory);
    (*env)->ReleaseStringUTFChars(env, root, directory);
    if (result) {
        char message[96];
        snprintf(message, sizeof(message), "Android compiler probe failed: %d", result);
        fail(env, message);
    }
#else
    (void)root;
    fail(env, "Rebuild APK with --probes to run compiler/ABI probes");
#endif
}
