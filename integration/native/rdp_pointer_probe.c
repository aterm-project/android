// Headless pointer ABI probe. Compile with the engine's FreeRDP/OpenSSL flags;
// no server, credentials, window, socket, or framebuffer is required.
#include "../../apps/client/native/desktop/atermius_rdp.c"
#define CHECK(test) do { if (!(test)) { fprintf(stderr, "pointer probe failed at %d\n", __LINE__); return 1; } } while (0)
int main(void) {
  AtermContext* c = aterm_rdp_create("127.0.0.1", 9, "probe", "", "");
  CHECK(c != NULL);
  CHECK(freerdp_settings_get_bool(c->context.settings, FreeRDP_GrabMouse));
  register_pointer(&c->context);
  rdpPointer* p = Pointer_Alloc(&c->context);
  CHECK(p != NULL && p->New && p->Set && p->Free);
  BYTE pixels[16] = {0,0,255,255, 0,0,255,255, 0,0,255,255, 0,0,255,255};
  BYTE mask[4] = {0};
  p->width = p->height = 2; p->xPos = 1; p->yPos = 0; p->xorBpp = 32;
  p->xorMaskData = pixels; p->lengthXorMask = sizeof(pixels);
  p->andMaskData = mask; p->lengthAndMask = sizeof(mask);
  CHECK(p->New(&c->context, p));
  CHECK(p->Set(&c->context, p));
  UINT32 info[9] = {0};
  const BYTE* image = aterm_rdp_pointer(c, info);
  CHECK(image && info[1] == 2 && info[2] == 2 && info[3] == 2 && info[4] == 1);
  CHECK(image[2] == 255 && image[3] == 255);
  const UINT32 revision = info[0];
  CHECK(p->SetNull(&c->context));
  CHECK(aterm_rdp_pointer(c, info) == NULL && info[1] == 1 && info[0] != revision);
  CHECK(p->Set(&c->context, p)); // Same decoded cached shape is reused.
  p->Free(&c->context, p);
  image = aterm_rdp_pointer(c, info);
  CHECK(image && info[1] == 2 && image[2] == 255); // Active shape owns its copy.
  CHECK(p->SetPosition(&c->context, 31, 47));
  aterm_rdp_pointer(c, info);
  CHECK(info[6] == 1 && info[7] == 31 && info[8] == 47);
  CHECK(p->SetDefault(&c->context));
  CHECK(aterm_rdp_pointer(c, info) == NULL && info[1] == 0);
  p->width = 513;
  CHECK(!p->New(&c->context, p));
  p->width = 2; p->xPos = 2;
  CHECK(!p->New(&c->context, p));
  free(p);
  aterm_rdp_free(c);
  puts("pointer shape, alpha, hotspot, cached reuse, lifetime, hidden/default, position and bounds passed");
  return 0;
}
