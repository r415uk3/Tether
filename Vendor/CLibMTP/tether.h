// Tether's additions to libmtp, implemented in Vendor/patches/tether-proplist.c (appended to libmtp.c at build time).
#include "../build/include/libmtp.h"

/// Fills `out[i]` with the record for `handles[i]` from one GetObjectPropList on `parent`, or NULL where the reply had
/// no complete record. Never call it for the storage root. Returns 0, or -1 if the device refused the request.
int LIBMTP_Tether_Get_Folder_Props(LIBMTP_mtpdevice_t *device, uint32_t const storage, uint32_t const parent,
                                   uint32_t const *handles, int const count, LIBMTP_file_t **out);

/// One object's record from GetObjectPropList, or NULL if refused or incomplete.
LIBMTP_file_t *LIBMTP_Tether_Get_File_Props(LIBMTP_mtpdevice_t *device, uint32_t const handle);
