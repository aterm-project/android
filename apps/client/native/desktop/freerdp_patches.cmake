# Small, auditable FreeRDP 3.33.0 source patches, applied once to the pinned
# tarball (see CMakeLists.txt PATCH_COMMAND). Each patch is idempotent and
# fails loudly if upstream text changed.
if(NOT FREERDP_SOURCE)
  message(FATAL_ERROR "FREERDP_SOURCE is required")
endif()

function(atermius_patch file old new)
  set(path "${FREERDP_SOURCE}/${file}")
  file(READ "${path}" code)
  string(FIND "${code}" "${new}" already)
  if(NOT already EQUAL -1)
    return()
  endif()
  string(FIND "${code}" "${old}" found)
  if(found EQUAL -1)
    message(FATAL_ERROR "FreeRDP ${file} changed; review the Atermius patch")
  endif()
  string(REPLACE "${old}" "${new}" code "${code}")
  file(WRITE "${path}" "${code}")
endfunction()

# 1. rdpecam on Windows: no V4L requirement. The capture HAL is provided by
#    atermius_rdp (camera_mf.c, Media Foundation) through the addin provider.
atermius_patch(channels/rdpecam/client/CMakeLists.txt
  "if(NOT ANDROID AND NOT APPLE)\n  find_package(V4L)"
  "if(NOT ANDROID AND NOT APPLE AND NOT WIN32)\n  find_package(V4L)")

# 2. rdpecam passthrough without FFmpeg. When the camera already produces the
#    negotiated format (MJPG/YUY2/NV12...), samples are copied unchanged, which
#    FreeRDP's own converter also does. Only the unused codec context setup
#    required FFmpeg; skip it for passthrough.
atermius_patch(channels/rdpecam/client/encoding.c
  "BOOL ecam_encoder_context_init(CameraDeviceStream* stream)\n{\n\tif (!ecam_init_video_context(stream))\n\t\treturn FALSE;"
  "BOOL ecam_encoder_context_init(CameraDeviceStream* stream)\n{\n\t/* atermius: raw/MJPG passthrough needs no codec context */\n\tif ((ecamToVideoFormat(streamInputFormat(stream)) != FREERDP_VIDEO_FORMAT_NONE) &&\n\t    (streamInputFormat(stream) == streamOutputFormat(stream)))\n\t\treturn TRUE;\n\n\tif (!ecam_init_video_context(stream))\n\t\treturn FALSE;")
atermius_patch(channels/rdpecam/client/encoding.c
  "\tif (!ecam_encoder_context_init(stream))\n\t\treturn FALSE;\n\n\treturn freerdp_video_sample_convert("
  "\tif (!ecam_encoder_context_init(stream))\n\t\treturn FALSE;\n\n\t/* atermius: passthrough without a codec context */\n\tif ((inputFormat != FREERDP_VIDEO_FORMAT_NONE) && (inputFormat == outputFormat))\n\t{\n\t\tif (!Stream_EnsureRemainingCapacity(output, srcSize))\n\t\t\treturn FALSE;\n\t\tStream_Write(output, srcData, srcSize);\n\t\treturn TRUE;\n\t}\n\n\treturn freerdp_video_sample_convert(")
