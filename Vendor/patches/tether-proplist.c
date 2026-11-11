
/* ---------------------------------------------------------------------------------------------------------------
 * Tether: folder listing through MTP GetObjectPropList.
 *
 * Appended to libmtp.c by Vendor/build-libs.sh (so it can use libmtp internals); the two LIBMTP_Tether_* functions
 * are added to libmtp.sym and declared for Swift in Vendor/CLibMTP/tether.h.
 *
 * Why: LIBMTP_Get_Files_And_Folders sends GetObjectInfo per object. Android answers that with the photo's EXIF
 * thumbnail size, which it reads from the file: ~33 ms per photo, 20 s for a 600-photo Camera folder. libmtp flags
 * every Android device DEVICE_FLAG_BROKEN_MTPGETOBJPROPLIST (old Android versions mishandled it), so it never asks
 * for the property list, which Android serves from the file system without opening files: ~1 s for the same folder.
 * Callers must validate what comes back and fall back to GetObjectInfo for anything missing.
 * ------------------------------------------------------------------------------------------------------------- */

/* Same conversion as ptp_unpack_PTPTIME (static in ptp-pack.c), so dates match the GetObjectInfo path exactly. */
static time_t tether_ptptime(const char *str)
{
  char tmp[5];
  struct tm tm;
  size_t len;

  if (str == NULL)
    return 0;
  len = strlen(str);
  if (len < 15 || len >= 40)
    return 0;
  memset(&tm, 0, sizeof(tm));
  memcpy(tmp, str, 4);      tmp[4] = 0; tm.tm_year = atoi(tmp) - 1900;
  memcpy(tmp, str + 4, 2);  tmp[2] = 0; tm.tm_mon = atoi(tmp) - 1;
  memcpy(tmp, str + 6, 2);  tmp[2] = 0; tm.tm_mday = atoi(tmp);
  memcpy(tmp, str + 9, 2);  tmp[2] = 0; tm.tm_hour = atoi(tmp);
  memcpy(tmp, str + 11, 2); tmp[2] = 0; tm.tm_min = atoi(tmp);
  memcpy(tmp, str + 13, 2); tmp[2] = 0; tm.tm_sec = atoi(tmp);
  tm.tm_isdst = -1;
  return mktime(&tm);
}

#define TETHER_HAS_NAME   1u
#define TETHER_HAS_FORMAT 2u
#define TETHER_HAS_SIZE   4u
#define TETHER_HAS_PARENT 8u

static void tether_apply_prop(LIBMTP_file_t *file, unsigned *seen, MTPProperties const *prop)
{
  switch (prop->property) {
  case PTP_OPC_ObjectFileName:
    if (prop->propval.str != NULL && file->filename == NULL) {
      file->filename = strdup(prop->propval.str);
      *seen |= TETHER_HAS_NAME;
    }
    break;
  case PTP_OPC_ObjectFormat:
    file->filetype = map_ptp_type_to_libmtp_type(prop->propval.u16);
    *seen |= TETHER_HAS_FORMAT;
    break;
  case PTP_OPC_ObjectSize:
    file->filesize = prop->datatype == PTP_DTC_UINT64 ? prop->propval.u64 : prop->propval.u32;
    *seen |= TETHER_HAS_SIZE;
    break;
  case PTP_OPC_DateModified:
    file->modificationdate = tether_ptptime(prop->propval.str);
    break;
  case PTP_OPC_ParentObject:
    file->parent_id = prop->propval.u32;
    *seen |= TETHER_HAS_PARENT;
    break;
  case PTP_OPC_StorageID:
    file->storage_id = prop->propval.u32;
    break;
  default:
    break;
  }
}

/* A record is usable only with a name, a format, and (for files) a size. */
static int tether_complete(LIBMTP_file_t const *file, unsigned seen)
{
  if ((seen & (TETHER_HAS_NAME | TETHER_HAS_FORMAT)) != (TETHER_HAS_NAME | TETHER_HAS_FORMAT))
    return 0;
  return file->filetype == LIBMTP_FILETYPE_FOLDER || (seen & TETHER_HAS_SIZE);
}

static LIBMTP_file_t *tether_new_file(uint32_t handle, uint32_t storage, uint32_t parent)
{
  LIBMTP_file_t *file = LIBMTP_new_file_t();
  if (file != NULL) {
    file->item_id = handle;
    file->storage_id = storage;
    file->parent_id = parent;
  }
  return file;
}

typedef struct { uint32_t handle; int index; } tether_slot_t;

static int tether_slot_cmp(void const *a, void const *b)
{
  uint32_t x = ((tether_slot_t const *) a)->handle, y = ((tether_slot_t const *) b)->handle;
  return x < y ? -1 : x > y;
}

/**
 * Reads the properties of every child of `parent` with one GetObjectPropList (depth 1).
 * `handles` are the children from LIBMTP_Get_Children; `out[i]` receives the record for `handles[i]`, or NULL when the
 * reply had no complete record for it (the caller then asks for that object on its own).
 * Never pass the storage root (0xFFFFFFFF): depth 1 there makes Android walk the whole storage and the USB call
 * times out, leaving the session unusable.
 * Returns 0 on success, -1 if the device refused the request (every out[i] is then NULL).
 */
int LIBMTP_Tether_Get_Folder_Props(LIBMTP_mtpdevice_t *device, uint32_t const storage, uint32_t const parent,
                                   uint32_t const *handles, int const count, LIBMTP_file_t **out)
{
  PTPParams *params = (PTPParams *) device->params;
  MTPProperties *props = NULL;
  int nprops = 0, i;
  tether_slot_t *slots;
  unsigned *seen;
  uint16_t ret;

  for (i = 0; i < count; i++)
    out[i] = NULL;
  if (count <= 0 || parent == 0 || parent == 0xFFFFFFFFU)
    return -1;
  if (!ptp_operation_issupported(params, PTP_OC_MTP_GetObjPropList))
    return -1;

  ret = ptp_mtp_getobjectproplist_generic(params, parent, 0x00000000U, 0xFFFFFFFFU, 0, 1, &props, &nprops);
  if (ret != PTP_RC_OK) {
    add_ptp_error_to_errorstack(device, ret, "LIBMTP_Tether_Get_Folder_Props(): GetObjectPropList failed.");
    return -1;
  }

  slots = malloc(sizeof(tether_slot_t) * (size_t) count);
  seen = calloc((size_t) count, sizeof(unsigned));
  if (slots == NULL || seen == NULL) {
    free(slots);
    free(seen);
    ptp_destroy_object_prop_list(props, nprops);
    return -1;
  }
  for (i = 0; i < count; i++) {
    slots[i].handle = handles[i];
    slots[i].index = i;
  }
  qsort(slots, (size_t) count, sizeof(tether_slot_t), tether_slot_cmp);

  for (i = 0; i < nprops; i++) {
    tether_slot_t key, *slot;
    int index;
    /* The reply also carries the folder itself and may carry objects that appeared since GetObjectHandles. */
    key.handle = props[i].ObjectHandle;
    slot = bsearch(&key, slots, (size_t) count, sizeof(tether_slot_t), tether_slot_cmp);
    if (slot == NULL)
      continue;
    index = slot->index;
    if (out[index] == NULL && (out[index] = tether_new_file(handles[index], storage, parent)) == NULL)
      continue;
    tether_apply_prop(out[index], &seen[index], &props[i]);
  }

  for (i = 0; i < count; i++) {
    if (out[i] == NULL)
      continue;
    if (!tether_complete(out[i], seen[i]) || ((seen[i] & TETHER_HAS_PARENT) && out[i]->parent_id != parent)) {
      LIBMTP_destroy_file_t(out[i]);
      out[i] = NULL;
    }
  }

  free(slots);
  free(seen);
  ptp_destroy_object_prop_list(props, nprops);
  return 0;
}

/**
 * One object's record from GetObjectPropList (depth 0), or NULL if the device refused or the reply was incomplete.
 * About 4x faster than GetObjectInfo for photos on Android.
 */
LIBMTP_file_t *LIBMTP_Tether_Get_File_Props(LIBMTP_mtpdevice_t *device, uint32_t const handle)
{
  PTPParams *params = (PTPParams *) device->params;
  MTPProperties *props = NULL;
  LIBMTP_file_t *file;
  unsigned seen = 0;
  int nprops = 0, i;

  if (!ptp_operation_issupported(params, PTP_OC_MTP_GetObjPropList))
    return NULL;
  if (ptp_mtp_getobjectproplist_single(params, handle, &props, &nprops) != PTP_RC_OK)
    return NULL;
  file = tether_new_file(handle, 0, 0);
  for (i = 0; file != NULL && i < nprops; i++) {
    if (props[i].ObjectHandle == handle)
      tether_apply_prop(file, &seen, &props[i]);
  }
  ptp_destroy_object_prop_list(props, nprops);
  if (file != NULL && (!tether_complete(file, seen) || !(seen & TETHER_HAS_PARENT))) {
    LIBMTP_destroy_file_t(file);
    file = NULL;
  }
  return file;
}
