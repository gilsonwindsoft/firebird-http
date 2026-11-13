// Package fb wraps the legacy Firebird client API (libfbclient) with cgo.
// Callers must serialize calls per attachment; libfbclient is thread-safe
// across different attachments.
package fb

/*
#cgo LDFLAGS: -lfbclient
#include <stdlib.h>
#include <string.h>
#include "shim.h"
*/
import "C"

import (
	"encoding/binary"
	"unsafe"

	"fbhttp/gateway/internal/protocol"
)

type Handle = C.FB_API_HANDLE

// Statement types (isc_info_sql_stmt_*).
const (
	StmtSelect       = 1
	StmtSelectForUpd = 12
)

const (
	sqlVarying = C.SQL_VARYING
	maxInfoBuf = 0x7FFF
	growDesc   = 32
)

// Status error codes used outside this package.
const (
	ErrSegment   = C.isc_segment
	ErrSegstrEOF = C.isc_segstr_eof
)

type status [20]C.ISC_STATUS

func (s *status) p() *C.ISC_STATUS { return &s[0] }

// failed converts a non-zero status vector into a protocol error.
func (s *status) failed() *protocol.Error {
	if s[0] != 1 || s[1] == 0 {
		return nil
	}
	e := &protocol.Error{Category: protocol.CatFirebird, SQLCode: int32(C.isc_sqlcode(s.p()))}
	for i := 0; i < len(s) && s[i] != C.isc_arg_end; {
		tag := uint32(s[i])
		switch {
		case tag == C.isc_arg_cstring && i+2 < len(s):
			n := C.int(s[i+1])
			e.Status = append(e.Status, protocol.StatusItem{Tag: tag, Str: C.GoStringN(C.shim_status_str(s[i+2]), n)})
			i += 3
		case protocol.IsStringTag(tag) && i+1 < len(s):
			e.Status = append(e.Status, protocol.StatusItem{Tag: tag, Str: C.GoString(C.shim_status_str(s[i+1]))})
			i += 2
		case i+1 < len(s):
			e.Status = append(e.Status, protocol.StatusItem{Tag: tag, Num: int64(s[i+1])})
			i += 2
		default:
			i = len(s)
		}
	}
	// fb_interpret advances a pointer to the vector, so both live in C memory.
	cv := (*status)(C.malloc(C.size_t(unsafe.Sizeof(*s))))
	defer C.free(unsafe.Pointer(cv))
	*cv = *s
	pv := (**C.ISC_STATUS)(C.malloc(C.size_t(unsafe.Sizeof(uintptr(0)))))
	defer C.free(unsafe.Pointer(pv))
	*pv = cv.p()
	buf := (*C.char)(C.malloc(1024))
	defer C.free(unsafe.Pointer(buf))
	for C.fb_interpret(buf, 1024, pv) > 0 {
		e.Messages = append(e.Messages, C.GoString(buf))
	}
	return e
}

func cbytes(b []byte) (*C.char, func()) {
	if len(b) == 0 {
		return nil, func() {}
	}
	p := C.CBytes(b)
	return (*C.char)(p), func() { C.free(p) }
}

func info(call func(st *status, items *C.char, n C.short, buf *C.char, buflen C.short), items []byte, buflen uint32) ([]byte, *protocol.Error) {
	if buflen > maxInfoBuf {
		buflen = maxInfoBuf
	}
	ci, free := cbytes(items)
	defer free()
	buf := C.calloc(C.size_t(buflen)+1, 1)
	defer C.free(buf)
	var st status
	call(&st, ci, C.short(len(items)), (*C.char)(buf), C.short(buflen))
	if e := st.failed(); e != nil {
		return nil, e
	}
	return C.GoBytes(buf, C.int(buflen)), nil
}

// ---- attachment ----

func Attach(target string, dpb []byte) (Handle, *protocol.Error) {
	name := C.CString(target)
	defer C.free(unsafe.Pointer(name))
	cd, free := cbytes(dpb)
	defer free()
	var st status
	var db Handle
	C.isc_attach_database(st.p(), C.short(len(target)), name, &db, C.short(len(dpb)), cd)
	return db, st.failed()
}

func Detach(db *Handle) *protocol.Error {
	var st status
	C.isc_detach_database(st.p(), db)
	return st.failed()
}

func DatabaseInfo(db Handle, items []byte, buflen uint32) ([]byte, *protocol.Error) {
	return info(func(st *status, it *C.char, n C.short, buf *C.char, bl C.short) {
		C.isc_database_info(st.p(), &db, n, it, bl, buf)
	}, items, buflen)
}

// ---- transactions ----

func StartTransaction(db Handle, tpb []byte) (Handle, *protocol.Error) {
	ct, free := cbytes(tpb)
	defer free()
	var st status
	var tr Handle
	C.shim_start_transaction(st.p(), &tr, &db, C.short(len(tpb)), ct)
	return tr, st.failed()
}

func Commit(tr *Handle) *protocol.Error {
	var st status
	C.isc_commit_transaction(st.p(), tr)
	return st.failed()
}

func Rollback(tr *Handle) *protocol.Error {
	var st status
	C.isc_rollback_transaction(st.p(), tr)
	return st.failed()
}

func CommitRetaining(tr *Handle) *protocol.Error {
	var st status
	C.isc_commit_retaining(st.p(), tr)
	return st.failed()
}

func RollbackRetaining(tr *Handle) *protocol.Error {
	var st status
	C.isc_rollback_retaining(st.p(), tr)
	return st.failed()
}

func TransactionInfo(tr Handle, items []byte, buflen uint32) ([]byte, *protocol.Error) {
	return info(func(st *status, it *C.char, n C.short, buf *C.char, bl C.short) {
		C.isc_transaction_info(st.p(), &tr, n, it, bl, buf)
	}, items, buflen)
}

// ---- XSQLDA helpers ----

func describe(da *C.XSQLDA) []protocol.Var {
	vars := make([]protocol.Var, int(da.sqld))
	for i := range vars {
		v := C.shim_var(da, C.int(i))
		vars[i] = protocol.Var{
			Type: int16(v.sqltype), Scale: int16(v.sqlscale), SubType: int16(v.sqlsubtype), Len: int16(v.sqllen),
			Name:      C.GoStringN(&v.sqlname[0], C.int(v.sqlname_length)),
			RelName:   C.GoStringN(&v.relname[0], C.int(v.relname_length)),
			OwnName:   C.GoStringN(&v.ownname[0], C.int(v.ownname_length)),
			AliasName: C.GoStringN(&v.aliasname[0], C.int(v.aliasname_length)),
		}
	}
	return vars
}

// newSQLDA builds an XSQLDA with buffers from a client layout. Nil layout gives nil.
func newSQLDA(l protocol.Layout) *C.XSQLDA {
	if l == nil {
		return nil
	}
	da := C.shim_sqlda_new(C.short(len(l)))
	if da == nil {
		panic("fb: out of memory")
	}
	da.sqld = C.short(len(l))
	for i, x := range l {
		v := C.shim_var(da, C.int(i))
		v.sqltype, v.sqlscale, v.sqlsubtype, v.sqllen = C.short(x.Type), C.short(x.Scale), C.short(x.SubType), C.short(x.Len)
	}
	if C.shim_sqlda_alloc_buffers(da) != 0 {
		C.shim_sqlda_free(da)
		panic("fb: out of memory")
	}
	return da
}

// varData returns the sqldata buffer of v, sized as shim_sqlda_alloc_buffers allocated it.
func varData(v *C.XSQLVAR) []byte {
	size := int(uint16(v.sqllen))
	if v.sqltype&^1 == sqlVarying {
		size += 2
	}
	return unsafe.Slice((*byte)(unsafe.Pointer(v.sqldata)), size)
}

func setRow(da *C.XSQLDA, row []protocol.Value) {
	for i, val := range row {
		v := C.shim_var(da, C.int(i))
		size := int(uint16(v.sqllen))
		data := varData(v)
		if val.Null {
			*v.sqlind = -1
			continue
		}
		*v.sqlind = 0
		if v.sqltype&^1 == sqlVarying {
			n := min(len(val.Data), size)
			binary.NativeEndian.PutUint16(data, uint16(n))
			copy(data[2:], val.Data[:n])
		} else {
			copy(data[:size], val.Data)
		}
	}
}

func getRow(da *C.XSQLDA) []protocol.Value {
	row := make([]protocol.Value, int(da.sqld))
	for i := range row {
		v := C.shim_var(da, C.int(i))
		if v.sqltype&1 == 1 && *v.sqlind < 0 {
			row[i].Null = true
			continue
		}
		size := int(uint16(v.sqllen))
		data := varData(v)
		if v.sqltype&^1 == sqlVarying {
			n := min(int(binary.NativeEndian.Uint16(data)), size)
			row[i].Data = append([]byte(nil), data[2:2+n]...)
		} else {
			row[i].Data = append([]byte(nil), data[:size]...)
		}
	}
	return row
}

// ---- statements ----

// Stmt is a DSQL statement with its open-cursor output buffer.
type Stmt struct {
	H    Handle
	Type int32
	out  *C.XSQLDA // output buffers of the open cursor
}

func Allocate(db Handle) (*Stmt, *protocol.Error) {
	var st status
	s := &Stmt{}
	C.isc_dsql_allocate_statement(st.p(), &db, &s.H)
	return s, st.failed()
}

func (s *Stmt) releaseOut() {
	C.shim_sqlda_free(s.out)
	s.out = nil
}

// Prepare prepares sql and returns the output and input descriptions.
func (s *Stmt) Prepare(tr Handle, dialect uint16, sql string) (out, in []protocol.Var, e *protocol.Error) {
	s.releaseOut()
	csql := C.CString(sql)
	defer C.free(unsafe.Pointer(csql))
	var st status
	da := C.shim_sqlda_new(growDesc)
	defer func() { C.shim_sqlda_free(da) }()
	C.isc_dsql_prepare(st.p(), &tr, &s.H, C.ushort(len(sql)), csql, C.ushort(dialect), da)
	if e := st.failed(); e != nil {
		return nil, nil, e
	}
	if da.sqld > da.sqln {
		n := da.sqld
		C.shim_sqlda_free(da)
		da = C.shim_sqlda_new(n)
		if C.isc_dsql_describe(st.p(), &s.H, C.ushort(dialect), da); st.failed() != nil {
			return nil, nil, st.failed()
		}
	}
	out = describe(da)

	bind := C.shim_sqlda_new(growDesc)
	defer func() { C.shim_sqlda_free(bind) }()
	if C.isc_dsql_describe_bind(st.p(), &s.H, C.ushort(dialect), bind); st.failed() != nil {
		return nil, nil, st.failed()
	}
	if bind.sqld > bind.sqln {
		n := bind.sqld
		C.shim_sqlda_free(bind)
		bind = C.shim_sqlda_new(n)
		if C.isc_dsql_describe_bind(st.p(), &s.H, C.ushort(dialect), bind); st.failed() != nil {
			return nil, nil, st.failed()
		}
	}
	in = describe(bind)

	typ, e := s.SQLInfo([]byte{C.isc_info_sql_stmt_type, C.isc_info_end}, 16)
	if e != nil {
		return nil, nil, e
	}
	s.Type = int32(parseInfoInt(typ, C.isc_info_sql_stmt_type))
	return out, in, nil
}

// IsCursor reports if executing the statement opens a cursor.
func (s *Stmt) IsCursor() bool { return s.Type == StmtSelect || s.Type == StmtSelectForUpd }

func (s *Stmt) Free(option uint16) *protocol.Error {
	var st status
	C.isc_dsql_free_statement(st.p(), &s.H, C.ushort(option))
	if option != C.DSQL_drop || st.failed() == nil {
		s.releaseOut()
	}
	return st.failed()
}

// Open executes a cursor statement and keeps out for fetches.
func (s *Stmt) Open(tr *Handle, dialect uint16, inL protocol.Layout, inRow []protocol.Value, outL protocol.Layout) *protocol.Error {
	s.releaseOut()
	in := newSQLDA(inL)
	defer C.shim_sqlda_free(in)
	if in != nil {
		setRow(in, inRow)
	}
	var st status
	C.isc_dsql_execute(st.p(), tr, &s.H, C.ushort(dialect), in)
	if e := st.failed(); e != nil {
		return e
	}
	s.out = newSQLDA(outL)
	return nil
}

// Execute runs isc_dsql_execute2. It returns the output row when outL is
// not nil and the statement produced one.
func (s *Stmt) Execute(tr *Handle, dialect uint16, inL protocol.Layout, inRow []protocol.Value, outL protocol.Layout) ([]protocol.Value, *protocol.Error) {
	s.releaseOut()
	in, out := newSQLDA(inL), newSQLDA(outL)
	defer C.shim_sqlda_free(in)
	defer C.shim_sqlda_free(out)
	if in != nil {
		setRow(in, inRow)
	}
	var st status
	rc := C.isc_dsql_execute2(st.p(), tr, &s.H, C.ushort(dialect), in, out)
	if e := st.failed(); e != nil {
		return nil, e
	}
	if out == nil || rc == 100 { // 100: singleton select without rows
		return nil, nil
	}
	return getRow(out), nil
}

// SetOutLayout replaces the fetch buffer layout (FETCH with a new layout).
func (s *Stmt) SetOutLayout(outL protocol.Layout) {
	s.releaseOut()
	s.out = newSQLDA(outL)
}

// Fetch reads up to n rows. eof is true when the cursor has no more rows.
func (s *Stmt) Fetch(n int) (rows [][]protocol.Value, eof bool, e *protocol.Error) {
	if s.out == nil {
		s.out = newSQLDA(protocol.Layout{})
	}
	var st status
	for len(rows) < n {
		rc := C.isc_dsql_fetch(st.p(), &s.H, C.ushort(C.SQL_DIALECT_CURRENT), s.out)
		if rc == 100 {
			return rows, true, nil
		}
		if e := st.failed(); e != nil {
			return rows, false, e
		}
		rows = append(rows, getRow(s.out))
	}
	return rows, false, nil
}

func (s *Stmt) SQLInfo(items []byte, buflen uint32) ([]byte, *protocol.Error) {
	return info(func(st *status, it *C.char, n C.short, buf *C.char, bl C.short) {
		C.isc_dsql_sql_info(st.p(), &s.H, n, it, bl, buf)
	}, items, buflen)
}

// RecordsInfo returns the isc_info_sql_records block (rows affected).
func (s *Stmt) RecordsInfo() ([]byte, *protocol.Error) {
	return s.SQLInfo([]byte{C.isc_info_sql_records, C.isc_info_end}, 64)
}

func (s *Stmt) SetCursorName(name string) *protocol.Error {
	cn := C.CString(name)
	defer C.free(unsafe.Pointer(cn))
	var st status
	C.isc_dsql_set_cursor_name(st.p(), &s.H, cn, 0)
	return st.failed()
}

// ExecImmediate runs isc_dsql_exec_immed2. tr may change (SET TRANSACTION, COMMIT).
func ExecImmediate(db Handle, tr *Handle, dialect uint16, sql string, inL protocol.Layout, inRow []protocol.Value, outL protocol.Layout) ([]protocol.Value, *protocol.Error) {
	in, out := newSQLDA(inL), newSQLDA(outL)
	defer C.shim_sqlda_free(in)
	defer C.shim_sqlda_free(out)
	if in != nil {
		setRow(in, inRow)
	}
	csql := C.CString(sql)
	defer C.free(unsafe.Pointer(csql))
	var st status
	C.isc_dsql_exec_immed2(st.p(), &db, tr, C.ushort(len(sql)), csql, C.ushort(dialect), in, out)
	if e := st.failed(); e != nil {
		return nil, e
	}
	if out == nil {
		return nil, nil
	}
	return getRow(out), nil
}

// parseInfoInt reads the integer value of item from an info buffer.
func parseInfoInt(b []byte, item byte) int64 {
	for i := 0; i+3 <= len(b) && b[i] != C.isc_info_end; {
		n := int(binary.LittleEndian.Uint16(b[i+1:]))
		if i+3+n > len(b) {
			break
		}
		if b[i] == item {
			return int64(C.isc_portable_integer((*C.ISC_UCHAR)(unsafe.Pointer(&b[i+3])), C.short(n)))
		}
		i += 3 + n
	}
	return 0
}

// ---- blobs ----

type Quad = [8]byte

func toQuad(q Quad) C.ISC_QUAD          { return *(*C.ISC_QUAD)(unsafe.Pointer(&q)) }
func fromQuad(q C.ISC_QUAD) (out Quad) { return *(*Quad)(unsafe.Pointer(&q)) }

// BlobInfoItems is the item list OPEN_BLOB answers with.
var BlobInfoItems = []byte{C.isc_info_blob_total_length, C.isc_info_blob_max_segment, C.isc_info_blob_num_segments, C.isc_info_blob_type, C.isc_info_end}

func OpenBlob(db, tr Handle, id Quad, bpb []byte) (Handle, *protocol.Error) {
	cb, free := cbytes(bpb)
	defer free()
	q := toQuad(id)
	var st status
	var b Handle
	C.isc_open_blob2(st.p(), &db, &tr, &b, &q, C.ISC_USHORT(len(bpb)), (*C.ISC_UCHAR)(unsafe.Pointer(cb)))
	return b, st.failed()
}

func CreateBlob(db, tr Handle, bpb []byte) (Handle, Quad, *protocol.Error) {
	cb, free := cbytes(bpb)
	defer free()
	var q C.ISC_QUAD
	var st status
	var b Handle
	C.isc_create_blob2(st.p(), &db, &tr, &b, &q, C.short(len(bpb)), cb)
	return b, fromQuad(q), st.failed()
}

// BlobTotalLength extracts isc_info_blob_total_length from an info block.
func BlobTotalLength(info []byte) int64 { return parseInfoInt(info, C.isc_info_blob_total_length) }

// ReadBlob reads up to max bytes, merging segments. eof is true at the end.
func ReadBlob(b Handle, max int) (data []byte, eof bool, e *protocol.Error) {
	const seg = 0xFFFF
	buf := C.malloc(seg)
	defer C.free(buf)
	var st status
	for len(data) < max {
		var got C.ushort
		want := min(seg, max-len(data))
		C.isc_get_segment(st.p(), &b, &got, C.ushort(want), (*C.char)(buf))
		data = append(data, C.GoBytes(buf, C.int(got))...)
		if st[1] == C.isc_segstr_eof {
			return data, true, nil
		}
		if st[1] != 0 && st[1] != C.isc_segment {
			return nil, false, st.failed()
		}
	}
	return data, false, nil
}

func PutSegment(b Handle, data []byte) *protocol.Error {
	cd, free := cbytes(data)
	defer free()
	var st status
	C.isc_put_segment(st.p(), &b, C.ushort(len(data)), cd)
	return st.failed()
}

func CloseBlob(b *Handle) *protocol.Error {
	var st status
	C.isc_close_blob(st.p(), b)
	return st.failed()
}

func CancelBlob(b *Handle) *protocol.Error {
	var st status
	C.isc_cancel_blob(st.p(), b)
	return st.failed()
}

func BlobInfo(b Handle, items []byte, buflen uint32) ([]byte, *protocol.Error) {
	return info(func(st *status, it *C.char, n C.short, buf *C.char, bl C.short) {
		C.isc_blob_info(st.p(), &b, n, it, bl, buf)
	}, items, buflen)
}

// ---- DPB ----

// stripped DPB tags: local configuration and OS-level authentication must
// not be controlled by remote clients.
var strippedDPB = map[byte]bool{
	C.isc_dpb_config:            true,
	C.isc_dpb_working_directory: true,
	C.isc_dpb_trusted_auth:      true,
	C.isc_dpb_trusted_role:      true,
}

// walkDPB calls fn for each clumplet (tag, raw bytes including header, value).
// It supports isc_dpb_version1 (1-byte lengths) and isc_dpb_version2 (4-byte lengths).
func walkDPB(dpb []byte, fn func(tag byte, raw, val []byte)) bool {
	if len(dpb) == 0 {
		return true
	}
	wide := dpb[0] == C.isc_dpb_version2
	if dpb[0] != C.isc_dpb_version1 && !wide {
		return false
	}
	hdr := 2
	if wide {
		hdr = 5
	}
	for i := 1; i < len(dpb); {
		if i+hdr > len(dpb) {
			return false
		}
		n := uint64(dpb[i+1])
		if wide {
			n = uint64(binary.LittleEndian.Uint32(dpb[i+1:]))
		}
		end := uint64(i+hdr) + n
		if end > uint64(len(dpb)) {
			return false
		}
		fn(dpb[i], dpb[i:end], dpb[i+hdr:end])
		i = int(end)
	}
	return true
}

// SanitizeDPB removes the stripped tags. ok is false for a malformed DPB.
func SanitizeDPB(dpb []byte) (out []byte, ok bool) {
	if len(dpb) > 0 {
		out = []byte{dpb[0]}
	}
	ok = walkDPB(dpb, func(tag byte, raw, _ []byte) {
		if !strippedDPB[tag] {
			out = append(out, raw...)
		}
	})
	return out, ok
}

// AddDPBDefault appends tag=value unless the DPB already has tag.
func AddDPBDefault(dpb []byte, tag byte, value string) []byte {
	has := false
	walkDPB(dpb, func(t byte, _, _ []byte) {
		if t == tag {
			has = true
		}
	})
	if has || value == "" {
		return dpb
	}
	if len(dpb) == 0 {
		dpb = []byte{C.isc_dpb_version1}
	}
	if dpb[0] == C.isc_dpb_version2 {
		dpb = append(dpb, tag)
		dpb = binary.LittleEndian.AppendUint32(dpb, uint32(len(value)))
		return append(dpb, value...)
	}
	if len(value) > 255 {
		return dpb
	}
	dpb = append(dpb, tag, byte(len(value)))
	return append(dpb, value...)
}

// DPBSetBind is isc_dpb_set_bind (Firebird 4+).
const DPBSetBind = C.isc_dpb_set_bind

// DPBUser returns isc_dpb_user_name, for logging.
func DPBUser(dpb []byte) (user string) {
	walkDPB(dpb, func(tag byte, _, val []byte) {
		if tag == C.isc_dpb_user_name {
			user = string(val)
		}
	})
	return user
}

// CodeError builds the Firebird error for a single gds code, with the
// message text from fb_interpret (for example isc_bad_stmt_handle).
func CodeError(code int64) *protocol.Error {
	var st status
	st[0], st[1], st[2] = 1, C.ISC_STATUS(code), C.isc_arg_end
	return st.failed()
}

const (
	ErrBadDBHandle    = C.isc_bad_db_handle
	ErrBadTransHandle = C.isc_bad_trans_handle
	ErrBadStmtHandle  = C.isc_bad_stmt_handle
	ErrBadBlobHandle  = C.isc_bad_segstr_handle
)

// ClientVersion returns the libfbclient version string.
func ClientVersion() string {
	buf := (*C.char)(C.malloc(256))
	defer C.free(unsafe.Pointer(buf))
	C.isc_get_client_version(buf)
	return C.GoString(buf)
}
