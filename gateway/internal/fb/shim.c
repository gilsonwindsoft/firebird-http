#include <stdlib.h>
#include <string.h>
#include "shim.h"

ISC_STATUS shim_start_transaction(ISC_STATUS* st, isc_tr_handle* tr, isc_db_handle* db,
                                  short tpb_len, const char* tpb) {
	return isc_start_transaction(st, tr, 1, db, tpb_len, tpb);
}

XSQLDA* shim_sqlda_new(short n) {
	if (n < 1) n = 1;
	XSQLDA* da = (XSQLDA*)calloc(1, XSQLDA_LENGTH(n));
	if (!da) return NULL;
	da->version = SQLDA_VERSION1;
	da->sqln = n;
	return da;
}

int shim_sqlda_alloc_buffers(XSQLDA* da) {
	for (int i = 0; i < da->sqld; i++) {
		XSQLVAR* v = &da->sqlvar[i];
		size_t len = (size_t)(unsigned short)v->sqllen;
		if ((v->sqltype & ~1) == SQL_VARYING) len += 2;
		v->sqldata = (ISC_SCHAR*)calloc(1, len ? len : 1);
		v->sqlind = (short*)calloc(1, sizeof(short));
		if (!v->sqldata || !v->sqlind) return -1;
	}
	return 0;
}

void shim_sqlda_free(XSQLDA* da) {
	if (!da) return;
	for (int i = 0; i < da->sqln; i++) {
		free(da->sqlvar[i].sqldata);
		free(da->sqlvar[i].sqlind);
	}
	free(da);
}
