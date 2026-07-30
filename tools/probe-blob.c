#include <stdio.h>
#include <stdint.h>
#include <dlfcn.h>

int main(void)
{
  setvbuf (stdout, NULL, _IONBF, 0);
  void *h = dlopen("/opt/fpc-a900/lib/libfpcbep.so", RTLD_NOW);
  if (!h) { printf("dlopen: %s\n", dlerror()); return 1; }

  void *(*create)(void)                = dlsym(h, "fpc_create_enclave");
  int32_t (*start)(void *)             = dlsym(h, "fpc_start_enclave");
  int32_t (*einit)(void *, uint16_t)   = dlsym(h, "fpc_enclave_init");
  void *(*get_handle)(void)            = dlsym(h, "fpc_common_get_handle");
  int (*img_size)(void *)              = dlsym(h, "fpc_bep_image_get_size");
  int (*img_props)(void *, void *)     = dlsym(h, "fpc_image_get_properties");
  int (*img_dims)(void *, void *, void *) = dlsym(h, "fpc_bep_image_get_dimensions");
  int (*hw_details)(uint16_t, void *)  = dlsym(h, "fpc_hw_get_sensor_details_for_hardware_id");
  int (*getver)(void **) = dlsym(h, "fpc_bep_get_version");

  if (getver) { void *v = NULL; int r = getver (&v); printf("get_version -> %d, %s\n", r, v ? (char *) v : "(null)"); }

  if (hw_details)
    {
      uint8_t d[64] = { 0 };
      int r = hw_details (0x331, d);
      printf("hw_details(0x331) -> %d : type=%u w=%u h=%u\n", r,
             *(uint32_t *) d, *(uint16_t *) (d + 4), *(uint16_t *) (d + 6));
      printf("  raw:"); for (int i = 0; i < 40; i++) printf(" %02x", d[i]); printf("\n");
    }

  void *e = create ();
  printf("create_enclave -> %p\n", e);
  if (!e) return 1;
  printf("start_enclave  -> %d\n", start (e));
  printf("enclave_init(0x331) -> %d\n", einit (e, 0x331));

  void *hn = get_handle ();
  printf("common_get_handle -> %p\n", hn);
  if (!hn) return 1;
  void *img = *(void **) ((char *) hn + 0x10);
  printf("  handle[0x10] (image obj) -> %p\n", img);
  if (!img) return 0;

  uint32_t props[4] = { 0 };
  int r = img_props (img, props);
  printf("image_get_properties -> %d : [0]=%u [1]=%u [2]=%u [3]=%u\n",
         r, props[0], props[1], props[2], props[3]);
  printf("image_get_size -> %d\n", img_size (img));
  uint32_t w = 0, hh = 0;
  if (img_dims) printf("image_get_dimensions -> %d : w=%u h=%u\n", img_dims (img, &w, &hh), w, hh);
  printf("64*176 = %d   ; +34 header = %d\n", 64 * 176, 64 * 176 + 34);
  return 0;
}
