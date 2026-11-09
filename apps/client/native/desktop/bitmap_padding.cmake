# FreeRDP 3.33.0 rejects xrdp's four-pixel-aligned bitmap storage when the
# destination clipping is narrower (e.g. a one-pixel caret in a four-pixel row).
# Preserve all bounds checks: storage may exceed the destination by at most
# three pixels, only when aligned to four; never permit a smaller source.
# TS_BITMAP_DATA describes storage dimensions separately from destination bounds:
# https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpbcgr/84a3d4d2-5523-4e49-9a48-33952c559485
set(_update "${freerdp_SOURCE_DIR}/libfreerdp/core/update.c")
file(READ "${_update}" _code)
set(_old "if (w != bitmapData->width - 1)")
set(_new "if ((w + 1 > bitmapData->width) ||\n\t    (bitmapData->width - (w + 1) > 3) ||\n\t    ((w + 1 != bitmapData->width) && ((bitmapData->width % 4) != 0)))")
string(FIND "${_code}" "${_new}" _already)
if(_already EQUAL -1)
  string(FIND "${_code}" "${_old}" _found)
  if(_found EQUAL -1)
    message(FATAL_ERROR "FreeRDP bitmap check changed; review the compatibility patch")
  endif()
  string(REPLACE "${_old}" "${_new}" _code "${_code}")
  file(WRITE "${_update}" "${_code}")
endif()
