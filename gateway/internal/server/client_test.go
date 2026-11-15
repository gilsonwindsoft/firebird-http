package server

// Minimal protocol client used by the integration tests. It mirrors what
// fbclienthttp.dll sends, so it doubles as a reference for the DLL.

import (
	"bytes"
	"io"
	"net/http"
	"testing"

	"fbhttp/gateway/internal/protocol"
)

// ibase.h constants used by the tests.
const (
	dpbVersion1 = 1
	dpbUserName = 28
	dpbPassword = 29
	dpbLcCtype  = 48

	tpbVersion3      = 3
	tpbConcurrency   = 2
	tpbWait          = 6
	tpbNowait        = 7
	tpbWrite         = 9
	tpbReadCommitted = 15
	tpbRecVersion    = 17

	sqlVaryingT = 448
	sqlLongT    = 496
	sqlBlobT    = 520
	sqlInt64T   = 580

	infoSQLRecords = 23
	infoEnd        = 1
)

var tpbDefault = []byte{tpbVersion3, tpbWrite, tpbReadCommitted, tpbRecVersion, tpbNowait}

func dpb(user, password string) []byte {
	b := []byte{dpbVersion1}
	for _, kv := range []struct {
		tag byte
		v   string
	}{{dpbUserName, user}, {dpbPassword, password}, {dpbLcCtype, "UTF8"}} {
		b = append(b, kv.tag, byte(len(kv.v)))
		b = append(b, kv.v...)
	}
	return b
}

type client struct {
	t     testing.TB
	url   string
	token string
	seq   uint32
	db    uint32
}

func op(code uint16, build func(w *protocol.Writer)) protocol.Op {
	w := &protocol.Writer{}
	if build != nil {
		build(w)
	}
	return protocol.Op{Code: code, Payload: w.B}
}

// post sends one request body with the given seq and returns the results.
func (c *client) post(seq uint32, ops ...protocol.Op) ([]protocol.Result, int) {
	body := protocol.EncodeRequest(protocol.Request{Version: protocol.Version, Seq: seq, Ops: ops})
	req, _ := http.NewRequest("POST", c.url+"/v1/rpc", bytes.NewReader(body))
	if c.token != "" {
		req.Header.Set("X-Session", c.token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		c.t.Fatalf("post: %v", err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return nil, resp.StatusCode
	}
	res, err := protocol.DecodeResponse(b)
	if err != nil {
		c.t.Fatalf("decode response: %v", err)
	}
	return res, resp.StatusCode
}

// call sends the next request and returns the results.
func (c *client) call(ops ...protocol.Op) []protocol.Result {
	c.seq++
	res, code := c.post(c.seq, ops...)
	if code != http.StatusOK {
		c.t.Fatalf("HTTP %d", code)
	}
	return res
}

// one sends one operation and returns its reader, or the error.
func (c *client) one(o protocol.Op) (*protocol.Reader, *protocol.Error) {
	res := c.call(o)
	if len(res) != 1 {
		c.t.Fatalf("got %d results", len(res))
	}
	return resultReader(c.t, res[0])
}

func resultReader(t testing.TB, r protocol.Result) (*protocol.Reader, *protocol.Error) {
	if r.Status != protocol.StatusOK {
		e, err := protocol.DecodeError(r.Payload)
		if err != nil {
			t.Fatalf("decode error: %v", err)
		}
		return nil, e
	}
	return &protocol.Reader{B: r.Payload}, nil
}

func (c *client) must(o protocol.Op) *protocol.Reader {
	c.t.Helper()
	r, e := c.one(o)
	if e != nil {
		c.t.Fatalf("op %d: %v (%+v)", o.Code, e, e)
	}
	return r
}

func attachClient(t testing.TB, url, db, user, password string) (*client, *protocol.Error) {
	c := &client{t: t, url: url}
	res, code := c.post(1, op(protocol.OpAttach, func(w *protocol.Writer) { w.Str(db); w.Bytes(dpb(user, password)) }))
	if code != http.StatusOK {
		t.Fatalf("attach HTTP %d", code)
	}
	r, e := resultReader(t, res[0])
	if e != nil {
		return nil, e
	}
	c.token, c.db, c.seq = r.Str(), r.U32(), 1
	return c, nil
}

func (c *client) startTr() uint32 {
	return c.must(op(protocol.OpStartTransaction, func(w *protocol.Writer) { w.U32(c.db); w.Bytes(tpbDefault); w.U32(0) })).U32()
}

func (c *client) trOp(code uint16, tr uint32) *protocol.Error {
	_, e := c.one(op(code, func(w *protocol.Writer) { w.U32(tr) }))
	return e
}

type prepared struct {
	stmt    uint32
	typ     int32
	out, in []protocol.Var
	info    []byte // sql_info for prepareInfoItems
}

// Item list the Devart driver asks after describe (docs/api-surface.md):
// select, describe_vars, sqlda_seq, relation_alias, describe_end.
var prepareInfoItems = []byte{4, 7, 9, 25, 8}

func (c *client) prepare(tr uint32, sql string) (prepared, *protocol.Error) {
	r, e := c.one(op(protocol.OpPrepare, func(w *protocol.Writer) {
		w.U32(c.db)
		w.U32(tr)
		w.U32(0)
		w.U16(3)
		w.Str(sql)
		w.Bytes(prepareInfoItems)
		w.U32(1024)
	}))
	if e != nil {
		return prepared{}, e
	}
	p := prepared{stmt: r.U32(), typ: r.I32(), out: protocol.ReadDesc(r), in: protocol.ReadDesc(r)}
	p.info = r.Bytes()
	return p, nil
}

func layoutOf(vars []protocol.Var) protocol.Layout {
	l := make(protocol.Layout, len(vars))
	for i, v := range vars {
		l[i] = protocol.Var{Type: v.Type, Scale: v.Scale, SubType: v.SubType, Len: v.Len}
	}
	return l
}

func executeOp(tr uint32, p prepared, inRow []protocol.Value, outL protocol.Layout, fetch uint32) protocol.Op {
	return executeOpExpected(tr, p, inRow, outL, fetch, nil, nil)
}

// executeOpExpected also sends the description the client expects (v2);
// expOut == nil and expIn == nil sends "no expected description".
func executeOpExpected(tr uint32, p prepared, inRow []protocol.Value, outL protocol.Layout, fetch uint32, expOut, expIn protocol.Layout) protocol.Op {
	return op(protocol.OpExecute, func(w *protocol.Writer) {
		w.U32(tr)
		w.U32(p.stmt)
		w.U16(3)
		if inRow == nil {
			protocol.WriteLayout(w, nil)
		} else {
			inL := layoutOf(p.in)
			protocol.WriteLayout(w, inL)
			protocol.WriteRow(w, inL, inRow)
		}
		protocol.WriteLayout(w, outL)
		w.U32(fetch)
		if expOut == nil && expIn == nil {
			w.U8(0)
			return
		}
		w.U8(1)
		protocol.WriteLayout(w, expOut)
		protocol.WriteLayout(w, expIn)
	})
}

// prepareOp builds a PREPARE with the given statement id (0 = allocate,
// >= 0x80000000 = client-chosen).
func prepareOp(db, tr, stmt uint32, sql string) protocol.Op {
	return op(protocol.OpPrepare, func(w *protocol.Writer) {
		w.U32(db)
		w.U32(tr)
		w.U32(stmt)
		w.U16(3)
		w.Str(sql)
		w.Bytes(prepareInfoItems)
		w.U32(1024)
	})
}

type batch struct {
	rows [][]protocol.Value
	eof  bool
}

func readBatch(r *protocol.Reader, l protocol.Layout) batch {
	n := int(r.U32())
	var b batch
	for i := 0; i < n; i++ {
		b.rows = append(b.rows, protocol.ReadRow(r, l))
	}
	b.eof = r.U8() == 1
	return b
}

// query prepares, opens and fetches every row with the given batch size.
// It returns the rows and the number of requests used after prepare.
func (c *client) query(tr uint32, sql string, inRow []protocol.Value, batchSize uint32) ([][]protocol.Value, int) {
	c.t.Helper()
	p, e := c.prepare(tr, sql)
	if e != nil {
		c.t.Fatalf("prepare: %v", e)
	}
	outL := layoutOf(p.out)
	r := c.must(executeOp(tr, p, inRow, outL, batchSize))
	if kind := r.U8(); kind != 2 {
		c.t.Fatalf("kind %d", kind)
	}
	r.Bytes() // records
	b := readBatch(r, outL)
	rows, requests := b.rows, 1
	for !b.eof {
		r := c.must(op(protocol.OpFetch, func(w *protocol.Writer) { w.U32(p.stmt); protocol.WriteLayout(w, nil); w.U32(batchSize) }))
		b = readBatch(r, outL)
		rows = append(rows, b.rows...)
		requests++
	}
	c.must(op(protocol.OpFree, func(w *protocol.Writer) { w.U32(p.stmt); w.U16(2) }))
	return rows, requests
}

// execSQL prepares and executes a statement without output and returns rows affected.
func (c *client) execSQL(tr uint32, sql string, inRow []protocol.Value) (int64, *protocol.Error) {
	p, e := c.prepare(tr, sql)
	if e != nil {
		return 0, e
	}
	defer c.one(op(protocol.OpFree, func(w *protocol.Writer) { w.U32(p.stmt); w.U16(2) }))
	r, e := c.one(executeOp(tr, p, inRow, nil, 0))
	if e != nil {
		return 0, e
	}
	if kind := r.U8(); kind != 0 {
		c.t.Fatalf("kind %d", kind)
	}
	return recordsAffected(r.Bytes()), nil
}

// recordsAffected sums insert/update/delete counts of an isc_info_sql_records block.
func recordsAffected(b []byte) int64 {
	// 23, len(2), then items: code(1) len(2) value(4) ... end(1)
	if len(b) < 3 || b[0] != infoSQLRecords {
		return -1
	}
	var total int64
	for i := 3; i+3 <= len(b) && b[i] != infoEnd; {
		n := int(b[i+1]) | int(b[i+2])<<8
		if b[i] != 16 /* isc_info_req_select_count */ && i+3+n <= len(b) {
			var v int64
			for j := n - 1; j >= 0; j-- {
				v = v<<8 | int64(b[i+3+j])
			}
			total += v
		}
		i += 3 + n
	}
	return total
}

func int32Value(v int32) protocol.Value {
	return protocol.Value{Data: []byte{byte(v), byte(v >> 8), byte(v >> 16), byte(v >> 24)}}
}

func valueInt32(v protocol.Value) int32 {
	d := v.Data
	return int32(uint32(d[0]) | uint32(d[1])<<8 | uint32(d[2])<<16 | uint32(d[3])<<24)
}
