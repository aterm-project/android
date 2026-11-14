// Atermius direct RDP engine. Each instance belongs to one Dart worker isolate.
// FreeRDP (Apache-2.0) performs protocol negotiation, NLA, TLS, raster decoding
// and the device/audio/camera virtual channels.
#include <stdlib.h>
#include <stdio.h>
#include <ctype.h>
#include <string.h>
#include <limits.h>
#include <freerdp/freerdp.h>
#include <freerdp/settings.h>
#include <freerdp/addin.h>
#include <freerdp/client/channels.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/graphics.h>
#include <freerdp/codec/color.h>
#include <freerdp/input.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/disp.h>
#if defined(ATERMIUS_RDP_NATIVE_TOUCH)
#include <freerdp/client/rdpei.h>
#endif
#include <freerdp/client/cliprdr.h>
#include <freerdp/channels/channels.h>
#include <freerdp/channels/rdpdr.h>
#include <winpr/synch.h>
#include <winpr/wlog.h>
#include <openssl/pem.h>
#include <openssl/x509.h>
#include <openssl/crypto.h>
#ifdef _WIN32
#define API __declspec(dllexport)
#else
#define API __attribute__((visibility("default")))
#endif
#if defined(__ANDROID__)
#include <sys/stat.h>
#include <pthread.h>
#include <jni.h>
// WinPR's Android string conversion (libwinpr/crt/unicode_android.c) asserts a
// JavaVM, which only WinPR's own JNI_OnLoad (libwinpr/utils/android.c, exported
// through android/exports.map) records. The app runs it with
// System.loadLibrary("atermius_rdp"); a dart:ffi dlopen alone never does. Until
// then the engine refuses to start instead of aborting the process.
extern JavaVM* jniVm;
static int jvm_ready(void) { return __atomic_load_n(&jniVm, __ATOMIC_ACQUIRE) != NULL; }
// FreeRDP refuses to create settings without HOME (upstream aFreeRDP sets it to
// the app files directory); Android app processes have none. Dart passes an
// app-private directory before the first connection. An existing HOME is kept.
static pthread_mutex_t home_lock = PTHREAD_MUTEX_INITIALIZER;
API int aterm_rdp_set_home(const char* dir) {
  if (!jvm_ready()) return 0;
  if (!dir || dir[0] != '/' || strlen(dir) >= PATH_MAX) return 0;
  struct stat st;
  if (stat(dir, &st) != 0 || !S_ISDIR(st.st_mode)) return 0;
  pthread_mutex_lock(&home_lock);
  const char* current = getenv("HOME");
  int ok = (current && *current) ? 1 : setenv("HOME", dir, 0) == 0;
  pthread_mutex_unlock(&home_lock);
  return ok;
}
#elif defined(__APPLE__)
#include <TargetConditionals.h>
#include <sys/stat.h>
#include <pthread.h>
// On iOS/macOS sandboxed containers, point XDG_CONFIG_HOME (and missing HOME)
// to an app-writable Application Support directory so FreeRDP never tries to
// mkdir inside an unwritable container root.
static pthread_mutex_t home_lock = PTHREAD_MUTEX_INITIALIZER;
API int aterm_rdp_set_home(const char* dir) {
  if (!dir || dir[0] != '/' || strlen(dir) >= PATH_MAX) return 0;
  struct stat st;
  if (stat(dir, &st) != 0 || !S_ISDIR(st.st_mode)) return 0;
  pthread_mutex_lock(&home_lock);
  const char* xdg = getenv("XDG_CONFIG_HOME");
  int ok = (xdg && *xdg) ? 1 : setenv("XDG_CONFIG_HOME", dir, 0) == 0;
  const char* current = getenv("HOME");
  if (!current || !*current) {
    ok = ok && (setenv("HOME", dir, 0) == 0);
  }
  pthread_mutex_unlock(&home_lock);
  return ok;
}
#endif

// Feature bits; must match lib/desktop/rdp_features.dart.
#define FEATURE_CONFIG_V1 (1u << 0)
#define FEATURE_DRIVE (1u << 1)
#define FEATURE_PRINTER (1u << 2)
#define FEATURE_SMARTCARD (1u << 3)
#define FEATURE_AUDIO_OUT (1u << 4)
#define FEATURE_AUDIO_IN (1u << 5)
#define FEATURE_MULTIMON (1u << 6)
#define FEATURE_FILE_CLIPBOARD (1u << 7)
#define FEATURE_CAMERA (1u << 8)
#define FEATURE_USB (1u << 9)
#define FEATURE_NATIVE_TOUCH (1u << 10)

#define MAX_DESKTOP_SIDE 8192u
#define MAX_DESKTOP_PIXELS (8192u * 4096u)
#define MAX_DRIVES 8
#define MAX_PRINTERS 1
#define MAX_MONITORS 16
#define MAX_USB 16
#define MAX_FILELIST_ITEMS 4096u
#define FILE_DESCRIPTOR_SIZE 592u
#define MAX_EVENT_BYTES (64u * 1024u * 1024u)
#define MAX_FILE_CHUNK (8u * 1024u * 1024u)
#define LOCAL_FILES_FORMAT_ID 0xC0A0u
#define FILE_GROUP_DESCRIPTOR_W "FileGroupDescriptorW"

// Events delivered to Dart through aterm_rdp_next_event.
#define EVENT_FILE_REQUEST 1  // server reads one of our offered files
#define EVENT_FILE_DATA 2     // server answered our FileContentsRequest

#if defined(ATERMIUS_RDP_CAMERA)
extern UINT VCAPITYPE aterm_camera_mf_entry(void* entryPoints);
#endif

static INIT_ONCE provider_once = INIT_ONCE_STATIC_INIT;
static PVIRTUALCHANNELENTRY aterm_addin_provider(LPCSTR name, LPCSTR subsystem, LPCSTR type,
                                                 DWORD flags) {
#if defined(ATERMIUS_RDP_CAMERA)
  // The Media Foundation camera HAL lives in this DLL rather than in the
  // FreeRDP static table; every other addin resolves exactly as before.
  if (name && subsystem && strcmp(name, "rdpecam") == 0 && strcmp(subsystem, "mf") == 0)
    return (PVIRTUALCHANNELENTRY)(void*)aterm_camera_mf_entry;
#endif
  return freerdp_channels_load_static_addin_entry(name, subsystem, type, flags);
}
static BOOL CALLBACK initialize_provider(PINIT_ONCE once, PVOID parameter, PVOID* context) {
  (void)once; (void)parameter; (void)context;
  return freerdp_register_addin_provider(aterm_addin_provider, 0) == CHANNEL_RC_OK;
}

typedef struct AtermEvent {
  struct AtermEvent* next;
  UINT32 type, stream, a, b, c;
  UINT32 length;
  BYTE data[];
} AtermEvent;

typedef struct {
  char name[32];
  char* path;
} DriveConfig;

typedef struct {
  INT32 x, y, width, height;
  BOOL primary;
} MonitorConfig;

typedef struct {
  UINT32 width, height, scale;
  BOOL dynamic_resolution, clipboard, clipboard_files, microphone, smartcards, cameras;
  UINT32 audio;     // 0 local, 1 remote, 2 off
  UINT32 printers;  // 0 off, 1 named default, 2 all
  char* printer_name;
  DriveConfig drives[MAX_DRIVES];
  UINT32 drive_count;
  MonitorConfig monitors[MAX_MONITORS];
  UINT32 monitor_count;
  char usb[MAX_USB][10];
  UINT32 usb_count;
} AtermConfig;

typedef struct {
  rdpContext context;
  UINT32 revision, clipboard_revision, files_revision;
  UINT32 buttons;
  BOOL connected, pin_set, disp_ready, certificate_rejected;
  BOOL clipboard_enabled, files_enabled, server_files;
  BYTE pin[32], rejected_certificate[32];
#if defined(ATERMIUS_RDP_NATIVE_TOUCH)
  RdpeiClientContext* touch;
  BOOL touch_ready;
  struct { BOOL active; INT32 x, y; } contacts[10];
#endif
  DispClientContext* disp;
  CliprdrClientContext* clip;
  CRITICAL_SECTION lock;
  BYTE* local_clipboard;
  UINT32 local_clipboard_len;
  BYTE* remote_clipboard;
  UINT32 remote_clipboard_len;
  BYTE* local_files;  // CLIPRDR_FILELIST we offer (cItems + descriptors)
  UINT32 local_files_len;
  BYTE* remote_files;  // CLIPRDR_FILELIST the server offers
  UINT32 remote_files_len;
  UINT32 remote_text_id, remote_files_id, pending_format, queued_files_request;
  AtermEvent *events_head, *events_tail;
  UINT32 event_bytes, event_count;
  INT32 dirty_x0, dirty_y0, dirty_x1, dirty_y1;
  UINT32 scale;
  BYTE* cursor_pixels;
  UINT32 cursor_revision, cursor_kind, cursor_width, cursor_height;
  UINT32 cursor_hot_x, cursor_hot_y, pointer_revision, pointer_x, pointer_y;
} AtermContext;

// FreeRDP owns the pointer cache. Keep its decoded shape separate from the
// framebuffer: the client renders it at the latest local mouse position.
typedef struct { rdpPointer pointer; BYTE* pixels; } AtermPointer;
static BOOL pointer_new(rdpContext* context, rdpPointer* pointer) {
  AtermPointer* p = (AtermPointer*)pointer;
  if (!pointer->width || !pointer->height || pointer->width > 512 ||
      pointer->height > 512 || pointer->xPos >= pointer->width ||
      pointer->yPos >= pointer->height) return FALSE;
  p->pixels = calloc((size_t)pointer->width * pointer->height, 4);
  if (!p->pixels) return FALSE;
  if (!freerdp_image_copy_from_pointer_data(p->pixels, PIXEL_FORMAT_BGRA32, 0, 0, 0,
      pointer->width, pointer->height, pointer->xorMaskData, pointer->lengthXorMask,
      pointer->andMaskData, pointer->lengthAndMask, pointer->xorBpp,
      context->gdi ? &context->gdi->palette : NULL)) {
    free(p->pixels); p->pixels = NULL; return FALSE;
  }
  return TRUE;
}
static void pointer_free(rdpContext* context, rdpPointer* pointer) {
  (void)context;
  free(((AtermPointer*)pointer)->pixels);
  ((AtermPointer*)pointer)->pixels = NULL;
}
static BOOL pointer_set(rdpContext* context, rdpPointer* pointer) {
  AtermContext* c = (AtermContext*)context;
  AtermPointer* p = (AtermPointer*)pointer;
  if (!p->pixels) return FALSE;
  size_t length = (size_t)pointer->width * pointer->height * 4;
  BYTE* copy = malloc(length);
  if (!copy) return FALSE;
  memcpy(copy, p->pixels, length);
  EnterCriticalSection(&c->lock);
  free(c->cursor_pixels); c->cursor_pixels = copy;
  c->cursor_width = pointer->width; c->cursor_height = pointer->height;
  c->cursor_hot_x = pointer->xPos; c->cursor_hot_y = pointer->yPos;
  c->cursor_kind = 2; c->cursor_revision++;
  LeaveCriticalSection(&c->lock);
  return TRUE;
}
static BOOL pointer_system(rdpContext* context, UINT32 kind) {
  AtermContext* c = (AtermContext*)context;
  EnterCriticalSection(&c->lock);
  free(c->cursor_pixels); c->cursor_pixels = NULL;
  c->cursor_kind = kind; c->cursor_revision++;
  LeaveCriticalSection(&c->lock);
  return TRUE;
}
static BOOL pointer_null(rdpContext* c) { return pointer_system(c, 1); }
static BOOL pointer_default(rdpContext* c) { return pointer_system(c, 0); }
static BOOL pointer_position(rdpContext* context, UINT32 x, UINT32 y) {
  AtermContext* c = (AtermContext*)context;
  EnterCriticalSection(&c->lock);
  c->pointer_x = x; c->pointer_y = y; c->pointer_revision++;
  LeaveCriticalSection(&c->lock);
  return TRUE;
}
static void register_pointer(rdpContext* c) {
  rdpPointer pointer = { 0 };
  pointer.size = sizeof(AtermPointer);
  pointer.New = pointer_new; pointer.Free = pointer_free;
  pointer.Set = pointer_set; pointer.SetNull = pointer_null;
  pointer.SetDefault = pointer_default; pointer.SetPosition = pointer_position;
  graphics_register_pointer(c->graphics, &pointer);
}

static void mark_dirty(AtermContext* c, INT32 x, INT32 y, INT32 w, INT32 h) {
  if (w <= 0 || h <= 0) return;
  if (c->dirty_x1 <= c->dirty_x0 || c->dirty_y1 <= c->dirty_y0) {
    c->dirty_x0 = x; c->dirty_y0 = y; c->dirty_x1 = x + w; c->dirty_y1 = y + h;
    return;
  }
  if (x < c->dirty_x0) c->dirty_x0 = x;
  if (y < c->dirty_y0) c->dirty_y0 = y;
  if (x + w > c->dirty_x1) c->dirty_x1 = x + w;
  if (y + h > c->dirty_y1) c->dirty_y1 = y + h;
}

static BOOL begin_paint(rdpContext* c) {
  c->gdi->primary->hdc->hwnd->invalid->null = TRUE;
  return TRUE;
}
static BOOL end_paint(rdpContext* c) {
  HGDI_RGN invalid = c->gdi->primary->hdc->hwnd->invalid;
  if (!invalid->null) {
    AtermContext* a = (AtermContext*)c;
    a->revision++;
    mark_dirty(a, invalid->x, invalid->y, invalid->w, invalid->h);
  }
  return TRUE;
}
static BOOL desktop_size_valid(UINT32 w, UINT32 h) {
  return w && h && w <= MAX_DESKTOP_SIDE && h <= MAX_DESKTOP_SIDE &&
         (UINT64)w * h <= MAX_DESKTOP_PIXELS;
}
static BOOL resize_desktop(rdpContext* c) {
  UINT32 w = freerdp_settings_get_uint32(c->settings, FreeRDP_DesktopWidth);
  UINT32 h = freerdp_settings_get_uint32(c->settings, FreeRDP_DesktopHeight);
  if (!desktop_size_valid(w, h)) return FALSE;
  AtermContext* a = (AtermContext*)c;
  a->revision++;
  if (!gdi_resize(c->gdi, w, h)) return FALSE;
  a->dirty_x0 = 0; a->dirty_y0 = 0; a->dirty_x1 = (INT32)w; a->dirty_y1 = (INT32)h;
  return TRUE;
}
static int verify_certificate(freerdp* instance, const BYTE* pem, size_t length,
                              const char* host, UINT16 port, DWORD flags) {
  AtermContext* c = (AtermContext*)instance->context;
  // Never approve here. Return the rejected leaf fingerprint to Flutter so the
  // user can explicitly approve and save it, then retry with that exact pin.
  // Redirect/gateway identities must not be saved as the original Host's pin.
  if (!host || port != freerdp_settings_get_uint32(c->context.settings, FreeRDP_ServerPort) ||
      strcmp(host, freerdp_settings_get_string(c->context.settings, FreeRDP_ServerHostname)) != 0 ||
      (flags & (VERIFY_CERT_FLAG_GATEWAY | VERIFY_CERT_FLAG_REDIRECT)) || length > INT_MAX) return 0;
  BIO* bio = BIO_new_mem_buf(pem, (int)length);
  if (!bio) return 0;
  X509* certificate = PEM_read_bio_X509(bio, NULL, NULL, NULL);
  BIO_free(bio);
  if (!certificate) return 0;
  BYTE digest[EVP_MAX_MD_SIZE]; unsigned int count = 0;
  int parsed = X509_digest(certificate, EVP_sha256(), digest, &count) && count == 32;
  int valid = parsed && c->pin_set && CRYPTO_memcmp(digest, c->pin, 32) == 0;
  if (parsed && !valid) {
    memcpy(c->rejected_certificate, digest, 32);
    c->certificate_rejected = TRUE;
  }
  X509_free(certificate);
  return valid ? 2 : 0;
}
static BOOL authenticate(freerdp* instance, char** user, char** password,
                         char** domain, rdp_auth_reason reason) {
  (void)instance; (void)user; (void)password; (void)domain; (void)reason;
  return FALSE; // never read stdin or display a blocking native password dialog
}
static UINT disp_caps(DispClientContext* disp, UINT32 count, UINT32 a, UINT32 b) {
  (void)count; (void)a; (void)b;
  ((AtermContext*)disp->custom)->disp_ready = TRUE;
  return CHANNEL_RC_OK;
}

// ---- events -------------------------------------------------------------
// Caller holds c->lock. Over-budget data is replaced by a failure marker so the
// Dart side fails the transfer instead of waiting forever.
static void push_event(AtermContext* c, UINT32 type, UINT32 stream, UINT32 a, UINT32 b,
                       UINT32 cval, const BYTE* data, UINT32 length) {
  if (c->event_count >= 4096) return;
  if (c->event_bytes + length > MAX_EVENT_BYTES) { data = NULL; length = 0; a = 0; }
  AtermEvent* e = (AtermEvent*)calloc(1, sizeof(AtermEvent) + length);
  if (!e) return;
  e->type = type; e->stream = stream; e->a = a; e->b = b; e->c = cval; e->length = length;
  if (length) memcpy(e->data, data, length);
  if (c->events_tail) c->events_tail->next = e; else c->events_head = e;
  c->events_tail = e;
  c->event_bytes += length; c->event_count++;
}
static void free_events(AtermContext* c) {
  AtermEvent* e = c->events_head;
  while (e) {
    AtermEvent* next = e->next;
    SecureZeroMemory(e->data, e->length);
    free(e);
    e = next;
  }
  c->events_head = c->events_tail = NULL;
  c->event_bytes = c->event_count = 0;
}

// ---- clipboard (MS-RDPECLIP) --------------------------------------------
static UINT send_local_format_list(AtermContext* c) {
  CLIPRDR_FORMAT formats[1] = {0};
  CLIPRDR_FORMAT_LIST list = {0};
  if (c->local_files) {
    formats[0].formatId = LOCAL_FILES_FORMAT_ID;
    formats[0].formatName = FILE_GROUP_DESCRIPTOR_W;
    list.numFormats = 1;
  } else if (c->local_clipboard) {
    formats[0].formatId = CF_UNICODETEXT;
    list.numFormats = 1;
  }
  list.formats = formats;
  return c->clip->ClientFormatList(c->clip, &list);
}
static UINT clip_ready(CliprdrClientContext* clip, const CLIPRDR_MONITOR_READY* ready) {
  (void)ready;
  AtermContext* c = (AtermContext*)clip->custom;
  CLIPRDR_GENERAL_CAPABILITY_SET general = {0};
  general.capabilitySetType = CB_CAPSTYPE_GENERAL;
  general.capabilitySetLength = 12;
  general.version = CB_CAPS_VERSION_2;
  general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
  // No clip-data locking: transfers address the current list only.
  if (c->files_enabled)
    general.generalFlags |= CB_STREAM_FILECLIP_ENABLED | CB_FILECLIP_NO_FILE_PATHS |
                            CB_HUGE_FILE_SUPPORT_ENABLED;
  CLIPRDR_CAPABILITIES caps = {0};
  caps.cCapabilitiesSets = 1;
  caps.capabilitySets = (CLIPRDR_CAPABILITY_SET*)&general;
  UINT rc = clip->ClientCapabilities(clip, &caps);
  if (rc != CHANNEL_RC_OK) return rc;
  EnterCriticalSection(&c->lock);
  rc = send_local_format_list(c);
  LeaveCriticalSection(&c->lock);
  return rc;
}
static UINT clip_server_caps(CliprdrClientContext* clip, const CLIPRDR_CAPABILITIES* caps) {
  AtermContext* c = (AtermContext*)clip->custom;
  BOOL files = FALSE;
  for (UINT32 i = 0; caps && i < caps->cCapabilitiesSets; i++) {
    const CLIPRDR_CAPABILITY_SET* set = &caps->capabilitySets[i];
    if (set->capabilitySetType == CB_CAPSTYPE_GENERAL) {
      const CLIPRDR_GENERAL_CAPABILITY_SET* g = (const CLIPRDR_GENERAL_CAPABILITY_SET*)set;
      files = (g->generalFlags & CB_STREAM_FILECLIP_ENABLED) != 0;
    }
  }
  EnterCriticalSection(&c->lock);
  c->server_files = files;
  LeaveCriticalSection(&c->lock);
  return CHANNEL_RC_OK;
}
static UINT request_format(AtermContext* c, UINT32 id) {
  CLIPRDR_FORMAT_DATA_REQUEST request = {0};
  request.requestedFormatId = id;
  c->pending_format = id;
  return c->clip->ClientFormatDataRequest(c->clip, &request);
}
static UINT clip_formats(CliprdrClientContext* clip, const CLIPRDR_FORMAT_LIST* list) {
  AtermContext* c = (AtermContext*)clip->custom;
  CLIPRDR_FORMAT_LIST_RESPONSE response = {0}; response.common.msgFlags = CB_RESPONSE_OK;
  UINT rc = clip->ClientFormatListResponse(clip, &response);
  if (rc != CHANNEL_RC_OK) return rc;
  EnterCriticalSection(&c->lock);
  c->remote_text_id = 0; c->remote_files_id = 0; c->queued_files_request = 0;
  for (UINT32 i = 0; i < list->numFormats; i++) {
    const CLIPRDR_FORMAT* f = &list->formats[i];
    if (f->formatId == CF_UNICODETEXT) c->remote_text_id = CF_UNICODETEXT;
    else if (c->files_enabled && f->formatName &&
             strcmp(f->formatName, FILE_GROUP_DESCRIPTOR_W) == 0)
      c->remote_files_id = f->formatId;
  }
  // A new remote list replaces the previous remote files immediately.
  if (c->remote_files) { free(c->remote_files); c->remote_files = NULL; }
  c->remote_files_len = 0;
  c->files_revision++;
  if (c->remote_text_id) {
    c->queued_files_request = c->remote_files_id;
    rc = request_format(c, c->remote_text_id);
  } else if (c->remote_files_id) {
    rc = request_format(c, c->remote_files_id);
  } else {
    c->pending_format = 0;
  }
  LeaveCriticalSection(&c->lock);
  return rc;
}
static UINT clip_data(CliprdrClientContext* clip, const CLIPRDR_FORMAT_DATA_RESPONSE* data) {
  AtermContext* c = (AtermContext*)clip->custom;
  UINT rc = CHANNEL_RC_OK;
  EnterCriticalSection(&c->lock);
  const UINT32 format = c->pending_format;
  c->pending_format = 0;
  const BOOL ok = (data->common.msgFlags & CB_RESPONSE_OK) &&
                  (!data->common.dataLen || data->requestedFormatData);
  if (ok && format == CF_UNICODETEXT && data->common.dataLen <= 131074 &&
      !(data->common.dataLen & 1)) {
    free(c->remote_clipboard); c->remote_clipboard = NULL; c->remote_clipboard_len = 0;
    if (data->common.dataLen) {
      c->remote_clipboard = (BYTE*)malloc(data->common.dataLen);
      if (c->remote_clipboard) {
        memcpy(c->remote_clipboard, data->requestedFormatData, data->common.dataLen);
        c->remote_clipboard_len = data->common.dataLen;
      }
    }
    c->clipboard_revision++;
  } else if (ok && format && format == c->remote_files_id && data->common.dataLen >= 4) {
    UINT32 items = 0;
    memcpy(&items, data->requestedFormatData, 4);  // little-endian on all targets
    if (items <= MAX_FILELIST_ITEMS &&
        data->common.dataLen == 4 + items * FILE_DESCRIPTOR_SIZE) {
      free(c->remote_files);
      c->remote_files = (BYTE*)malloc(data->common.dataLen);
      if (c->remote_files) {
        memcpy(c->remote_files, data->requestedFormatData, data->common.dataLen);
        c->remote_files_len = data->common.dataLen;
      }
      c->files_revision++;
    }
  }
  if (c->queued_files_request) {
    const UINT32 next = c->queued_files_request;
    c->queued_files_request = 0;
    rc = request_format(c, next);
  }
  LeaveCriticalSection(&c->lock);
  return rc;
}
static UINT clip_request(CliprdrClientContext* clip, const CLIPRDR_FORMAT_DATA_REQUEST* request) {
  AtermContext* c = (AtermContext*)clip->custom;
  CLIPRDR_FORMAT_DATA_RESPONSE response = {0};
  EnterCriticalSection(&c->lock);
  response.common.msgFlags = CB_RESPONSE_FAIL;
  if (request->requestedFormatId == CF_UNICODETEXT && c->local_clipboard) {
    response.common.msgFlags = CB_RESPONSE_OK;
    response.common.dataLen = c->local_clipboard_len;
    response.requestedFormatData = c->local_clipboard;
  } else if (request->requestedFormatId == LOCAL_FILES_FORMAT_ID && c->local_files) {
    response.common.msgFlags = CB_RESPONSE_OK;
    response.common.dataLen = c->local_files_len;
    response.requestedFormatData = c->local_files;
  }
  UINT rc = clip->ClientFormatDataResponse(clip, &response);
  LeaveCriticalSection(&c->lock);
  return rc;
}
static UINT clip_file_request(CliprdrClientContext* clip,
                              const CLIPRDR_FILE_CONTENTS_REQUEST* request) {
  AtermContext* c = (AtermContext*)clip->custom;
  EnterCriticalSection(&c->lock);
  UINT32 items = 0;
  if (c->local_files) memcpy(&items, c->local_files, 4);
  const BOOL valid = c->local_files && request->listIndex < items &&
                     (request->dwFlags == FILECONTENTS_SIZE ||
                      request->dwFlags == FILECONTENTS_RANGE);
  if (valid) {
    // Dart reads the file and answers through aterm_rdp_file_response.
    BYTE position[8];
    memcpy(position, &request->nPositionLow, 4);
    memcpy(position + 4, &request->nPositionHigh, 4);
    push_event(c, EVENT_FILE_REQUEST, request->streamId, request->listIndex, request->dwFlags,
               request->cbRequested, position, 8);
  }
  LeaveCriticalSection(&c->lock);
  if (valid) return CHANNEL_RC_OK;
  CLIPRDR_FILE_CONTENTS_RESPONSE response = {0};
  response.common.msgFlags = CB_RESPONSE_FAIL;
  response.streamId = request->streamId;
  return clip->ClientFileContentsResponse(clip, &response);
}
static UINT clip_file_response(CliprdrClientContext* clip,
                               const CLIPRDR_FILE_CONTENTS_RESPONSE* response) {
  AtermContext* c = (AtermContext*)clip->custom;
  EnterCriticalSection(&c->lock);
  const BOOL ok = (response->common.msgFlags & CB_RESPONSE_OK) &&
                  response->cbRequested <= MAX_FILE_CHUNK &&
                  (!response->cbRequested || response->requestedData);
  push_event(c, EVENT_FILE_DATA, response->streamId, ok ? 1 : 0, 0, 0,
             ok ? response->requestedData : NULL, ok ? response->cbRequested : 0);
  LeaveCriticalSection(&c->lock);
  return CHANNEL_RC_OK;
}
#if defined(ATERMIUS_RDP_NATIVE_TOUCH)
static UINT touch_ready(RdpeiClientContext* context) {
  AtermContext* c = context->custom;
  EnterCriticalSection(&c->lock);
  if (c->touch == context) c->touch_ready = TRUE;
  LeaveCriticalSection(&c->lock);
  return CHANNEL_RC_OK;
}
static UINT touch_suspended(RdpeiClientContext* context) {
  AtermContext* c = context->custom;
  EnterCriticalSection(&c->lock);
  c->touch_ready = FALSE;
  memset(c->contacts, 0, sizeof(c->contacts));
  LeaveCriticalSection(&c->lock);
  return CHANNEL_RC_OK;
}
#endif
static void channel_connected(void* ctx, const ChannelConnectedEventArgs* event) {
  AtermContext* c = (AtermContext*)ctx;
#if defined(ATERMIUS_RDP_NATIVE_TOUCH)
  if (strcmp(event->name, RDPEI_DVC_CHANNEL_NAME) == 0) {
    EnterCriticalSection(&c->lock);
    c->touch = (RdpeiClientContext*)event->pInterface;
    c->touch_ready = FALSE;
    memset(c->contacts, 0, sizeof(c->contacts));
    c->touch->custom = c;
    c->touch->Ready = touch_ready;
    c->touch->SuspendTouch = touch_suspended;
    c->touch->ResumeTouch = touch_ready;
    LeaveCriticalSection(&c->lock);
  }
#endif
  if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0) {
    c->disp = (DispClientContext*)event->pInterface;
    c->disp->custom = c; c->disp->DisplayControlCaps = disp_caps;
  } else if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
    c->clip = (CliprdrClientContext*)event->pInterface;
    c->clip->custom = c;
    c->clip->MonitorReady = clip_ready;
    c->clip->ServerCapabilities = clip_server_caps;
    c->clip->ServerFormatList = clip_formats;
    c->clip->ServerFormatDataResponse = clip_data;
    c->clip->ServerFormatDataRequest = clip_request;
    c->clip->ServerFileContentsRequest = clip_file_request;
    c->clip->ServerFileContentsResponse = clip_file_response;
  }
}
static void channel_disconnected(void* ctx, const ChannelDisconnectedEventArgs* event) {
  AtermContext* c = (AtermContext*)ctx;
#if defined(ATERMIUS_RDP_NATIVE_TOUCH)
  if (strcmp(event->name, RDPEI_DVC_CHANNEL_NAME) == 0) {
    EnterCriticalSection(&c->lock);
    c->touch = NULL;
    c->touch_ready = FALSE;
    memset(c->contacts, 0, sizeof(c->contacts));
    LeaveCriticalSection(&c->lock);
  }
#endif
  if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0) { c->disp = NULL; c->disp_ready = FALSE; }
  if (strcmp(event->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) c->clip = NULL;
}
static BOOL pre_connect(freerdp* instance) {
  rdpContext* c = instance->context;
  PubSub_SubscribeChannelConnected(c->pubSub, channel_connected);
  PubSub_SubscribeChannelDisconnected(c->pubSub, channel_disconnected);
  return TRUE;
}
static BOOL load_channels(freerdp* instance) {
  rdpContext* c = instance->context;
  return freerdp_client_load_addins(c->channels, c->settings);
}
static BOOL post_connect(freerdp* instance) {
  rdpContext* c = instance->context;
  UINT32 width = freerdp_settings_get_uint32(c->settings, FreeRDP_DesktopWidth);
  UINT32 height = freerdp_settings_get_uint32(c->settings, FreeRDP_DesktopHeight);
  if (!desktop_size_valid(width, height)) return FALSE;
  if (!gdi_init(instance, PIXEL_FORMAT_BGRA32) || !resize_desktop(c)) return FALSE;
  register_pointer(c);
  c->update->BeginPaint = begin_paint;
  c->update->EndPaint = end_paint;
  c->update->DesktopResize = resize_desktop;
  ((AtermContext*)c)->connected = TRUE;
  return TRUE;
}
static void post_disconnect(freerdp* instance) {
  AtermContext* c = (AtermContext*)instance->context;
  c->connected = FALSE;
  PubSub_UnsubscribeChannelConnected(c->context.pubSub, channel_connected);
  PubSub_UnsubscribeChannelDisconnected(c->context.pubSub, channel_disconnected);
  gdi_free(instance);
}

// ---- configuration --------------------------------------------------------
static void config_free(AtermConfig* cfg) {
  for (UINT32 i = 0; i < cfg->drive_count; i++) free(cfg->drives[i].path);
  free(cfg->printer_name);
  memset(cfg, 0, sizeof(*cfg));
}
static BOOL parse_u32(const char* v, UINT32 min, UINT32 max, UINT32* out) {
  if (!*v) return FALSE;
  UINT64 n = 0;
  for (const char* p = v; *p; p++) {
    if (*p < '0' || *p > '9') return FALSE;
    n = n * 10 + (UINT64)(*p - '0');
    if (n > max) return FALSE;
  }
  if (n < min) return FALSE;
  *out = (UINT32)n;
  return TRUE;
}
static BOOL parse_i32(const char* v, INT32 min, INT32 max, INT32* out) {
  BOOL negative = *v == '-';
  UINT32 n = 0;
  if (!parse_u32(negative ? v + 1 : v, 0, 0x7fffffff, &n)) return FALSE;
  INT64 value = negative ? -(INT64)n : (INT64)n;
  if (value < min || value > max) return FALSE;
  *out = (INT32)value;
  return TRUE;
}
static BOOL parse_bool(const char* v, BOOL* out) {
  if (strcmp(v, "0") == 0) { *out = FALSE; return TRUE; }
  if (strcmp(v, "1") == 0) { *out = TRUE; return TRUE; }
  return FALSE;
}
static BOOL safe_text(const char* v, size_t max) {
  size_t n = strlen(v);
  if (!n || n > max) return FALSE;
  for (const unsigned char* p = (const unsigned char*)v; *p; p++)
    if (*p < 32 || *p == 127 || *p == '|') return FALSE;
  return TRUE;
}
// Strict line parser; unknown keys or malformed values reject the session so
// a UI/engine mismatch cannot silently drop a user's choice.
static BOOL parse_config(const char* text, AtermConfig* cfg) {
  memset(cfg, 0, sizeof(*cfg));
  cfg->width = 1280; cfg->height = 800; cfg->scale = 100;
  cfg->dynamic_resolution = TRUE; cfg->clipboard = TRUE;
  if (!text || strlen(text) > 65536) return FALSE;
  BOOL versioned = FALSE;
  const char* p = text;
  char line[2048];
  while (*p) {
    const char* end = strchr(p, '\n');
    size_t n = end ? (size_t)(end - p) : strlen(p);
    if (n >= sizeof(line)) return FALSE;
    memcpy(line, p, n); line[n] = '\0';
    p += n + (end ? 1 : 0);
    if (!n) continue;
    char* eq = strchr(line, '=');
    if (!eq) return FALSE;
    *eq = '\0';
    const char* k = line; const char* v = eq + 1;
    UINT32 u = 0;
    if (strcmp(k, "version") == 0) { if (strcmp(v, "1") != 0) return FALSE; versioned = TRUE; }
    else if (strcmp(k, "width") == 0) { if (!parse_u32(v, 200, MAX_DESKTOP_SIDE, &cfg->width)) return FALSE; }
    else if (strcmp(k, "height") == 0) { if (!parse_u32(v, 200, MAX_DESKTOP_SIDE, &cfg->height)) return FALSE; }
    else if (strcmp(k, "scale") == 0) { if (!parse_u32(v, 100, 500, &cfg->scale)) return FALSE; }
    else if (strcmp(k, "dynamic_resolution") == 0) { if (!parse_bool(v, &cfg->dynamic_resolution)) return FALSE; }
    else if (strcmp(k, "clipboard") == 0) { if (!parse_bool(v, &cfg->clipboard)) return FALSE; }
    else if (strcmp(k, "clipboard_files") == 0) { if (!parse_bool(v, &cfg->clipboard_files)) return FALSE; }
    else if (strcmp(k, "audio") == 0) { if (!parse_u32(v, 0, 2, &cfg->audio)) return FALSE; }
    else if (strcmp(k, "microphone") == 0) { if (!parse_bool(v, &cfg->microphone)) return FALSE; }
    else if (strcmp(k, "printers") == 0) { if (!parse_u32(v, 0, 2, &cfg->printers)) return FALSE; }
    else if (strcmp(k, "printer_name") == 0) {
      if (!safe_text(v, 256) || cfg->printer_name) return FALSE;
      cfg->printer_name = _strdup(v);
      if (!cfg->printer_name) return FALSE;
    }
    else if (strcmp(k, "smartcards") == 0) { if (!parse_bool(v, &cfg->smartcards)) return FALSE; }
    else if (strcmp(k, "cameras") == 0) { if (!parse_bool(v, &cfg->cameras)) return FALSE; }
    else if (strcmp(k, "drive") == 0) {
      char* bar = strchr((char*)v, '|');
      if (!bar || cfg->drive_count >= MAX_DRIVES) return FALSE;
      *bar = '\0';
      const char* name = v; const char* path = bar + 1;
      if (!safe_text(name, 31) || !safe_text(path, 1024)) return FALSE;
      for (const char* q = name; *q; q++)
        if (!isalnum((unsigned char)*q) && *q != ' ' && *q != '_' && *q != '-') return FALSE;
      DriveConfig* d = &cfg->drives[cfg->drive_count];
      strcpy(d->name, name);
      d->path = _strdup(path);
      if (!d->path) return FALSE;
      cfg->drive_count++;
    }
    else if (strcmp(k, "monitor") == 0) {
      if (cfg->monitor_count >= MAX_MONITORS) return FALSE;
      MonitorConfig* m = &cfg->monitors[cfg->monitor_count];
      char* fields[5]; int count = 0; char* cursor = (char*)v;
      while (count < 5) {
        fields[count++] = cursor;
        char* bar = strchr(cursor, '|');
        if (!bar) break;
        *bar = '\0'; cursor = bar + 1;
      }
      UINT32 w = 0, h = 0, primary = 0;
      if (count != 5 || !parse_i32(fields[0], -32766, 32766, &m->x) ||
          !parse_i32(fields[1], -32766, 32766, &m->y) || !parse_u32(fields[2], 200, 8192, &w) ||
          !parse_u32(fields[3], 200, 8192, &h) || !parse_u32(fields[4], 0, 1, &primary))
        return FALSE;
      m->width = (INT32)w; m->height = (INT32)h; m->primary = primary == 1;
      cfg->monitor_count++;
    }
    else if (strcmp(k, "usb") == 0) {
      if (cfg->usb_count >= MAX_USB || strlen(v) != 9 || v[4] != ':') return FALSE;
      for (int i = 0; i < 9; i++)
        if (i != 4 && !isxdigit((unsigned char)v[i])) return FALSE;
      strcpy(cfg->usb[cfg->usb_count++], v);
    }
    else return FALSE;
    (void)u;
  }
  if (!versioned) return FALSE;
  if (cfg->monitor_count) {
    UINT32 primaries = 0;
    for (UINT32 i = 0; i < cfg->monitor_count; i++) primaries += cfg->monitors[i].primary ? 1 : 0;
    if (primaries != 1) return FALSE;
  }
  if (cfg->printers == 1 && !cfg->printer_name) return FALSE;
  return TRUE;
}

static BOOL add_device(rdpSettings* s, UINT32 type, size_t count, const char* const args[]) {
  RDPDR_DEVICE* device = freerdp_device_new(type, count, args);
  if (!device) return FALSE;
  if (!freerdp_device_collection_add(s, device)) { freerdp_device_free(device); return FALSE; }
  return TRUE;
}

static BOOL apply_monitors(rdpSettings* s, const AtermConfig* cfg) {
  INT32 left = 0, top = 0, right = 0, bottom = 0;
  if (!freerdp_settings_set_pointer_len(s, FreeRDP_MonitorDefArray, NULL, cfg->monitor_count))
    return FALSE;
  for (UINT32 i = 0; i < cfg->monitor_count; i++) {
    const MonitorConfig* m = &cfg->monitors[i];
    rdpMonitor* out =
        (rdpMonitor*)freerdp_settings_get_pointer_array_writable(s, FreeRDP_MonitorDefArray, i);
    if (!out) return FALSE;
    memset(out, 0, sizeof(*out));
    out->x = m->x; out->y = m->y; out->width = m->width; out->height = m->height;
    out->is_primary = m->primary ? 1 : 0;
    out->orig_screen = i;
    out->attributes.desktopScaleFactor = cfg->scale;
    out->attributes.deviceScaleFactor = cfg->scale >= 180 ? 180 : cfg->scale >= 140 ? 140 : 100;
    if (i == 0 || m->x < left) left = m->x;
    if (i == 0 || m->y < top) top = m->y;
    if (i == 0 || m->x + m->width > right) right = m->x + m->width;
    if (i == 0 || m->y + m->height > bottom) bottom = m->y + m->height;
  }
  const UINT32 w = (UINT32)(right - left), h = (UINT32)(bottom - top);
  if (!desktop_size_valid(w, h)) return FALSE;
  return freerdp_settings_set_uint32(s, FreeRDP_MonitorCount, cfg->monitor_count) &&
         freerdp_settings_set_bool(s, FreeRDP_UseMultimon, TRUE) &&
         freerdp_settings_set_bool(s, FreeRDP_ForceMultimon, TRUE) &&
         freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, w) &&
         freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, h);
}

API UINT32 aterm_rdp_features(void) {
  UINT32 bits = FEATURE_CONFIG_V1 | FEATURE_FILE_CLIPBOARD;
#if defined(ATERMIUS_RDP_DEVICES)
  bits |= FEATURE_DRIVE;
#endif
#if defined(ATERMIUS_RDP_PRINTER)
  bits |= FEATURE_PRINTER;
#endif
#if defined(ATERMIUS_RDP_SMARTCARD)
  bits |= FEATURE_SMARTCARD;
#endif
#if defined(ATERMIUS_RDP_AUDIO)
  bits |= FEATURE_AUDIO_OUT | FEATURE_AUDIO_IN;
#endif
  bits |= FEATURE_MULTIMON;
#if defined(ATERMIUS_RDP_CAMERA)
  bits |= FEATURE_CAMERA;
#endif
#if defined(ATERMIUS_RDP_USB)
  bits |= FEATURE_USB;
#endif
#if defined(ATERMIUS_RDP_NATIVE_TOUCH)
  bits |= FEATURE_NATIVE_TOUCH;
#endif
  return bits;
}

API void* aterm_rdp_create_ex(const char* host, int port, const char* user,
                              const char* password, const char* pin, const char* config) {
  if (!host || !*host || port < 1 || port > 65535 || !user || !password || !pin) return NULL;
#if defined(__ANDROID__)
  if (!jvm_ready()) return NULL;
#endif
  AtermConfig cfg;
  if (!parse_config(config, &cfg)) { config_free(&cfg); return NULL; }
  const UINT32 features = aterm_rdp_features();
  if ((cfg.drive_count && !(features & FEATURE_DRIVE)) ||
      (cfg.printers && !(features & FEATURE_PRINTER)) ||
      (cfg.smartcards && !(features & FEATURE_SMARTCARD)) ||
      (cfg.audio == 0 && !(features & FEATURE_AUDIO_OUT)) ||
      (cfg.microphone && !(features & FEATURE_AUDIO_IN)) ||
      (cfg.cameras && !(features & FEATURE_CAMERA)) ||
      (cfg.usb_count && !(features & FEATURE_USB))) {
    // Refuse instead of silently dropping a requested redirection.
    config_free(&cfg);
    return NULL;
  }
  if (!InitOnceExecuteOnce(&provider_once, initialize_provider, NULL, NULL)) { config_free(&cfg); return NULL; }
  freerdp* instance = freerdp_new();
  if (!instance) { config_free(&cfg); return NULL; }
  instance->ContextSize = sizeof(AtermContext);
  instance->LoadChannels = load_channels;
  instance->PreConnect = pre_connect; instance->PostConnect = post_connect;
  instance->PostDisconnect = post_disconnect;
  instance->VerifyX509Certificate = verify_certificate;
  instance->AuthenticateEx = authenticate;
  if (!freerdp_context_new(instance)) { freerdp_free(instance); config_free(&cfg); return NULL; }
  AtermContext* c = (AtermContext*)instance->context;
  InitializeCriticalSection(&c->lock);
  c->clipboard_enabled = cfg.clipboard;
  c->files_enabled = cfg.clipboard && cfg.clipboard_files;
  c->scale = cfg.scale;
  rdpSettings* s = c->context.settings;
  if (*pin) {
    if (strlen(pin) != 64) goto fail;
    for (int i = 0; i < 32; i++) {
      unsigned int value;
      if (!isxdigit((unsigned char)pin[i * 2]) || !isxdigit((unsigned char)pin[i * 2 + 1])) goto fail;
      if (sscanf(pin + i * 2, "%2x", &value) != 1) goto fail;
      c->pin[i] = (BYTE)value;
    }
    c->pin_set = TRUE;
  }
  #define STR(k,v) if (!freerdp_settings_set_string(s, FreeRDP_##k, v)) goto fail
  #define NUM(k,v) if (!freerdp_settings_set_uint32(s, FreeRDP_##k, v)) goto fail
  #define BOOLVAL(k,v) if (!freerdp_settings_set_bool(s, FreeRDP_##k, v)) goto fail
  STR(ServerHostname, host); NUM(ServerPort, (UINT32)port);
#if defined(__ANDROID__) || defined(__APPLE__)
  // Connect straight to the Host through OS routing/VPN. FreeRDP would
  // otherwise adopt http(s)_proxy from the process environment.
  NUM(ProxyType, PROXY_TYPE_IGNORE);
#endif
  const char* separator = strchr(user, '\\');
  if (separator) {
    size_t domain_size = (size_t)(separator - user);
    char* domain = (char*)calloc(1, domain_size + 1);
    if (!domain) goto fail;
    memcpy(domain, user, domain_size);
    BOOL domain_ok = freerdp_settings_set_string(s, FreeRDP_Domain, domain);
    free(domain);
    if (!domain_ok) goto fail;
    STR(Username, separator + 1);
  } else { STR(Username, user); }
  STR(Password, password);
  NUM(DesktopWidth, cfg.width & ~1u); NUM(DesktopHeight, cfg.height);
  NUM(ColorDepth, 32); NUM(KeyboardLayout, 0x0409);
  NUM(DesktopScaleFactor, cfg.scale);
  NUM(DeviceScaleFactor, cfg.scale >= 180 ? 180 : cfg.scale >= 140 ? 140 : 100);
  NUM(TcpConnectTimeout, 10000); NUM(TcpAckTimeout, 10000);
  BOOLVAL(ExternalCertificateManagement, c->pin_set);
  BOOLVAL(CertificateCallbackPreferPEM, TRUE); BOOLVAL(IgnoreCertificate, FALSE);
  BOOLVAL(AutoAcceptCertificate, FALSE); BOOLVAL(AutoDenyCertificate, FALSE);
  BOOLVAL(RdpSecurity, FALSE); // TLS/NLA only; no unencrypted legacy RDP
  BOOLVAL(TlsSecurity, TRUE); BOOLVAL(NlaSecurity, TRUE);
  BOOLVAL(NSCodec, TRUE); BOOLVAL(SurfaceCommandsEnabled, TRUE);
  BOOLVAL(SupportGraphicsPipeline, FALSE); BOOLVAL(SoftwareGdi, TRUE);
  // Enables server Position Updates in FreeRDP's pointer cache. No OS grab:
  // our SetPosition callback only updates this session's client-side cursor.
  BOOLVAL(GrabMouse, TRUE);
  // Display control stays negotiated for single-monitor sessions even with a
  // fixed size, so an explicit in-session resolution change can be applied
  // live. Automatic window-following resizes are a Dart-side policy
  // (dynamic_resolution=1). Multi-monitor geometry is fixed at connect time.
  BOOLVAL(SupportDisplayControl, cfg.monitor_count == 0);
  BOOLVAL(DynamicResolutionUpdate, cfg.monitor_count == 0);
  BOOLVAL(NetworkAutoDetect, FALSE);
  BOOLVAL(SupportHeartbeatPdu, FALSE); BOOLVAL(SupportMultitransport, FALSE);
  // No message channel is negotiated; never advertise UDP multitransport.
  NUM(MultitransportFlags, 0);
  BOOLVAL(RedirectClipboard, cfg.clipboard);
  BOOLVAL(AutoReconnectionEnabled, FALSE);
  // Redirection: each resource is explicit. No "all drives" and no hotplug of
  // arbitrary drives; only folders the user listed for this Host.
  BOOLVAL(RedirectDrives, FALSE); BOOLVAL(RedirectHomeDrive, FALSE);
  BOOLVAL(RedirectPrinters, FALSE); BOOLVAL(RedirectSmartCards, FALSE);
  BOOLVAL(RedirectSerialPorts, FALSE); BOOLVAL(RedirectParallelPorts, FALSE);
  BOOL devices = FALSE;
  for (UINT32 i = 0; i < cfg.drive_count; i++) {
    const char* args[] = { cfg.drives[i].name, cfg.drives[i].path };
    if (!add_device(s, RDPDR_DTYP_FILESYSTEM, 2, args)) goto fail;
    devices = TRUE;
  }
  if (cfg.printers == 1) {
    const char* args[] = { cfg.printer_name, "", "default" };
    if (!add_device(s, RDPDR_DTYP_PRINT, 3, args)) goto fail;
    devices = TRUE;
  } else if (cfg.printers == 2) {
    const char* args[] = { "" };  // empty name: enumerate every local printer
    if (!add_device(s, RDPDR_DTYP_PRINT, 1, args)) goto fail;
    devices = TRUE;
  }
  if (cfg.smartcards) {
    const char* args[] = { "" };
    if (!add_device(s, RDPDR_DTYP_SMARTCARD, 1, args)) goto fail;
    devices = TRUE;
  }
#if defined(ATERMIUS_RDP_NATIVE_TOUCH)
  { const char* params[] = { "rdpei" };
    if (!freerdp_client_add_dynamic_channel(s, 1, params)) goto fail;
  }
#endif
  BOOLVAL(DeviceRedirection, devices);
  BOOLVAL(AudioPlayback, cfg.audio == 0);
  BOOLVAL(RemoteConsoleAudio, cfg.audio == 1);
  BOOLVAL(AudioCapture, cfg.microphone);
#if defined(_WIN32) && defined(ATERMIUS_RDP_AUDIO)
  if (cfg.audio == 0) {
    const char* params[] = { "rdpsnd", "sys:winmm" };
    if (!freerdp_client_add_static_channel(s, 2, params)) goto fail;
    if (!freerdp_client_add_dynamic_channel(s, 2, params)) goto fail;
  }
  if (cfg.microphone) {
    const char* params[] = { "audin", "sys:winmm" };
    if (!freerdp_client_add_dynamic_channel(s, 2, params)) goto fail;
  }
#endif
#if defined(ATERMIUS_RDP_CAMERA)
  if (cfg.cameras) {
    const char* params[] = { "rdpecam", "sys:mf" };
    if (!freerdp_client_add_dynamic_channel(s, 2, params)) goto fail;
  }
#endif
#if defined(ATERMIUS_RDP_USB)
  if (cfg.usb_count) {
    char list[MAX_USB * 10 + 8] = "dev:";
    for (UINT32 i = 0; i < cfg.usb_count; i++) {
      if (i) strcat(list, "#");
      strcat(list, cfg.usb[i]);
    }
    const char* params[] = { "urbdrc", "id", list };
    if (!freerdp_client_add_dynamic_channel(s, 3, params)) goto fail;
  }
#endif
  if (cfg.monitor_count && !apply_monitors(s, &cfg)) goto fail;
  #undef STR
  #undef NUM
  #undef BOOLVAL
  config_free(&cfg);
  return c;
fail:
  config_free(&cfg);
  DeleteCriticalSection(&c->lock);
  freerdp_context_free(instance); freerdp_free(instance); return NULL;
}
// Compatibility entry point for callers built against the first engine.
API void* aterm_rdp_create(const char* host, int port, const char* user,
                           const char* password, const char* pin) {
  return aterm_rdp_create_ex(host, port, user, password, pin,
                             "version=1\naudio=2\nclipboard=1\n");
}
API int aterm_rdp_connect(void* handle) {
  AtermContext* c = (AtermContext*)handle;
  return freerdp_connect(c->context.instance) ? 1 : 0;
}
API UINT32 aterm_rdp_error(void* handle) {
  return freerdp_get_last_error(&((AtermContext*)handle)->context);
}
API int aterm_rdp_rejected_certificate(void* handle, char* output, UINT32 capacity) {
  AtermContext* c = (AtermContext*)handle;
  if (!c->certificate_rejected || !output || capacity < 65) return 0;
  for (int i = 0; i < 32; i++) snprintf(output + i * 2, 3, "%02x", c->rejected_certificate[i]);
  output[64] = '\0';
  return 64;
}
API int aterm_rdp_poll(void* handle) {
  AtermContext* c = (AtermContext*)handle;
  if (!c->connected || freerdp_shall_disconnect_context(&c->context)) return 0;
  HANDLE events[MAXIMUM_WAIT_OBJECTS];
  DWORD count = freerdp_get_event_handles(&c->context, events, MAXIMUM_WAIT_OBJECTS);
  if (!count) return 0;
  DWORD status = WaitForMultipleObjects(count, events, FALSE, 0);
  if (status == WAIT_FAILED) return 0;
  if (status == WAIT_TIMEOUT) return 1;
  return freerdp_check_event_handles(&c->context) ? 1 : 0;
}
API const BYTE* aterm_rdp_frame(void* handle, UINT32* info) {
  AtermContext* c = (AtermContext*)handle; rdpGdi* g = c->context.gdi;
  if (!c->connected || !g) return NULL;
  info[0] = (UINT32)g->width; info[1] = (UINT32)g->height;
  info[2] = (UINT32)g->stride; info[3] = c->revision;
  return g->primary_buffer;
}
// info: width, height, stride, revision, dirty x, y, w, h (clipped). Reading
// consumes the accumulated dirty rectangle.
API const BYTE* aterm_rdp_frame_ex(void* handle, UINT32* info) {
  AtermContext* c = (AtermContext*)handle; rdpGdi* g = c->context.gdi;
  if (!c->connected || !g) return NULL;
  info[0] = (UINT32)g->width; info[1] = (UINT32)g->height;
  info[2] = (UINT32)g->stride; info[3] = c->revision;
  INT32 x0 = c->dirty_x0 < 0 ? 0 : c->dirty_x0, y0 = c->dirty_y0 < 0 ? 0 : c->dirty_y0;
  INT32 x1 = c->dirty_x1 > g->width ? g->width : c->dirty_x1;
  INT32 y1 = c->dirty_y1 > g->height ? g->height : c->dirty_y1;
  if (x1 <= x0 || y1 <= y0) { x0 = y0 = x1 = y1 = 0; }
  info[4] = (UINT32)x0; info[5] = (UINT32)y0; info[6] = (UINT32)(x1 - x0); info[7] = (UINT32)(y1 - y0);
  c->dirty_x0 = c->dirty_y0 = c->dirty_x1 = c->dirty_y1 = 0;
  return g->primary_buffer;
}
API int aterm_rdp_key(void* handle, UINT32 code, int down, int unicode) {
  rdpInput* input = ((AtermContext*)handle)->context.input;
  if (unicode) return freerdp_input_send_unicode_keyboard_event(input, down ? 0 : KBD_FLAGS_RELEASE, (UINT16)code);
  return freerdp_input_send_keyboard_event_ex(input, down, FALSE, code);
}
API int aterm_rdp_mouse(void* handle, int x, int y, UINT32 buttons) {
  AtermContext* c = (AtermContext*)handle; rdpInput* input = c->context.input;
  if (x < 0) x = 0;
  if (y < 0) y = 0;
  if (x > 0xffff) x = 0xffff;
  if (y > 0xffff) y = 0xffff;
  BOOL ok = freerdp_input_send_mouse_event(input, PTR_FLAGS_MOVE, (UINT16)x, (UINT16)y);
  const UINT16 flags[] = {PTR_FLAGS_BUTTON1, PTR_FLAGS_BUTTON3, PTR_FLAGS_BUTTON2};
  for (int i = 0; i < 3; i++) {
    UINT32 mask = 1u << i;
    if ((buttons ^ c->buttons) & mask)
      ok = freerdp_input_send_mouse_event(input, flags[i] | ((buttons & mask) ? PTR_FLAGS_DOWN : 0), (UINT16)x, (UINT16)y) && ok;
  }
  if (buttons & 8) ok = freerdp_input_send_mouse_event(input, PTR_FLAGS_WHEEL | 120, 0, 0) && ok;
  if (buttons & 16) ok = freerdp_input_send_mouse_event(input, PTR_FLAGS_WHEEL | PTR_FLAGS_WHEEL_NEGATIVE | 0x88, 0, 0) && ok;
  c->buttons = buttons & 7;
  return ok;
}
// Optional exports: older installed DLLs continue to use mouse fallback.
API int aterm_rdp_can_touch(void* handle) {
#if defined(ATERMIUS_RDP_NATIVE_TOUCH)
  AtermContext* c = handle;
  if (!c) return 0;
  EnterCriticalSection(&c->lock);
  int ready = c->connected && c->touch && c->touch_ready;
  LeaveCriticalSection(&c->lock);
  return ready;
#else
  (void)handle; return 0;
#endif
}
// phase: 0 down, 1 move, 2 up, 3 cancel. IDs are bounded per-session slots.
API int aterm_rdp_touch(void* handle, int id, int phase, int x, int y) {
#if defined(ATERMIUS_RDP_NATIVE_TOUCH)
  AtermContext* c = handle;
  if (!c || id < 1 || id > 10 || phase < 0 || phase > 3) return 0;
  EnterCriticalSection(&c->lock);
  int ok = 0, i = id - 1; INT32 contact = -1;
  if (!c->connected || !c->touch || !c->touch_ready || !c->context.gdi) goto done;
  if (x < 0) x = 0;
  if (y < 0) y = 0;
  if (x >= c->context.gdi->width) x = c->context.gdi->width - 1;
  if (y >= c->context.gdi->height) y = c->context.gdi->height - 1;
  if (phase == 0) {
    if (c->contacts[i].active) goto done;
    ok = c->touch->TouchBegin(c->touch, id, x, y, &contact) == CHANNEL_RC_OK;
    if (ok) { c->contacts[i].active = TRUE; c->contacts[i].x = x; c->contacts[i].y = y; }
  } else if (c->contacts[i].active) {
    // MS-RDPEI UP retains the last engaged coordinates. A final move first
    // records any new pointer-up coordinate before ending that contact.
    if (phase == 1 || (phase == 2 && (x != c->contacts[i].x || y != c->contacts[i].y))) {
      if (c->touch->TouchUpdate(c->touch, id, x, y, &contact) != CHANNEL_RC_OK) goto done;
      c->contacts[i].x = x; c->contacts[i].y = y;
    }
    ok = 1;
    if (phase >= 2) {
      pcRdpeiTouchEvent finish = phase == 3 ? c->touch->TouchCancel : c->touch->TouchEnd;
      ok = finish(c->touch, id, c->contacts[i].x, c->contacts[i].y, &contact) == CHANNEL_RC_OK;
      if (ok) c->contacts[i].active = FALSE;
    }
  }
done:
  LeaveCriticalSection(&c->lock);
  return ok;
#else
  (void)handle; (void)id; (void)phase; (void)x; (void)y; return 0;
#endif
}
API int aterm_rdp_resize(void* handle, UINT32 width, UINT32 height) {
  AtermContext* c = (AtermContext*)handle;
  if (!c->disp || !c->disp_ready || width < 200 || height < 200 ||
      !desktop_size_valid(width, height)) return 0;
  DISPLAY_CONTROL_MONITOR_LAYOUT monitor = {0};
  monitor.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
  monitor.Width = width & ~1u; monitor.Height = height;
  monitor.PhysicalWidth = 340; monitor.PhysicalHeight = 270;
  monitor.DesktopScaleFactor = c->scale ? c->scale : 100;
  monitor.DeviceScaleFactor = c->scale >= 180 ? 180 : c->scale >= 140 ? 140 : 100;
  return c->disp->SendMonitorLayout(c->disp, 1, &monitor) == CHANNEL_RC_OK;
}
// 1 when the server negotiated display control (live resolution changes).
API int aterm_rdp_can_resize(void* handle) {
  AtermContext* c = (AtermContext*)handle;
  return c->disp && c->disp_ready ? 1 : 0;
}
// All callers run on the owning poll thread; pointers remain valid until the
// next poll. info: shape revision/kind/size/hotspot, position revision/x/y.
API const BYTE* aterm_rdp_pointer(void* handle, UINT32* info) {
  if (!handle || !info) return NULL;
  AtermContext* c = (AtermContext*)handle;
  info[0] = c->cursor_revision; info[1] = c->cursor_kind;
  info[2] = c->cursor_width; info[3] = c->cursor_height;
  info[4] = c->cursor_hot_x; info[5] = c->cursor_hot_y;
  info[6] = c->pointer_revision; info[7] = c->pointer_x; info[8] = c->pointer_y;
  return c->cursor_pixels;
}
API int aterm_rdp_paste(void* handle, const BYTE* utf16, UINT32 length) {
  AtermContext* c = (AtermContext*)handle;
  if (!c->clip || !c->clipboard_enabled || length > 131072 || (length & 1)) return 0;
  BYTE* copy = (BYTE*)calloc(1, length + 2);
  if (!copy) return 0;
  memcpy(copy, utf16, length);
  EnterCriticalSection(&c->lock);
  if (c->local_clipboard) { SecureZeroMemory(c->local_clipboard, c->local_clipboard_len); free(c->local_clipboard); }
  c->local_clipboard = copy; c->local_clipboard_len = length + 2;
  free(c->local_files); c->local_files = NULL; c->local_files_len = 0;
  UINT rc = send_local_format_list(c);
  LeaveCriticalSection(&c->lock);
  return rc == CHANNEL_RC_OK;
}
API UINT32 aterm_rdp_clipboard(void* handle, BYTE* out, UINT32 capacity, UINT32* revision) {
  AtermContext* c = (AtermContext*)handle;
  EnterCriticalSection(&c->lock);
  UINT32 length = c->remote_clipboard_len;
  *revision = c->clipboard_revision;
  if (out && capacity >= length && length) memcpy(out, c->remote_clipboard, length);
  LeaveCriticalSection(&c->lock);
  return length;
}
// Offer local files: a CLIPRDR_FILELIST (cItems + 592-byte FILEDESCRIPTORW).
// Dart builds the descriptors and serves contents on EVENT_FILE_REQUEST.
API int aterm_rdp_offer_files(void* handle, const BYTE* list, UINT32 length) {
  AtermContext* c = (AtermContext*)handle;
  if (!c->clip || !c->files_enabled || !list || length < 4) return 0;
  UINT32 items = 0; memcpy(&items, list, 4);
  if (!items || items > MAX_FILELIST_ITEMS || length != 4 + items * FILE_DESCRIPTOR_SIZE) return 0;
  BYTE* copy = (BYTE*)malloc(length);
  if (!copy) return 0;
  memcpy(copy, list, length);
  EnterCriticalSection(&c->lock);
  if (!c->server_files) { LeaveCriticalSection(&c->lock); free(copy); return 0; }
  free(c->local_files);
  c->local_files = copy; c->local_files_len = length;
  if (c->local_clipboard) { SecureZeroMemory(c->local_clipboard, c->local_clipboard_len); free(c->local_clipboard); }
  c->local_clipboard = NULL; c->local_clipboard_len = 0;
  UINT rc = send_local_format_list(c);
  LeaveCriticalSection(&c->lock);
  return rc == CHANNEL_RC_OK;
}
API int aterm_rdp_file_response(void* handle, UINT32 stream, int ok, const BYTE* data, UINT32 length) {
  AtermContext* c = (AtermContext*)handle;
  if (!c->clip || length > MAX_FILE_CHUNK || (length && !data)) return 0;
  CLIPRDR_FILE_CONTENTS_RESPONSE response = {0};
  response.common.msgFlags = ok ? CB_RESPONSE_OK : CB_RESPONSE_FAIL;
  response.streamId = stream;
  response.cbRequested = ok ? length : 0;
  response.requestedData = ok ? data : NULL;
  return c->clip->ClientFileContentsResponse(c->clip, &response) == CHANNEL_RC_OK;
}
API UINT32 aterm_rdp_remote_files(void* handle, BYTE* out, UINT32 capacity, UINT32* revision) {
  AtermContext* c = (AtermContext*)handle;
  EnterCriticalSection(&c->lock);
  UINT32 length = c->remote_files_len;
  *revision = c->files_revision;
  if (out && capacity >= length && length) memcpy(out, c->remote_files, length);
  LeaveCriticalSection(&c->lock);
  return length;
}
API int aterm_rdp_request_file(void* handle, UINT32 stream, UINT32 index, UINT32 flags,
                               UINT64 position, UINT32 size) {
  AtermContext* c = (AtermContext*)handle;
  if (!c->clip || (flags != FILECONTENTS_SIZE && flags != FILECONTENTS_RANGE) ||
      size > MAX_FILE_CHUNK || (flags == FILECONTENTS_SIZE && (size != 8 || position)))
    return 0;
  EnterCriticalSection(&c->lock);
  UINT32 items = 0;
  if (c->remote_files) memcpy(&items, c->remote_files, 4);
  LeaveCriticalSection(&c->lock);
  if (index >= items) return 0;
  CLIPRDR_FILE_CONTENTS_REQUEST request = {0};
  request.streamId = stream; request.listIndex = index; request.dwFlags = flags;
  request.nPositionLow = (UINT32)(position & 0xffffffffu);
  request.nPositionHigh = (UINT32)(position >> 32);
  request.cbRequested = size;
  return c->clip->ClientFileContentsRequest(c->clip, &request) == CHANNEL_RC_OK;
}
// header: type, stream, a, b, c, length. Returns -1 when empty, else length.
// When capacity is too small, the event stays queued and the length returns.
API int aterm_rdp_next_event(void* handle, UINT32* header, BYTE* out, UINT32 capacity) {
  AtermContext* c = (AtermContext*)handle;
  EnterCriticalSection(&c->lock);
  AtermEvent* e = c->events_head;
  if (!e) { LeaveCriticalSection(&c->lock); return -1; }
  header[0] = e->type; header[1] = e->stream; header[2] = e->a; header[3] = e->b;
  header[4] = e->c; header[5] = e->length;
  if (e->length > capacity) { LeaveCriticalSection(&c->lock); return (int)e->length; }
  if (e->length) memcpy(out, e->data, e->length);
  c->events_head = e->next;
  if (!c->events_head) c->events_tail = NULL;
  c->event_bytes -= e->length; c->event_count--;
  LeaveCriticalSection(&c->lock);
  int length = (int)e->length;
  SecureZeroMemory(e->data, e->length);
  free(e);
  return length;
}
API void aterm_rdp_free(void* handle) {
  if (!handle) return;
  AtermContext* c = (AtermContext*)handle;
  freerdp* instance = c->context.instance;
  freerdp_disconnect(instance);
  if (c->local_clipboard) { SecureZeroMemory(c->local_clipboard, c->local_clipboard_len); free(c->local_clipboard); }
  if (c->remote_clipboard) { SecureZeroMemory(c->remote_clipboard, c->remote_clipboard_len); free(c->remote_clipboard); }
  free(c->local_files); free(c->remote_files);
  free(c->cursor_pixels);
  free_events(c);
  SecureZeroMemory(c->pin, sizeof(c->pin));
  DeleteCriticalSection(&c->lock);
  freerdp_context_free(instance); freerdp_free(instance);
}
