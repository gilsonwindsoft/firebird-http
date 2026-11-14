package protocol

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestRequestRoundTrip(t *testing.T) {
	in := Request{Version: Version, Seq: 7, Ops: []Op{
		{Code: OpFree, Flags: FlagDeferred, Payload: []byte{1, 0, 0, 0, 2, 0}},
		{Code: OpExecute, Payload: []byte("x")},
	}}
	out, err := DecodeRequest(EncodeRequest(in))
	if err != nil || !reflect.DeepEqual(in, out) {
		t.Fatalf("got %+v, %v", out, err)
	}
}

func TestRequestTruncated(t *testing.T) {
	b := EncodeRequest(Request{Version: 1, Seq: 1, Ops: []Op{{Code: 1, Payload: []byte("abc")}}})
	for i := range len(b) {
		if _, err := DecodeRequest(b[:i]); err == nil {
			t.Fatalf("no error for %d bytes", i)
		}
	}
}

func TestHugeLengthRejected(t *testing.T) {
	r := &Reader{B: []byte{0xff, 0xff, 0xff, 0xff, 1}}
	if r.Bytes(); r.Err == nil {
		t.Fatal("expected error")
	}
}

func TestResponseRoundTrip(t *testing.T) {
	in := []Result{{Code: OpPrepare, Status: StatusOK, Payload: []byte{1, 2}}, {Code: OpExecute, Status: StatusError, Payload: []byte{}}}
	out, err := DecodeResponse(EncodeResponse(in))
	if err != nil || !reflect.DeepEqual(in, out) {
		t.Fatalf("got %+v, %v", out, err)
	}
}

func sampleError() *Error {
	return &Error{Category: CatFirebird, SQLCode: -803,
		Status:   []StatusItem{{Tag: 1, Num: 335544665}, {Tag: ArgString, Str: "PK_T"}, {Tag: ArgString, Str: "T"}, {Tag: ArgSQLState, Str: "23000"}},
		Messages: []string{"violation of PRIMARY or UNIQUE KEY constraint \"PK_T\" on table \"T\""},
		SQLText:  "Attempt to store duplicate value (visible to active transactions) in unique index \"PK_T\""}
}

func TestErrorRoundTrip(t *testing.T) {
	in := sampleError()
	out, err := DecodeError(EncodeError(in))
	if err != nil || !reflect.DeepEqual(in, out) {
		t.Fatalf("got %+v, %v", out, err)
	}
}

// An error block from a gateway that predates SQLText still decodes.
func TestErrorWithoutSQLText(t *testing.T) {
	in := sampleError()
	in.SQLText = ""
	out, err := DecodeError(EncodeError(in))
	if err != nil || !reflect.DeepEqual(in, out) {
		t.Fatalf("got %+v, %v", out, err)
	}
}

func sampleLayout() Layout {
	return Layout{{Type: 497, Len: 4}, {Type: 449, Len: 10}, {Type: 581, Scale: -4, Len: 8}, {Type: 453, Len: 3}}
}

func sampleRow() []Value {
	return []Value{
		{Data: []byte{1, 0, 0, 0}},
		{Data: []byte{}}, // empty varchar, not NULL
		{Null: true},
		{Data: []byte("abc")},
	}
}

func TestRowRoundTrip(t *testing.T) {
	l := sampleLayout()
	w := &Writer{}
	WriteLayout(w, l)
	WriteRow(w, l, sampleRow())
	r := &Reader{B: w.B}
	l2 := ReadLayout(r)
	row := ReadRow(r, l2)
	if r.Err != nil || !reflect.DeepEqual(l, l2) || !reflect.DeepEqual(sampleRow(), row) || len(r.B) != 0 {
		t.Fatalf("got %+v %+v %v", l2, row, r.Err)
	}
}

func TestNoLayout(t *testing.T) {
	w := &Writer{}
	WriteLayout(w, nil)
	if l := ReadLayout(&Reader{B: w.B}); l != nil {
		t.Fatalf("got %+v", l)
	}
}

func TestVaryingTooLong(t *testing.T) {
	l := Layout{{Type: 448, Len: 2}}
	w := &Writer{}
	WriteRow(w, l, []Value{{Data: []byte("abc")}})
	r := &Reader{B: w.B}
	if ReadRow(r, l); r.Err == nil {
		t.Fatal("expected error")
	}
}

// TestWriteFixtures writes sample messages to testdata/ so the Delphi codec
// tests (client/tests) can check they decode the same bytes.
func TestWriteFixtures(t *testing.T) {
	dir := filepath.Join("..", "..", "..", "tests", "protocol-fixtures")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	w := &Writer{}
	WriteLayout(w, sampleLayout())
	WriteRow(w, sampleLayout(), sampleRow())
	files := map[string][]byte{
		"error.bin": EncodeError(sampleError()),
		"row.bin":   w.B,
		"request.bin": EncodeRequest(Request{Version: Version, Seq: 2, Ops: []Op{
			{Code: OpFree, Flags: FlagDeferred, Payload: []byte{5, 0, 0, 0, 2, 0}},
			{Code: OpFetch, Payload: []byte{5, 0, 0, 0, 200, 0, 0, 0}},
		}}),
	}
	for name, b := range files {
		if err := os.WriteFile(filepath.Join(dir, name), b, 0o644); err != nil {
			t.Fatal(err)
		}
	}
}
