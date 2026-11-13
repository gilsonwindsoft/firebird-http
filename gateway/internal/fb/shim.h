// Small C helpers for things cgo cannot do directly: variadic/struct
// arguments and XSQLDA buffer management.
#ifndef FBHTTP_SHIM_H
#define FBHTTP_SHIM_H

#include <ibase.h>

// Starts a transaction on one attachment (isc_start_transaction is variadic).
ISC_STATUS shim_start_transaction(ISC_STATUS* st, isc_tr_handle* tr, isc_db_handle* db,
                                  short tpb_len, const char* tpb);

// Allocates an XSQLDA with n vars (sqln = n, sqld = 0). Buffers are not allocated.
XSQLDA* shim_sqlda_new(short n);

// Allocates sqldata/sqlind for every var according to its sqltype/sqllen.
// Returns 0 on success, -1 on out of memory.
int shim_sqlda_alloc_buffers(XSQLDA* da);

// Frees the data buffers and the XSQLDA. Accepts NULL.
void shim_sqlda_free(XSQLDA* da);

// Status vector string arguments are pointers stored as ISC_STATUS.
static inline const char* shim_status_str(ISC_STATUS v) { return (const char*)v; }

static inline XSQLVAR* shim_var(XSQLDA* da, int i) { return &da->sqlvar[i]; }

#endif
