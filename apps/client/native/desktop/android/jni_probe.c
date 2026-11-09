// On-device negative-path probe for libatermius_rdp.so (not packaged in the
// APK). Run from adb shell, where no JavaVM ever loaded the engine:
//   jni_probe /path/to/libatermius_rdp.so <existing writable dir>
// It must report that the engine exports JNI_OnLoad and refuses to start
// without a registered JavaVM (set_home 0, create NULL) instead of aborting
// in WinPR's JNI assertion. Exit 0 only when every check holds.
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>

typedef int (*set_home_fn)(const char*);
typedef void* (*create_fn)(const char*, int, const char*, const char*, const char*);
typedef uint32_t (*features_fn)(void);

static int failed = 0;
static void check(const char* name, int ok) {
  printf("%s %s\n", ok ? "ok" : "FAIL", name);
  if (!ok) failed = 1;
}

int main(int argc, char** argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s libatermius_rdp.so writable-dir\n", argv[0]);
    return 2;
  }
  void* engine = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  check("dlopen", engine != NULL);
  if (!engine) {
    fprintf(stderr, "%s\n", dlerror());
    return 1;
  }
  check("exports JNI_OnLoad", dlsym(engine, "JNI_OnLoad") != NULL);
  set_home_fn set_home = (set_home_fn)dlsym(engine, "aterm_rdp_set_home");
  create_fn create = (create_fn)dlsym(engine, "aterm_rdp_create");
  features_fn features = (features_fn)dlsym(engine, "aterm_rdp_features");
  check("exports engine ABI", set_home && create && features);
  if (!set_home || !create || !features) return 1;
  check("features without JavaVM", (features() & 1u) != 0);
  check("set_home refused without JavaVM", set_home(argv[2]) == 0);
  // A loopback target that is never contacted: creation must stop first.
  check("create refused without JavaVM", create("127.0.0.1", 9, "probe", "probe", "") == NULL);
  printf("%s\n", failed ? "FAILED" : "PASSED");
  return failed;
}
