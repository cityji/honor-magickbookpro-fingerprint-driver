#define _GNU_SOURCE
/* ASAN harness: drives the REAL fpcmoh init callbacks + REAL fpi-ssm.c.
 * No USB hardware needed. Proves:
 *   A) fpi_ssm_hello_receive_cb: stale event (cmdid 6) -> mark_failed frees
 *      the SSM -> fall-through next_state = heap-use-after-free (pre-fix).
 *   B) fpc_init_ssm_done: error override -> open_complete consumes the SSM's
 *      original error -> fpi_ssm_free frees it again = double-free (pre-fix).
 *   C) fpc_cmd_init_cb: short init event -> same fall-through UAF (pre-fix).
 * Post-fix: all three complete cleanly, exactly one completion per SSM.
 */
#include <stdlib.h>
#include <string.h>

/* unity-include the driver under test */
#include FPC_SRC

/* ---- instrumented stubs ------------------------------------------------- */

static int open_complete_calls;
static int suspend_complete_calls;
static int resume_complete_calls;
static int done_calls;
static GError *done_error;

/* mimics fpi_device_return_task_in_idle -> g_task_return_error: consumes */
void
fpi_device_open_complete (FpDevice *device, GError *error)
{
  open_complete_calls++;
  if (error)
    g_error_free (error);
}

void
fpi_device_suspend_complete (FpDevice *device, GError *error)
{
  suspend_complete_calls++;
  if (error)
    g_error_free (error);
}

void
fpi_device_resume_complete (FpDevice *device, GError *error)
{
  resume_complete_calls++;
  if (error)
    g_error_free (error);
}

GError *
fpi_device_error_new (FpDeviceError code)
{
  return g_error_new (FP_DEVICE_ERROR, code, "test error %d", code);
}

GError *
fpi_device_error_new_msg (FpDeviceError code, const gchar *fmt, ...)
{
  va_list args;
  va_start (args, fmt);
  GError *e = g_error_new_valist (FP_DEVICE_ERROR, code, fmt, args);
  va_end (args);
  return e;
}

GQuark
fp_device_error_quark (void)
{
  return g_quark_from_static_string ("FpDeviceError");
}

const char *
fp_device_get_driver (FpDevice *device)
{
  return "fpcmoh-test";
}

const char *
fp_device_get_device_id (FpDevice *device)
{
  return "test-device";
}

GSource *
fpi_device_add_timeout (FpDevice *device, gint interval, FpTimeoutFunc func,
                        gpointer user_data, GDestroyNotify notify)
{
  /* no delayed actions in the tested paths */
  return NULL;
}

/* FpDevice parent type stand-in (real one lives in fp-device.c) */
GType
fp_device_get_type (void)
{
  static GType t = 0;
  if (g_once_init_enter (&t))
    {
      GTypeInfo info = { 0 };
      info.class_size = sizeof (FpDeviceClass);
      info.instance_size = sizeof (FpDevice);
      GType tmp = g_type_register_static (G_TYPE_OBJECT, "FpDevice", &info,
                                          G_TYPE_FLAG_ABSTRACT);
      g_once_init_leave (&t, tmp);
    }
  return t;
}

/* ---- generic stubs (never executed on the tested paths) ----------------- */
/* Filled from linker errors; definitions only satisfy --no-undefined. */

static void
test_ssm_done (FpiSsm *ssm, FpDevice *dev, GError *error)
{
  done_calls++;
  done_error = error; /* owned copy from fpi_ssm_mark_completed */
}

static void
noop_handler (FpiSsm *ssm, FpDevice *dev)
{
}

static FpDevice *
make_device (void)
{
  return g_object_new (fpi_device_fpcmoh_get_type (), NULL);
}

/* ---- scenarios ---------------------------------------------------------- */

static void
scenario_hello (void)
{
  done_calls = 0; done_error = NULL;
  FpDevice *dev = make_device ();
  FpiSsm *ssm = fpi_ssm_new (dev, noop_handler, FPC_INIT_NUM_STATES);
  fpi_ssm_start (ssm, test_ssm_done);

  /* stale event from the interrupted session: cmdid 6, not 5 */
  evt_hdr_t evt = { 0 };
  evt.cmdid = GUINT32_TO_BE (6);
  FpiUsbTransfer transfer = { 0 };
  transfer.ssm = ssm;
  transfer.buffer = (guint8 *) &evt;
  transfer.actual_length = sizeof (evt);

  fpi_ssm_hello_receive_cb (&transfer, dev, NULL, NULL);

  g_assert_cmpint (done_calls, ==, 1);
  g_assert (done_error != NULL);
  g_error_free (done_error);
  g_object_unref (dev);
  g_print ("scenario hello: OK (one clean completion)\n");
}

static void
scenario_init_done (void)
{
  open_complete_calls = 0;
  FpDevice *dev = make_device ();
  FpiSsm *ssm = fpi_ssm_new (dev, noop_handler, FPC_INIT_NUM_STATES);
  fpi_ssm_start (ssm, fpc_init_ssm_done);

  fpi_ssm_mark_failed (ssm, fpi_device_error_new (FP_DEVICE_ERROR_GENERAL));

  g_assert_cmpint (open_complete_calls, ==, 1);
  g_object_unref (dev);
  g_print ("scenario init_done: OK (error owned exactly once)\n");
}

static void
scenario_cmd_init (void)
{
  done_calls = 0; done_error = NULL;
  FpDevice *dev = make_device ();
  FpiSsm *ssm = fpi_ssm_new (dev, noop_handler, FPC_INIT_NUM_STATES);
  fpi_ssm_start (ssm, test_ssm_done);

  guint8 short_buf[1] = { 0 };
  FpiUsbTransfer transfer = { 0 };
  transfer.ssm = ssm;
  transfer.buffer = short_buf;
  transfer.actual_length = 1; /* < sizeof(evt_initiated_t) -> handler -1 */

  fpc_cmd_init_cb (&transfer, dev, NULL, NULL);

  g_assert_cmpint (done_calls, ==, 1);
  g_assert (done_error != NULL);
  g_error_free (done_error);
  g_object_unref (dev);
  g_print ("scenario cmd_init: OK (one clean completion)\n");
}

int
main (int argc, char **argv)
{
  const char *which = argc > 1 ? argv[1] : "all";
  if (!strcmp (which, "hello") || !strcmp (which, "all"))
    scenario_hello ();
  if (!strcmp (which, "init_done") || !strcmp (which, "all"))
    scenario_init_done ();
  if (!strcmp (which, "cmd_init") || !strcmp (which, "all"))
    scenario_cmd_init ();
  return 0;
}
