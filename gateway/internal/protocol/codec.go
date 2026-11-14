// Package protocol implements the fbhttp v1 wire format (docs/protocol.md).
package protocol

import (
	"encoding/binary"
	"errors"
)

const Version = 1

// Opcodes.
const (
	OpAttach           = 1
	OpDetach           = 2
	OpDatabaseInfo     = 3
	OpStartTransaction = 10
	OpCommit           = 11
	OpRollback         = 12
	OpCommitRetaining  = 13
	OpRollbackRetain   = 14
	OpTransactionInfo  = 15
	OpPrepare          = 20
	OpFree             = 21
	OpExecute          = 22
	OpExecuteImmediate = 23
	OpFetch            = 24
	OpSetCursorName    = 25
	OpSQLInfo          = 26
	OpOpenBlob         = 30
	OpGetSegments      = 31
	OpCreateBlob       = 32
	OpPutSegments      = 33
	OpCloseBlob        = 34
	OpCancelBlob       = 35
	OpBlobInfo         = 36
)

// Error categories.
const (
	CatFirebird = 1
	CatSession  = 2
	CatProtocol = 3
	CatLimit    = 4
	CatInternal = 5
)

// Result status.
const (
	StatusOK    = 0
	StatusError = 1
)

const FlagDeferred = 1

// NoLayout marks "no XSQLDA" in a layout field.
const NoLayout = 0xFFFF

// SQL_VARYING type code (without the nullable bit).
const sqlVarying = 448

var ErrShort = errors.New("protocol: truncated message")

// Writer appends little-endian values to a buffer.
type Writer struct{ B []byte }

func (w *Writer) U8(v uint8)   { w.B = append(w.B, v) }
func (w *Writer) U16(v uint16) { w.B = binary.LittleEndian.AppendUint16(w.B, v) }
func (w *Writer) U32(v uint32) { w.B = binary.LittleEndian.AppendUint32(w.B, v) }
func (w *Writer) I16(v int16)  { w.U16(uint16(v)) }
func (w *Writer) I32(v int32)  { w.U32(uint32(v)) }
func (w *Writer) I64(v int64)  { w.B = binary.LittleEndian.AppendUint64(w.B, uint64(v)) }
func (w *Writer) Raw(b []byte) { w.B = append(w.B, b...) }
func (w *Writer) Bytes(b []byte) {
	w.U32(uint32(len(b)))
	w.B = append(w.B, b...)
}
func (w *Writer) Str(s string) { w.Bytes([]byte(s)) }

// Reader consumes little-endian values. The first failure sticks in Err;
// later reads return zero values, so callers check Err once at the end.
type Reader struct {
	B   []byte
	Err error
}

func (r *Reader) take(n int) []byte {
	if r.Err != nil {
		return nil
	}
	if n < 0 || len(r.B) < n {
		r.Err = ErrShort
		r.B = nil
		return nil
	}
	b := r.B[:n:n]
	r.B = r.B[n:]
	return b
}

func (r *Reader) U8() uint8 {
	if b := r.take(1); b != nil {
		return b[0]
	}
	return 0
}
func (r *Reader) U16() uint16 {
	if b := r.take(2); b != nil {
		return binary.LittleEndian.Uint16(b)
	}
	return 0
}
func (r *Reader) U32() uint32 {
	if b := r.take(4); b != nil {
		return binary.LittleEndian.Uint32(b)
	}
	return 0
}
func (r *Reader) I16() int16 { return int16(r.U16()) }
func (r *Reader) I32() int32 { return int32(r.U32()) }
func (r *Reader) I64() int64 {
	if b := r.take(8); b != nil {
		return int64(binary.LittleEndian.Uint64(b))
	}
	return 0
}
func (r *Reader) Raw(n int) []byte { return r.take(n) }
func (r *Reader) Bytes() []byte {
	n := r.U32()
	if r.Err != nil {
		return nil
	}
	if uint64(n) > uint64(len(r.B)) {
		r.Err = ErrShort
		return nil
	}
	return r.take(int(n))
}
func (r *Reader) Str() string { return string(r.Bytes()) }

// Op is one operation of a request.
type Op struct {
	Code    uint16
	Flags   uint8
	Payload []byte
}

// Request is a decoded /v1/rpc body.
type Request struct {
	Version uint32
	Seq     uint32
	Ops     []Op
}

func EncodeRequest(req Request) []byte {
	w := &Writer{}
	w.U32(req.Version)
	w.U32(req.Seq)
	w.U16(uint16(len(req.Ops)))
	for _, op := range req.Ops {
		w.U16(op.Code)
		w.U8(op.Flags)
		w.Bytes(op.Payload)
	}
	return w.B
}

func DecodeRequest(b []byte) (Request, error) {
	r := &Reader{B: b}
	req := Request{Version: r.U32(), Seq: r.U32()}
	n := int(r.U16())
	for i := 0; i < n && r.Err == nil; i++ {
		req.Ops = append(req.Ops, Op{Code: r.U16(), Flags: r.U8(), Payload: r.Bytes()})
	}
	if r.Err == nil && len(r.B) != 0 {
		r.Err = errors.New("protocol: trailing bytes")
	}
	return req, r.Err
}

// Result is one operation result.
type Result struct {
	Code    uint16
	Status  uint8
	Payload []byte
}

func EncodeResponse(res []Result) []byte {
	w := &Writer{}
	w.U16(uint16(len(res)))
	for _, x := range res {
		w.U16(x.Code)
		w.U8(x.Status)
		w.Bytes(x.Payload)
	}
	return w.B
}

func DecodeResponse(b []byte) ([]Result, error) {
	r := &Reader{B: b}
	n := int(r.U16())
	var res []Result
	for i := 0; i < n && r.Err == nil; i++ {
		res = append(res, Result{Code: r.U16(), Status: r.U8(), Payload: r.Bytes()})
	}
	return res, r.Err
}

// Status vector argument tags (ibase.h).
const (
	ArgEnd         = 0
	ArgString      = 2
	ArgCString     = 3
	ArgInterpreted = 5
	ArgSQLState    = 19
)

// StatusItem is one status-vector entry: a tag and a numeric or string value.
type StatusItem struct {
	Tag uint32
	Num int64
	Str string
}

func IsStringTag(tag uint32) bool {
	return tag == ArgString || tag == ArgCString || tag == ArgInterpreted || tag == ArgSQLState
}

// Error is the error block of a failed operation.
type Error struct {
	Category uint8
	SQLCode  int32
	Status   []StatusItem // without the terminating ArgEnd
	Messages []string
	// SQLText is isc_sql_interprete(SQLCode). Optional trailing field: older
	// peers neither send nor read it.
	SQLText string
}

func (e *Error) Error() string {
	if len(e.Messages) > 0 {
		return e.Messages[0]
	}
	return "fbhttp error"
}

func EncodeError(e *Error) []byte {
	w := &Writer{}
	w.U8(e.Category)
	w.I32(e.SQLCode)
	for _, it := range e.Status {
		w.U32(it.Tag)
		if IsStringTag(it.Tag) {
			w.Str(it.Str)
		} else {
			w.I64(it.Num)
		}
	}
	w.U32(ArgEnd)
	w.U16(uint16(len(e.Messages)))
	for _, m := range e.Messages {
		w.Str(m)
	}
	if e.SQLText != "" {
		w.Str(e.SQLText)
	}
	return w.B
}

func DecodeError(b []byte) (*Error, error) {
	r := &Reader{B: b}
	e := &Error{Category: r.U8(), SQLCode: r.I32()}
	for r.Err == nil {
		tag := r.U32()
		if tag == ArgEnd || r.Err != nil {
			break
		}
		it := StatusItem{Tag: tag}
		if IsStringTag(tag) {
			it.Str = r.Str()
		} else {
			it.Num = r.I64()
		}
		e.Status = append(e.Status, it)
	}
	n := int(r.U16())
	for i := 0; i < n && r.Err == nil; i++ {
		e.Messages = append(e.Messages, r.Str())
	}
	if r.Err == nil && len(r.B) > 0 {
		e.SQLText = r.Str()
	}
	return e, r.Err
}

// Var describes one XSQLVAR.
type Var struct {
	Type, Scale, SubType, Len         int16
	Name, RelName, OwnName, AliasName string
}

func WriteDesc(w *Writer, vars []Var) {
	w.U16(uint16(len(vars)))
	for _, v := range vars {
		w.I16(v.Type)
		w.I16(v.Scale)
		w.I16(v.SubType)
		w.I16(v.Len)
		w.Str(v.Name)
		w.Str(v.RelName)
		w.Str(v.OwnName)
		w.Str(v.AliasName)
	}
}

func ReadDesc(r *Reader) []Var {
	n := int(r.U16())
	vars := make([]Var, 0, min(n, 1024))
	for i := 0; i < n && r.Err == nil; i++ {
		vars = append(vars, Var{Type: r.I16(), Scale: r.I16(), SubType: r.I16(), Len: r.I16(),
			Name: r.Str(), RelName: r.Str(), OwnName: r.Str(), AliasName: r.Str()})
	}
	return vars
}

// Layout is the type part of an XSQLDA. Nil means "no XSQLDA".
type Layout []Var

func WriteLayout(w *Writer, l Layout) {
	if l == nil {
		w.U16(NoLayout)
		return
	}
	w.U16(uint16(len(l)))
	for _, v := range l {
		w.I16(v.Type)
		w.I16(v.Scale)
		w.I16(v.SubType)
		w.I16(v.Len)
	}
}

func ReadLayout(r *Reader) Layout {
	n := r.U16()
	if n == NoLayout || r.Err != nil {
		return nil
	}
	l := make(Layout, 0, min(int(n), 1024))
	for i := 0; i < int(n) && r.Err == nil; i++ {
		l = append(l, Var{Type: r.I16(), Scale: r.I16(), SubType: r.I16(), Len: r.I16()})
	}
	return l
}

// Value is one column value: nil Data with Null=true means NULL.
// For SQL_VARYING, Data holds only the text (no length prefix).
type Value struct {
	Null bool
	Data []byte
}

func WriteRow(w *Writer, l Layout, row []Value) {
	for i, v := range row {
		if v.Null {
			w.U8(1)
			continue
		}
		w.U8(0)
		if l[i].Type&^1 == sqlVarying {
			w.U16(uint16(len(v.Data)))
		}
		w.Raw(v.Data)
	}
}

// ReadRow reads one row. Returned slices alias the reader buffer.
func ReadRow(r *Reader, l Layout) []Value {
	row := make([]Value, len(l))
	for i, v := range l {
		if r.U8() == 1 {
			row[i].Null = true
			continue
		}
		n := int(uint16(v.Len))
		if v.Type&^1 == sqlVarying {
			n = int(r.U16())
			if n > int(uint16(v.Len)) {
				r.Err = errors.New("protocol: varying value longer than sqllen")
			}
		}
		row[i].Data = r.Raw(n)
		if r.Err != nil {
			return nil
		}
	}
	return row
}
