package server

import (
	"encoding/binary"
	"fmt"

	"fbhttp/gateway/internal/fb"
	"fbhttp/gateway/internal/protocol"
)

const (
	dsqlDrop       = 2
	maxSegmentSize = 0xFFFF
	maxBlobChunk   = 4 << 20
)

const (
	fetchChunk     = 256 // rows per libfbclient fetch loop inside a batch
	sqlVaryingType = 448
)

func protoErr(cat uint8, format string, a ...any) *protocol.Error {
	return &protocol.Error{Category: cat, Messages: []string{fmt.Sprintf(format, a...)}}
}

// exec runs one operation of an attached session. Caller holds s.mu.
func (srv *Server) exec(s *Session, op protocol.Op) ([]byte, *protocol.Error) {
	r := &protocol.Reader{B: op.Payload}
	w := &protocol.Writer{}
	var e *protocol.Error
	switch op.Code {
	case protocol.OpDetach:
		db, e2 := s.get(r.U32(), kindDB)
		if e = e2; e == nil && r.Err == nil {
			if e = fb.Detach(&db.h); e == nil {
				s.closed = true
				s.handles = nil
			}
		}

	case protocol.OpDatabaseInfo:
		db, e2 := s.get(r.U32(), kindDB)
		items, buflen := r.Bytes(), r.U32()
		if e = e2; e == nil && r.Err == nil {
			var b []byte
			if b, e = fb.DatabaseInfo(db.h, items, buflen); e == nil {
				w.Bytes(b)
			}
		}

	case protocol.OpStartTransaction:
		db, e2 := s.get(r.U32(), kindDB)
		tpb := r.Bytes()
		want := r.U32() // 0 = gateway picks; else a client id with the high bit set
		if e = e2; e == nil && r.Err == nil {
			if want != 0 && (want < clientIDBase || s.handles[want] != nil) {
				return nil, protoErr(protocol.CatProtocol, "invalid client transaction id %d", want)
			}
			var tr fb.Handle
			if tr, e = fb.StartTransaction(db.h, tpb); e == nil {
				w.U32(s.addAs(want, &handle{kind: kindTr, h: tr}))
			}
		}

	case protocol.OpCommit, protocol.OpRollback, protocol.OpCommitRetaining, protocol.OpRollbackRetain:
		id := r.U32()
		tr, e2 := s.get(id, kindTr)
		if e = e2; e == nil && r.Err == nil {
			switch op.Code {
			case protocol.OpCommit:
				e = fb.Commit(&tr.h)
			case protocol.OpRollback:
				e = fb.Rollback(&tr.h)
			case protocol.OpCommitRetaining:
				e = fb.CommitRetaining(&tr.h)
			default:
				e = fb.RollbackRetaining(&tr.h)
			}
			if e == nil && tr.h == 0 {
				delete(s.handles, id)
			}
		}

	case protocol.OpTransactionInfo:
		tr, e2 := s.get(r.U32(), kindTr)
		items, buflen := r.Bytes(), r.U32()
		if e = e2; e == nil && r.Err == nil {
			var b []byte
			if b, e = fb.TransactionInfo(tr.h, items, buflen); e == nil {
				w.Bytes(b)
			}
		}

	case protocol.OpPrepare:
		e = srv.prepare(s, r, w)

	case protocol.OpFree:
		id := r.U32()
		st, e2 := s.get(id, kindStmt)
		option := r.U16()
		if e = e2; e == nil && r.Err == nil {
			if e = st.stmt.Free(option); e == nil && option == dsqlDrop {
				delete(s.handles, id)
			}
		}

	case protocol.OpExecute:
		e = srv.execute(s, r, w)

	case protocol.OpExecuteImmediate:
		e = srv.executeImmediate(s, r, w)

	case protocol.OpFetch:
		st, e2 := s.get(r.U32(), kindStmt)
		outL := protocol.ReadLayout(r)
		n := int(r.U32())
		if e = e2; e == nil && r.Err == nil {
			if outL != nil {
				st.out = outL
				st.stmt.SetOutLayout(outL)
			}
			e = srv.fetch(st, n, w)
		}

	case protocol.OpSetCursorName:
		st, e2 := s.get(r.U32(), kindStmt)
		name := r.Str()
		if e = e2; e == nil && r.Err == nil {
			e = st.stmt.SetCursorName(name)
		}

	case protocol.OpSQLInfo:
		st, e2 := s.get(r.U32(), kindStmt)
		items, buflen := r.Bytes(), r.U32()
		if e = e2; e == nil && r.Err == nil {
			var b []byte
			if b, e = st.stmt.SQLInfo(items, buflen); e == nil {
				w.Bytes(b)
			}
		}

	case protocol.OpOpenBlob:
		e = srv.openBlob(s, r, w)

	case protocol.OpGetSegments:
		b, e2 := s.get(r.U32(), kindBlob)
		max := int(r.U32())
		if e = e2; e == nil && r.Err == nil {
			data, eof, e3 := fb.ReadBlob(b.h, min(max, maxBlobChunk))
			if e = e3; e == nil {
				w.Bytes(data)
				w.U8(b2u8(eof))
			}
		}

	case protocol.OpCreateBlob:
		db, e2 := s.get(r.U32(), kindDB)
		tr, e3 := s.get(r.U32(), kindTr)
		bpb := r.Bytes()
		if e = firstErr(e2, e3); e == nil && r.Err == nil {
			h, q, e4 := fb.CreateBlob(db.h, tr.h, bpb)
			if e = e4; e == nil {
				w.U32(s.add(&handle{kind: kindBlob, h: h}))
				w.Raw(q[:])
			}
		}

	case protocol.OpPutSegments:
		b, e2 := s.get(r.U32(), kindBlob)
		n := int(r.U32())
		for i := 0; i < n && e2 == nil && e == nil && r.Err == nil; i++ {
			seg := r.Bytes()
			for len(seg) > 0 && e == nil && r.Err == nil {
				part := seg[:min(len(seg), maxSegmentSize)]
				seg = seg[len(part):]
				e = fb.PutSegment(b.h, part)
			}
		}
		e = firstErr(e2, e)

	case protocol.OpCloseBlob, protocol.OpCancelBlob:
		id := r.U32()
		b, e2 := s.get(id, kindBlob)
		if e = e2; e == nil && r.Err == nil {
			if op.Code == protocol.OpCloseBlob {
				e = fb.CloseBlob(&b.h)
			} else {
				e = fb.CancelBlob(&b.h)
			}
			if e == nil {
				delete(s.handles, id)
			}
		}

	case protocol.OpBlobInfo:
		b, e2 := s.get(r.U32(), kindBlob)
		items, buflen := r.Bytes(), r.U32()
		if e = e2; e == nil && r.Err == nil {
			var res []byte
			if res, e = fb.BlobInfo(b.h, items, buflen); e == nil {
				w.Bytes(res)
			}
		}

	default:
		return nil, protoErr(protocol.CatProtocol, "unknown opcode %d", op.Code)
	}
	if e != nil {
		return nil, e
	}
	if r.Err != nil || len(r.B) != 0 {
		return nil, protoErr(protocol.CatProtocol, "malformed payload for opcode %d", op.Code)
	}
	return w.B, nil
}

func firstErr(es ...*protocol.Error) *protocol.Error {
	for _, e := range es {
		if e != nil {
			return e
		}
	}
	return nil
}

func b2u8(b bool) uint8 {
	if b {
		return 1
	}
	return 0
}

// optTr resolves a transaction id where 0 means "no transaction".
func optTr(s *Session, id uint32) (*handle, *protocol.Error) {
	if id == 0 {
		return &handle{kind: kindTr}, nil
	}
	return s.get(id, kindTr)
}

func (srv *Server) prepare(s *Session, r *protocol.Reader, w *protocol.Writer) *protocol.Error {
	db, e1 := s.get(r.U32(), kindDB)
	tr, e2 := optTr(s, r.U32())
	stmtID := r.U32()
	dialect := r.U16()
	sql := r.Str()
	infoItems, infoLen := r.Bytes(), r.U32()
	if r.Err != nil {
		return nil // reported as malformed by exec
	}
	if e := firstErr(e1, e2); e != nil {
		return e
	}
	// stmtID: 0 = allocate; >= clientIDBase = allocate under the client's id
	// (so the batch can EXECUTE it); otherwise re-prepare an existing one.
	fresh := stmtID == 0 || stmtID >= clientIDBase
	var st *handle
	if fresh {
		if stmtID != 0 && s.handles[stmtID] != nil {
			return protoErr(protocol.CatProtocol, "invalid client statement id %d", stmtID)
		}
		stmt, e := fb.Allocate(db.h)
		if e != nil {
			return e
		}
		st = &handle{kind: kindStmt, stmt: stmt}
	} else {
		var e *protocol.Error
		if st, e = s.get(stmtID, kindStmt); e != nil {
			return e
		}
	}
	out, in, e := st.stmt.Prepare(tr.h, dialect, sql)
	if e != nil {
		if fresh {
			st.stmt.Free(dsqlDrop) // the client never saw this statement
		}
		return e
	}
	var info []byte
	if len(infoItems) > 0 {
		if info, e = st.stmt.SQLInfo(infoItems, infoLen); e != nil {
			if fresh {
				st.stmt.Free(dsqlDrop)
			}
			return e
		}
	}
	if fresh {
		stmtID = s.addAs(stmtID, st)
	}
	st.outDesc, st.inDesc = typesOf(out), typesOf(in)
	st.out = nil
	st.sql = sql
	if srv.debugSQL {
		srv.log.Info("debug prepare", "session", s.ID, "stmt", stmtID, "type", st.stmt.Type, "sql", sql, "out", descTypes(out), "in", descTypes(in))
	}
	w.U32(stmtID)
	w.I32(st.stmt.Type)
	protocol.WriteDesc(w, out)
	protocol.WriteDesc(w, in)
	w.Bytes(info)
	return nil
}

// typesOf keeps the type part of a description.
func typesOf(vars []protocol.Var) protocol.Layout {
	l := make(protocol.Layout, len(vars))
	for i, v := range vars {
		l[i] = protocol.Var{Type: v.Type, Scale: v.Scale, SubType: v.SubType, Len: v.Len}
	}
	return l
}

func sameTypes(a, b protocol.Layout) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i].Type != b[i].Type || a[i].Scale != b[i].Scale || a[i].SubType != b[i].SubType || a[i].Len != b[i].Len {
			return false
		}
	}
	return true
}

// Message the client matches to drop its cached description.
const errDescriptionChanged = "fbhttp: statement description changed"

func readInput(r *protocol.Reader) (protocol.Layout, []protocol.Value) {
	l := protocol.ReadLayout(r)
	if l == nil {
		return nil, nil
	}
	return l, protocol.ReadRow(r, l)
}

func (srv *Server) execute(s *Session, r *protocol.Reader, w *protocol.Writer) *protocol.Error {
	tr, e1 := optTr(s, r.U32())
	st, e2 := s.get(r.U32(), kindStmt)
	dialect := r.U16()
	inL, inRow := readInput(r)
	outL := protocol.ReadLayout(r)
	fetch := int(r.U32())
	// Description the client answered to the driver from its cache, when the
	// PREPARE came in this batch. A mismatch (DDL since) must not execute.
	hasExpected := r.U8() == 1
	var expOut, expIn protocol.Layout
	if hasExpected {
		expOut, expIn = protocol.ReadLayout(r), protocol.ReadLayout(r)
	}
	if r.Err != nil {
		return nil
	}
	if e := firstErr(e1, e2); e != nil {
		return e
	}
	if hasExpected && !(sameTypes(expOut, st.outDesc) && sameTypes(expIn, st.inDesc)) {
		return protoErr(protocol.CatProtocol, "%s", errDescriptionChanged)
	}

	if st.stmt.IsCursor() && !(fetch == 0 && outL != nil) {
		if e := st.stmt.Open(&tr.h, dialect, inL, inRow, outL); e != nil {
			return e
		}
		st.out = outL
		records, e := st.stmt.RecordsInfo() // before fetching, as the native client sees it
		if e != nil {
			return e
		}
		w.U8(2)
		w.Bytes(records)
		return srv.fetch(st, fetch, w)
	}

	row, e := st.stmt.Execute(&tr.h, dialect, inL, inRow, outL)
	if e != nil {
		return e
	}
	records, e := st.stmt.RecordsInfo()
	if e != nil {
		return e
	}
	if outL == nil {
		w.U8(0)
	} else {
		w.U8(1)
		w.U8(b2u8(row != nil))
		if row != nil {
			protocol.WriteRow(w, outL, row)
		}
	}
	w.Bytes(records)
	return nil
}

// maxRowBytes is the largest encoded size of one row of l.
func maxRowBytes(l protocol.Layout) int {
	n := 0
	for _, v := range l {
		n += 1 + int(uint16(v.Len))
		if v.Type&^1 == sqlVaryingType {
			n += 2
		}
	}
	return max(n, 1)
}

// fetch writes a batch of up to n rows, stopping early when the encoded
// rows reach max_batch_bytes (at least one row). Rows come from libfbclient
// in chunks sized so the limit is not crossed by more than one row.
func (srv *Server) fetch(st *handle, n int, w *protocol.Writer) *protocol.Error {
	n = min(n, srv.cfg.MaxFetchRows)
	if st.stmt.Type == fb.StmtSelectForUpd {
		n = min(n, 1) // keep WHERE CURRENT OF on the row the client sees
	}
	limit := srv.cfg.MaxBatchBytes
	if limit <= 0 {
		limit = 4 << 20
	}
	rowMax := maxRowBytes(st.out)
	countAt := len(w.B)
	w.U32(0) // row count, patched below
	start := len(w.B)
	count, eof := 0, false
	for count < n && !eof {
		// Rows that still fit (by their largest encoding). A batch never
		// crosses the limit except with its first row.
		room := (limit - (len(w.B) - start)) / rowMax
		if room <= 0 {
			if count > 0 {
				break
			}
			room = 1
		}
		rows, chunkEOF, e := st.stmt.Fetch(min(n-count, fetchChunk, room))
		if e != nil {
			return e
		}
		if srv.debugSQL && count == 0 && len(rows) > 0 {
			srv.log.Info("debug rows", "sql", st.sql, "layout", descTypes(st.out), "first", rowHex(rows[0]))
		}
		for _, row := range rows {
			protocol.WriteRow(w, st.out, row)
		}
		count += len(rows)
		eof = chunkEOF
	}
	binary.LittleEndian.PutUint32(w.B[countAt:], uint32(count))
	w.U8(b2u8(eof))
	return nil
}

func (srv *Server) executeImmediate(s *Session, r *protocol.Reader, w *protocol.Writer) *protocol.Error {
	db, e1 := s.get(r.U32(), kindDB)
	trID := r.U32()
	tr, e2 := optTr(s, trID)
	dialect := r.U16()
	sql := r.Str()
	inL, inRow := readInput(r)
	outL := protocol.ReadLayout(r)
	if r.Err != nil {
		return nil
	}
	if e := firstErr(e1, e2); e != nil {
		return e
	}
	h := tr.h
	row, e := fb.ExecImmediate(db.h, &h, dialect, sql, inL, inRow, outL)
	// The transaction handle can change even when the statement fails.
	switch {
	case trID != 0 && h == 0:
		delete(s.handles, trID)
		trID = 0
	case trID != 0:
		tr.h = h
	case h != 0:
		trID = s.add(&handle{kind: kindTr, h: h})
	}
	if e != nil {
		return e
	}
	w.U32(trID)
	w.U8(b2u8(row != nil))
	if row != nil {
		protocol.WriteRow(w, outL, row)
	}
	return nil
}

func (srv *Server) openBlob(s *Session, r *protocol.Reader, w *protocol.Writer) *protocol.Error {
	db, e1 := s.get(r.U32(), kindDB)
	tr, e2 := s.get(r.U32(), kindTr)
	var q fb.Quad
	copy(q[:], r.Raw(8))
	bpb := r.Bytes()
	limit := min(int(r.U32()), srv.cfg.MaxInlineBlob)
	if r.Err != nil {
		return nil
	}
	if e := firstErr(e1, e2); e != nil {
		return e
	}
	h, e := fb.OpenBlob(db.h, tr.h, q, bpb)
	if e != nil {
		return e
	}
	info, e := fb.BlobInfo(h, fb.BlobInfoItems, 64)
	if e != nil {
		fb.CancelBlob(&h)
		return e
	}
	if total := fb.BlobTotalLength(info); total <= int64(limit) {
		data, _, e := fb.ReadBlob(h, int(total)+1)
		fb.CloseBlob(&h)
		if e != nil {
			return e
		}
		w.U32(0)
		w.Bytes(info)
		w.U8(1)
		w.Bytes(data)
		return nil
	}
	w.U32(s.add(&handle{kind: kindBlob, h: h}))
	w.Bytes(info)
	w.U8(0)
	w.Bytes(nil)
	return nil
}

func descTypes(vars []protocol.Var) string {
	out := ""
	for i, v := range vars {
		out += fmt.Sprintf("[%d:%d/%d/%d/%d %s]", i, v.Type, v.SubType, v.Scale, v.Len, v.AliasName)
	}
	return out
}

func rowHex(row []protocol.Value) string {
	out := ""
	for i, v := range row {
		if v.Null {
			out += fmt.Sprintf("[%d:NULL]", i)
		} else {
			out += fmt.Sprintf("[%d:%x]", i, v.Data)
		}
	}
	return out
}
