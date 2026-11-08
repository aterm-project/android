// Atermius rdpecam HAL for Windows: Media Foundation source reader.
// Uses only the system camera stack (no driver, no virtual camera). Samples
// are passed through in the camera's native compressed/raw format (MJPG, YUY2,
// NV12, I420, H.264); FreeRDP's passthrough patch forwards them unchanged.
// RGB formats are not offered: Media Foundation delivers them bottom-up.
#define COBJMACROS
// winsock2.h must precede windows.h: otherwise windows.h pulls legacy
// winsock.h, which conflicts with WinPR/FreeRDP's winsock2 use (C2011/C2375).
#include <winsock2.h>
#include <windows.h>
#include <objbase.h>

#include <winpr/wlog.h>
#include <winpr/synch.h>

#include "camera.h"

#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mferror.h>

#define TAG CHANNELS_TAG("rdpecam-mf.client")
#define MAX_STREAMS 8
#define MAX_NATIVE_TYPES 512
#define FIRST_VIDEO ((DWORD)MF_SOURCE_READER_FIRST_VIDEO_STREAM)

typedef struct {
  char* deviceId;
  char* link;  // full symbolic link, owned; resolved when the stream starts
  CameraDevice* dev;
  size_t streamIndex;
  ICamHalSampleCapturedCallback callback;
  CAM_MEDIA_TYPE_DESCRIPTION mediaType;
  HANDLE thread;
  volatile LONG streaming;
} MfStream;

#define MAX_CAMERAS 16

typedef struct {
  ICamHal iHal;
  CRITICAL_SECTION lock;
  MfStream streams[MAX_STREAMS];
  // FreeRDP keeps device ids in char[32]; Windows symbolic links are longer.
  // Devices are exposed as stable short ids "mfN" mapped to their link here.
  char* links[MAX_CAMERAS];
  BOOL started;
} MfHal;

// Copy of the symbolic link for a short id, or NULL. Caller frees.
static char* link_for(MfHal* hal, const char* shortId) {
  unsigned index = 0;
  char tail = 0;
  if (!shortId || sscanf(shortId, "mf%u%c", &index, &tail) != 1 || index >= MAX_CAMERAS)
    return NULL;
  EnterCriticalSection(&hal->lock);
  char* link = hal->links[index] ? _strdup(hal->links[index]) : NULL;
  LeaveCriticalSection(&hal->lock);
  return link;
}

// Short id for a link, assigning a free slot on first sight.
static BOOL short_id_for(MfHal* hal, const char* link, char out[8]) {
  int slot = -1;
  EnterCriticalSection(&hal->lock);
  for (int i = 0; i < MAX_CAMERAS; i++) {
    if (hal->links[i] && strcmp(hal->links[i], link) == 0) { slot = i; break; }
  }
  for (int i = 0; slot < 0 && i < MAX_CAMERAS; i++) {
    if (!hal->links[i]) {
      hal->links[i] = _strdup(link);
      if (hal->links[i]) slot = i;
    }
  }
  LeaveCriticalSection(&hal->lock);
  if (slot < 0) return FALSE;
  (void)snprintf(out, 8, "mf%d", slot);
  return TRUE;
}

// Media Foundation video subtypes are FOURCC GUIDs on this base.
static const GUID kVideoBase = {0x00000000, 0x0000, 0x0010,
                                {0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}};
// MF attribute GUIDs come from mfuuid.lib (SDK symbols, not literals).

#define ATERM_FOURCC(a, b, c, d) \
  ((DWORD)(BYTE)(a) | ((DWORD)(BYTE)(b) << 8) | ((DWORD)(BYTE)(c) << 16) | ((DWORD)(BYTE)(d) << 24))

static DWORD fourcc_for(CAM_MEDIA_FORMAT format) {
  switch (format) {
    case CAM_MEDIA_FORMAT_MJPG: return ATERM_FOURCC('M', 'J', 'P', 'G');
    case CAM_MEDIA_FORMAT_YUY2: return ATERM_FOURCC('Y', 'U', 'Y', '2');
    case CAM_MEDIA_FORMAT_NV12: return ATERM_FOURCC('N', 'V', '1', '2');
    case CAM_MEDIA_FORMAT_I420: return ATERM_FOURCC('I', '4', '2', '0');
    case CAM_MEDIA_FORMAT_H264: return ATERM_FOURCC('H', '2', '6', '4');
    default: return 0;
  }
}

static BOOL subtype_fourcc(IMFMediaType* type, DWORD* fourcc) {
  GUID subtype;
  if (FAILED(IMFMediaType_GetGUID(type, &MF_MT_SUBTYPE, &subtype))) return FALSE;
  if (memcmp(&subtype.Data2, &kVideoBase.Data2, sizeof(GUID) - sizeof(DWORD)) != 0) return FALSE;
  *fourcc = subtype.Data1;
  return TRUE;
}

static BOOL type_size(IMFMediaType* type, UINT32* w, UINT32* h) {
  UINT64 v = 0;
  if (FAILED(IMFMediaType_GetUINT64(type, &MF_MT_FRAME_SIZE, &v))) return FALSE;
  *w = (UINT32)(v >> 32);
  *h = (UINT32)(v & 0xffffffffu);
  return *w > 0 && *h > 0 && *w <= 8192 && *h <= 8192;
}

static void type_rate(IMFMediaType* type, UINT32* num, UINT32* den) {
  UINT64 v = 0;
  *num = 30;
  *den = 1;
  if (SUCCEEDED(IMFMediaType_GetUINT64(type, &MF_MT_FRAME_RATE, &v)) && (v >> 32) && (v & 0xffffffffu)) {
    *num = (UINT32)(v >> 32);
    *den = (UINT32)(v & 0xffffffffu);
  }
}

// COM on the calling channel/capture thread. Returns whether to uninitialize.
static BOOL com_enter(void) {
  HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
  return hr == S_OK || hr == S_FALSE;
}

static WCHAR* utf8_to_wide(const char* s) {
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, NULL, 0);
  if (n <= 0 || n > 4096) return NULL;
  WCHAR* w = (WCHAR*)calloc((size_t)n, sizeof(WCHAR));
  if (w && MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, w, n) != n) {
    free(w);
    return NULL;
  }
  return w;
}

static char* wide_to_utf8(const WCHAR* w) {
  int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
  if (n <= 0 || n > 8192) return NULL;
  char* s = (char*)calloc((size_t)n, 1);
  if (s && WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, NULL, NULL) != n) {
    free(s);
    return NULL;
  }
  return s;
}

static IMFSourceReader* open_reader(const char* deviceLink, IMFMediaSource** sourceOut) {
  *sourceOut = NULL;
  if (!deviceLink) return NULL;
  IMFAttributes* attributes = NULL;
  IMFMediaSource* source = NULL;
  IMFSourceReader* reader = NULL;
  WCHAR* link = utf8_to_wide(deviceLink);
  if (!link) return NULL;
  if (SUCCEEDED(MFCreateAttributes(&attributes, 2)) &&
      SUCCEEDED(IMFAttributes_SetGUID(attributes, &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID)) &&
      SUCCEEDED(IMFAttributes_SetString(attributes, &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, link)) &&
      SUCCEEDED(MFCreateDeviceSource(attributes, &source)) &&
      SUCCEEDED(MFCreateSourceReaderFromMediaSource(source, NULL, &reader))) {
    *sourceOut = source;
    source = NULL;
  }
  if (source) {
    IMFMediaSource_Shutdown(source);
    IMFMediaSource_Release(source);
  }
  if (attributes) IMFAttributes_Release(attributes);
  free(link);
  return reader;
}

static void close_reader(IMFSourceReader* reader, IMFMediaSource* source) {
  if (reader) IMFSourceReader_Release(reader);
  if (source) {
    IMFMediaSource_Shutdown(source);
    IMFMediaSource_Release(source);
  }
}

static UINT mf_enumerate(ICamHal* ihal, ICamHalEnumCallback callback, CameraPlugin* ecam,
                         GENERIC_CHANNEL_CALLBACK* hchannel) {
  MfHal* hal = (MfHal*)ihal;
  const BOOL com = com_enter();
  IMFAttributes* attributes = NULL;
  IMFActivate** devices = NULL;
  UINT32 count = 0, reported = 0;
  if (SUCCEEDED(MFCreateAttributes(&attributes, 1)) &&
      SUCCEEDED(IMFAttributes_SetGUID(attributes, &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID)) &&
      SUCCEEDED(MFEnumDeviceSources(attributes, &devices, &count))) {
    for (UINT32 i = 0; i < count; i++) {
      WCHAR *link = NULL, *name = NULL;
      UINT32 length = 0;
      if (SUCCEEDED(IMFActivate_GetAllocatedString(devices[i], &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, &link, &length)) &&
          SUCCEEDED(IMFActivate_GetAllocatedString(devices[i], &MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &name, &length))) {
        char* id = wide_to_utf8(link);
        char* label = wide_to_utf8(name);
        char shortId[8];
        if (id && label && short_id_for(hal, id, shortId) &&
            callback(ecam, hchannel, shortId, label) == CHANNEL_RC_OK)
          reported++;
        free(id);
        free(label);
      }
      if (link) CoTaskMemFree(link);
      if (name) CoTaskMemFree(name);
      IMFActivate_Release(devices[i]);
    }
    CoTaskMemFree(devices);
  }
  if (attributes) IMFAttributes_Release(attributes);
  if (com) CoUninitialize();
  WLog_DBG(TAG, "Media Foundation reported %" PRIu32 " cameras", reported);
  return reported;
}

static BOOL mf_activate(ICamHal* ihal, const char* deviceId, CAM_ERROR_CODE* errorCode) {
  (void)ihal; (void)deviceId;
  if (errorCode) *errorCode = CAM_ERROR_CODE_None;
  return TRUE;
}

static BOOL mf_deactivate(ICamHal* ihal, const char* deviceId, CAM_ERROR_CODE* errorCode) {
  (void)ihal; (void)deviceId;
  if (errorCode) *errorCode = CAM_ERROR_CODE_None;
  return TRUE;
}

// Lists native camera types for the first supported format (same contract as
// the V4L HAL): returns the supportedFormats index used, or -1.
static INT16 mf_media_types(ICamHal* ihal, const char* deviceId, size_t streamIndex,
                            const CAM_MEDIA_FORMAT_INFO* supported, size_t nSupported,
                            CAM_MEDIA_TYPE_DESCRIPTION* out, size_t* nOut) {
  (void)streamIndex;
  MfHal* hal = (MfHal*)ihal;
  const size_t capacity = *nOut;
  size_t produced = 0, index = 0;
  *nOut = 0;
  const BOOL com = com_enter();
  IMFMediaSource* source = NULL;
  char* deviceLink = link_for(hal, deviceId);
  IMFSourceReader* reader = open_reader(deviceLink, &source);
  free(deviceLink);
  if (!reader) {
    if (com) CoUninitialize();
    WLog_ERR(TAG, "Unable to open camera");
    return -1;
  }
  for (; index < nSupported && produced == 0; index++) {
    const DWORD wanted = fourcc_for(supported[index].inputFormat);
    if (!wanted || supported[index].inputFormat != supported[index].outputFormat) continue;
    for (DWORD t = 0; t < MAX_NATIVE_TYPES && produced < capacity; t++) {
      IMFMediaType* type = NULL;
      if (FAILED(IMFSourceReader_GetNativeMediaType(reader, FIRST_VIDEO, t, &type))) break;
      DWORD fourcc = 0;
      UINT32 w = 0, h = 0, num = 0, den = 0;
      if (subtype_fourcc(type, &fourcc) && fourcc == wanted && type_size(type, &w, &h)) {
        type_rate(type, &num, &den);
        // One entry per size, keeping the highest frame rate.
        size_t k = 0;
        for (; k < produced; k++)
          if (out[k].Width == w && out[k].Height == h) break;
        if (k == produced) {
          out[k].Format = supported[index].inputFormat;
          out[k].Width = w;
          out[k].Height = h;
          out[k].FrameRateNumerator = num;
          out[k].FrameRateDenominator = den;
          out[k].PixelAspectRatioNumerator = 1;
          out[k].PixelAspectRatioDenominator = 1;
          produced++;
        } else if ((UINT64)num * out[k].FrameRateDenominator >
                   (UINT64)out[k].FrameRateNumerator * den) {
          out[k].FrameRateNumerator = num;
          out[k].FrameRateDenominator = den;
        }
      }
      IMFMediaType_Release(type);
    }
  }
  close_reader(reader, source);
  if (com) CoUninitialize();
  *nOut = produced;
  if (!produced || index == 0 || index - 1 > INT16_MAX) return -1;
  return (INT16)(index - 1);
}

static BOOL select_type(IMFSourceReader* reader, const CAM_MEDIA_TYPE_DESCRIPTION* want) {
  const DWORD fourcc = fourcc_for(want->Format);
  IMFMediaType* best = NULL;
  UINT64 bestRate = 0;
  for (DWORD t = 0; t < MAX_NATIVE_TYPES; t++) {
    IMFMediaType* type = NULL;
    if (FAILED(IMFSourceReader_GetNativeMediaType(reader, FIRST_VIDEO, t, &type))) break;
    DWORD f = 0;
    UINT32 w = 0, h = 0, num = 0, den = 1;
    if (subtype_fourcc(type, &f) && f == fourcc && type_size(type, &w, &h) &&
        w == want->Width && h == want->Height) {
      type_rate(type, &num, &den);
      const UINT64 rate = ((UINT64)num << 16) / (den ? den : 1);
      if (!best || rate > bestRate) {
        if (best) IMFMediaType_Release(best);
        best = type;
        bestRate = rate;
        continue;
      }
    }
    IMFMediaType_Release(type);
  }
  if (!best) return FALSE;
  const HRESULT hr = IMFSourceReader_SetCurrentMediaType(reader, FIRST_VIDEO, NULL, best);
  IMFMediaType_Release(best);
  return SUCCEEDED(hr);
}

static DWORD WINAPI capture_thread(LPVOID param) {
  MfStream* stream = (MfStream*)param;
  const BOOL com = com_enter();
  IMFMediaSource* source = NULL;
  IMFSourceReader* reader = open_reader(stream->link, &source);
  if (!reader || !select_type(reader, &stream->mediaType)) {
    WLog_ERR(TAG, "Camera does not provide the negotiated media type");
    InterlockedExchange(&stream->streaming, 0);
  } else {
    (void)IMFSourceReader_SetStreamSelection(reader, (DWORD)MF_SOURCE_READER_ALL_STREAMS, FALSE);
    (void)IMFSourceReader_SetStreamSelection(reader, FIRST_VIDEO, TRUE);
  }
  while (InterlockedCompareExchange(&stream->streaming, 1, 1) == 1) {
    DWORD actual = 0, flags = 0;
    LONGLONG timestamp = 0;
    IMFSample* sample = NULL;
    const HRESULT hr =
        IMFSourceReader_ReadSample(reader, FIRST_VIDEO, 0, &actual, &flags, &timestamp, &sample);
    if (FAILED(hr) || (flags & MF_SOURCE_READERF_ERROR) || (flags & MF_SOURCE_READERF_ENDOFSTREAM)) {
      WLog_ERR(TAG, "Camera capture ended (0x%08lx)", (unsigned long)hr);
      if (sample) IMFSample_Release(sample);
      break;
    }
    if (!sample) continue;  // stream tick or format change
    IMFMediaBuffer* buffer = NULL;
    if (SUCCEEDED(IMFSample_ConvertToContiguousBuffer(sample, &buffer))) {
      BYTE* data = NULL;
      DWORD length = 0;
      if (SUCCEEDED(IMFMediaBuffer_Lock(buffer, &data, NULL, &length))) {
        const UINT rc = length ? stream->callback(stream->dev, stream->streamIndex, data, length)
                               : CHANNEL_RC_OK;
        IMFMediaBuffer_Unlock(buffer);
        if (rc == ECAM_SAMPLE_CAPTURE_DRAINED) InterlockedExchange(&stream->streaming, 0);
      }
      IMFMediaBuffer_Release(buffer);
    }
    IMFSample_Release(sample);
  }
  InterlockedExchange(&stream->streaming, 0);
  close_reader(reader, source);
  if (com) CoUninitialize();
  return 0;
}

static MfStream* find_stream(MfHal* hal, const char* deviceId, BOOL create) {
  MfStream* free_slot = NULL;
  for (int i = 0; i < MAX_STREAMS; i++) {
    MfStream* s = &hal->streams[i];
    if (s->deviceId && strcmp(s->deviceId, deviceId) == 0) return s;
    if (!s->deviceId && !free_slot) free_slot = s;
  }
  if (!create || !free_slot) return NULL;
  free_slot->deviceId = _strdup(deviceId);
  return free_slot->deviceId ? free_slot : NULL;
}

static void join_stream(MfStream* stream) {
  InterlockedExchange(&stream->streaming, 0);
  if (stream->thread) {
    // Wait for the capture thread to finish; it owns stream->link until it exits.
    (void)WaitForSingleObject(stream->thread, INFINITE);
    (void)CloseHandle(stream->thread);
    stream->thread = NULL;
  }
}

static CAM_ERROR_CODE mf_start(ICamHal* ihal, CameraDevice* dev, size_t streamIndex,
                               const CAM_MEDIA_TYPE_DESCRIPTION* mediaType,
                               ICamHalSampleCapturedCallback callback) {
  MfHal* hal = (MfHal*)ihal;
  if (!fourcc_for(mediaType->Format)) return CAM_ERROR_CODE_InvalidMediaType;
  EnterCriticalSection(&hal->lock);
  MfStream* stream = find_stream(hal, dev->deviceId, TRUE);
  if (!stream) {
    LeaveCriticalSection(&hal->lock);
    return CAM_ERROR_CODE_OutOfMemory;
  }
  if (InterlockedCompareExchange(&stream->streaming, 1, 1) == 1) {
    LeaveCriticalSection(&hal->lock);
    return CAM_ERROR_CODE_UnexpectedError;
  }
  join_stream(stream);
  free(stream->link);
  stream->link = link_for(hal, dev->deviceId);
  if (!stream->link) {
    LeaveCriticalSection(&hal->lock);
    return CAM_ERROR_CODE_ItemNotFound;
  }
  stream->dev = dev;
  stream->streamIndex = streamIndex;
  stream->callback = callback;
  stream->mediaType = *mediaType;
  InterlockedExchange(&stream->streaming, 1);
  stream->thread = CreateThread(NULL, 0, capture_thread, stream, 0, NULL);
  if (!stream->thread) InterlockedExchange(&stream->streaming, 0);
  LeaveCriticalSection(&hal->lock);
  return stream->thread ? CAM_ERROR_CODE_None : CAM_ERROR_CODE_OutOfMemory;
}

static CAM_ERROR_CODE mf_stop(ICamHal* ihal, const char* deviceId, size_t streamIndex) {
  (void)streamIndex;
  MfHal* hal = (MfHal*)ihal;
  EnterCriticalSection(&hal->lock);
  MfStream* stream = find_stream(hal, deviceId, FALSE);
  if (stream) join_stream(stream);
  LeaveCriticalSection(&hal->lock);
  return stream ? CAM_ERROR_CODE_None : CAM_ERROR_CODE_NotInitialized;
}

static CAM_ERROR_CODE mf_free(ICamHal* ihal) {
  MfHal* hal = (MfHal*)ihal;
  if (!hal) return CAM_ERROR_CODE_NotInitialized;
  for (int i = 0; i < MAX_STREAMS; i++) {
    join_stream(&hal->streams[i]);
    free(hal->streams[i].deviceId);
    free(hal->streams[i].link);
  }
  for (int i = 0; i < MAX_CAMERAS; i++) free(hal->links[i]);
  DeleteCriticalSection(&hal->lock);
  if (hal->started) MFShutdown();
  free(hal);
  return CAM_ERROR_CODE_None;
}

UINT VCAPITYPE aterm_camera_mf_entry(void* entry) {
  PFREERDP_CAMERA_HAL_ENTRY_POINTS points = (PFREERDP_CAMERA_HAL_ENTRY_POINTS)entry;
  if (!points || !points->pRegisterCameraHal) return ERROR_INVALID_PARAMETER;
  MfHal* hal = (MfHal*)calloc(1, sizeof(MfHal));
  if (!hal) return CHANNEL_RC_NO_MEMORY;
  InitializeCriticalSection(&hal->lock);
  if (FAILED(MFStartup(MF_VERSION, MFSTARTUP_LITE))) {
    WLog_ERR(TAG, "Media Foundation is unavailable on this system");
    DeleteCriticalSection(&hal->lock);
    free(hal);
    return ERROR_NOT_SUPPORTED;
  }
  hal->started = TRUE;
  hal->iHal.RequestDrivenCapture = TRUE;
  hal->iHal.Enumerate = mf_enumerate;
  hal->iHal.Activate = mf_activate;
  hal->iHal.Deactivate = mf_deactivate;
  hal->iHal.GetMediaTypeDescriptions = mf_media_types;
  hal->iHal.StartStream = mf_start;
  hal->iHal.StopStream = mf_stop;
  hal->iHal.Free = mf_free;
  const UINT rc = points->pRegisterCameraHal(points->plugin, &hal->iHal);
  if (rc != CHANNEL_RC_OK) mf_free(&hal->iHal);
  return rc;
}
