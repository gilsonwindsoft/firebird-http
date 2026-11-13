package server

// Integration tests against a real Firebird (see docker-compose.test.yml).
// They are skipped when FBHTTP_TEST_DB is not set.

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"fbhttp/gateway/internal/config"
	"fbhttp/gateway/internal/fb"
	"fbhttp/gateway/internal/protocol"
)

var (
	testDB, testUser, testPassword string
)

const rowCount = 10000

func TestMain(m *testing.M) {
	testDB, testUser, testPassword = os.Getenv("FBHTTP_TEST_DB"), os.Getenv("FBHTTP_TEST_USER"), os.Getenv("FBHTTP_TEST_PASSWORD")
	if testDB == "" {
		fmt.Println("FBHTTP_TEST_DB not set: skipping Firebird integration tests")
		os.Exit(0)
	}
	if err := setupSchema(); err != nil {
		fmt.Println("schema setup:", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}

// setupSchema creates the test tables directly through libfbclient.
// It retries the attach while the Firebird container starts.
func setupSchema() error {
	var db fb.Handle
	var e *protocol.Error
	for i := 0; i < 60; i++ {
		if db, e = fb.Attach(testDB, dpb(testUser, testPassword)); e == nil {
			break
		}
		time.Sleep(time.Second)
	}
	if e != nil {
		return e
	}
	defer fb.Detach(&db)
	ddl := []string{
		"RECREATE TABLE T_ROWS (ID INTEGER NOT NULL PRIMARY KEY, NAME VARCHAR(50), AMOUNT NUMERIC(18,4), CREATED TIMESTAMP, FLAG BOOLEAN, NOTE BLOB SUB_TYPE TEXT)",
		"RECREATE TABLE T_KV (ID INTEGER NOT NULL PRIMARY KEY, V VARCHAR(20))",
		"RECREATE TABLE T_BLOB (ID INTEGER NOT NULL PRIMARY KEY, B BLOB SUB_TYPE BINARY)",
		"CREATE OR ALTER PROCEDURE P_ADD (A INTEGER, B INTEGER) RETURNS (C INTEGER) AS BEGIN C = A + B; END",
	}
	for _, sql := range ddl {
		tr, e := fb.StartTransaction(db, tpbDefault)
		if e != nil {
			return e
		}
		if _, e := fb.ExecImmediate(db, &tr, 3, sql, nil, nil, nil); e != nil {
			fb.Rollback(&tr)
			return fmt.Errorf("%s: %w", sql, e)
		}
		if e := fb.Commit(&tr); e != nil {
			return errOf(e)
		}
	}
	tr, e := fb.StartTransaction(db, tpbDefault)
	if e != nil {
		return e
	}
	fill := fmt.Sprintf(`EXECUTE BLOCK AS DECLARE I INTEGER = 1; BEGIN
		WHILE (I <= %d) DO BEGIN
			INSERT INTO T_ROWS VALUES (:I, 'name ' || :I, :I * 1.2345, DATEADD(:I SECOND TO TIMESTAMP '2026-01-01 00:00:00'),
				MOD(:I, 2) = 0, IIF(MOD(:I, 7) = 0, NULL, 'note ' || :I));
			I = I + 1;
		END
		INSERT INTO T_ROWS (ID, NAME, AMOUNT) VALUES (-1, '', 12345678901234.5678);
	END`, rowCount)
	if _, e := fb.ExecImmediate(db, &tr, 3, fill, nil, nil, nil); e != nil {
		fb.Rollback(&tr)
		return e
	}
	return errOf(fb.Commit(&tr))
}

// errOf avoids returning a typed nil *protocol.Error as a non-nil error.
func errOf(e *protocol.Error) error {
	if e == nil {
		return nil
	}
	return e
}

type env struct {
	srv  *Server
	http *httptest.Server
	logs *syncBuffer
}

type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

func newEnv(t *testing.T, tune func(*config.Config)) *env {
	cfg := &config.Config{
		PlainHTTP: true, Aliases: map[string]string{"test": testDB},
		MaxSessions: 50, MaxSessionsPerIP: 50, MaxBodyBytes: 64 << 20, MaxFetchRows: 5000,
		MaxInlineBlob: 64 << 10, IdleTimeoutSec: 1800,
	}
	if tune != nil {
		tune(cfg)
	}
	logs := &syncBuffer{}
	srv := New(cfg, slog.New(slog.NewJSONHandler(logs, nil)))
	hs := httptest.NewServer(srv.Handler())
	t.Cleanup(func() { hs.Close(); srv.CloseAll() })
	return &env{srv: srv, http: hs, logs: logs}
}

func (e *env) attach(t *testing.T) *client {
	c, err := attachClient(t, e.http.URL, "test", testUser, testPassword)
	if err != nil {
		t.Fatalf("attach: %v", err)
	}
	return c
}

func TestAttachDetach(t *testing.T) {
	e := newEnv(t, nil)
	c := e.attach(t)
	tr := c.startTr()
	rows, _ := c.query(tr, "SELECT 1 FROM RDB$DATABASE", nil, 10)
	if len(rows) != 1 || valueInt32(rows[0][0]) != 1 {
		t.Fatalf("rows %+v", rows)
	}
	// Like the native client, detach refuses open transactions.
	if _, err := c.one(op(protocol.OpDetach, func(w *protocol.Writer) { w.U32(c.db) })); err == nil {
		t.Fatal("detach with open transaction succeeded")
	}
	c.trOp(protocol.OpCommit, tr)
	c.must(op(protocol.OpDetach, func(w *protocol.Writer) { w.U32(c.db) }))
	if n := e.srv.SessionCount(); n != 0 {
		t.Fatalf("sessions %d", n)
	}
}

func TestAttachWithServerPrefix(t *testing.T) {
	e := newEnv(t, nil)
	if _, err := attachClient(t, e.http.URL, "myserver/3050:test", testUser, testPassword); err != nil {
		t.Fatal(err)
	}
}

func TestAliasNotPublished(t *testing.T) {
	e := newEnv(t, nil)
	for _, db := range []string{"other", testDB, "/var/lib/firebird/data/test.fdb"} {
		_, err := attachClient(t, e.http.URL, db, testUser, testPassword)
		if err == nil || err.Category != protocol.CatSession {
			t.Fatalf("%s: got %v", db, err)
		}
	}
	if !strings.Contains(e.logs.String(), "database not allowed") {
		t.Fatal("refusal not logged")
	}
}

// With firebird_host, the database part the client sends is opened on that
// host; the client's host is ignored and a second host is refused.
func TestAttachFirebirdHost(t *testing.T) {
	host, path, _ := strings.Cut(testDB, ":")
	e := newEnv(t, func(c *config.Config) { c.Aliases = nil; c.FirebirdHost = host })
	if _, err := attachClient(t, e.http.URL, "localhost:"+path, testUser, testPassword); err != nil {
		t.Fatal(err)
	}
	if _, err := attachClient(t, e.http.URL, "x:evil:"+path, testUser, testPassword); err == nil || err.Category != protocol.CatSession {
		t.Fatalf("second host: got %v", err)
	}
}

func TestWrongPassword(t *testing.T) {
	e := newEnv(t, nil)
	_, err := attachClient(t, e.http.URL, "test", testUser, "wrong-password")
	if err == nil || err.Category != protocol.CatFirebird || len(err.Messages) == 0 {
		t.Fatalf("got %+v", err)
	}
	if e.srv.SessionCount() != 0 {
		t.Fatal("session created")
	}
}

func TestInvalidToken(t *testing.T) {
	e := newEnv(t, nil)
	c := &client{t: t, url: e.http.URL, token: "deadbeef", seq: 1}
	_, err := c.one(op(protocol.OpStartTransaction, func(w *protocol.Writer) { w.U32(1); w.Bytes(tpbDefault); w.U32(0) }))
	if err == nil || err.Category != protocol.CatSession {
		t.Fatalf("got %v", err)
	}
}

func TestVersionMismatch(t *testing.T) {
	e := newEnv(t, nil)
	body := protocol.EncodeRequest(protocol.Request{Version: 99, Seq: 1, Ops: []protocol.Op{{Code: protocol.OpAttach}}})
	resp, err := http.Post(e.http.URL+"/v1/rpc", contentType, bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var buf bytes.Buffer
	buf.ReadFrom(resp.Body)
	res, _ := protocol.DecodeResponse(buf.Bytes())
	_, perr := resultReader(t, res[0])
	if perr == nil || perr.Category != protocol.CatProtocol || !strings.Contains(perr.Messages[0], "supported versions: 1") {
		t.Fatalf("got %+v", perr)
	}
}

func TestBodyLimit(t *testing.T) {
	e := newEnv(t, func(c *config.Config) { c.MaxBodyBytes = 1024 })
	c := &client{t: t, url: e.http.URL}
	_, code := c.post(1, op(protocol.OpAttach, func(w *protocol.Writer) { w.Raw(make([]byte, 4096)) }))
	if code != http.StatusRequestEntityTooLarge {
		t.Fatalf("HTTP %d", code)
	}
}

func TestPrepareDescriptionMatchesNative(t *testing.T) {
	e := newEnv(t, nil)
	c := e.attach(t)
	tr := c.startTr()
	const sql = "SELECT ID, NAME, AMOUNT, CREATED, FLAG, NOTE FROM T_ROWS WHERE ID = ? AND NAME <> ?"
	p, err := c.prepare(tr, sql)
	if err != nil {
		t.Fatal(err)
	}

	db, _ := fb.Attach(testDB, dpb(testUser, testPassword))
	defer fb.Detach(&db)
	ntr, _ := fb.StartTransaction(db, tpbDefault)
	defer fb.Rollback(&ntr)
	st, _ := fb.Allocate(db)
	out, in, ferr := st.Prepare(ntr, 3, sql)
	if ferr != nil {
		t.Fatal(ferr)
	}
	if !reflect.DeepEqual(p.out, out) || !reflect.DeepEqual(p.in, in) || p.typ != st.Type || p.typ != fb.StmtSelect {
		t.Fatalf("gateway %+v\nnative out %+v in %+v", p, out, in)
	}
}

func TestFetchTenThousandRowsMatchesNative(t *testing.T) {
	e := newEnv(t, nil)
	c := e.attach(t)
	const sql = "SELECT ID, NAME, AMOUNT, CREATED, FLAG, NOTE FROM T_ROWS WHERE ID > ? ORDER BY ID"
	rows, requests := c.query(c.startTr(), sql, []protocol.Value{int32Value(0)}, 500)
	if len(rows) != rowCount || requests > 21 {
		t.Fatalf("rows %d requests %d", len(rows), requests)
	}

	db, _ := fb.Attach(testDB, dpb(testUser, testPassword))
	defer fb.Detach(&db)
	tr, _ := fb.StartTransaction(db, tpbDefault)
	defer fb.Rollback(&tr)
	st, _ := fb.Allocate(db)
	out, in, ferr := st.Prepare(tr, 3, sql)
	if ferr != nil {
		t.Fatal(ferr)
	}
	if ferr := st.Open(&tr, 3, layoutOf(in), []protocol.Value{int32Value(0)}, layoutOf(out)); ferr != nil {
		t.Fatal(ferr)
	}
	native, _, ferr := st.Fetch(rowCount + 1)
	if ferr != nil {
		t.Fatal(ferr)
	}
	if !reflect.DeepEqual(rows, native) {
		t.Fatal("gateway rows differ from native rows")
	}
	// NULL versus empty VARCHAR.
	if !rows[6][5].Null || rows[0][5].Null {
		t.Fatal("NULL blob mismatch")
	}
}

func TestDecimalAndEmptyString(t *testing.T) {
	e := newEnv(t, nil)
	c := e.attach(t)
	rows, _ := c.query(c.startTr(), "SELECT NAME, AMOUNT, CAST(-0.0001 AS NUMERIC(18,4)) FROM T_ROWS WHERE ID = -1", nil, 10)
	r := rows[0]
	if r[0].Null || len(r[0].Data) != 0 {
		t.Fatalf("empty string: %+v", r[0])
	}
	le := func(d []byte) int64 {
		var v int64
		for i := 7; i >= 0; i-- {
			v = v<<8 | int64(d[i])
		}
		return v
	}
	if le(r[1].Data) != 123456789012345678 || le(r[2].Data) != -1 {
		t.Fatalf("decimals %d %d", le(r[1].Data), le(r[2].Data))
	}
}

func TestTransactionAcrossRequestsAndRollback(t *testing.T) {
	e := newEnv(t, nil)
	c := e.attach(t)
	tr := c.startTr()
	if n, err := c.execSQL(tr, "INSERT INTO T_KV VALUES (?, 'rollback')", []protocol.Value{int32Value(1001)}); err != nil || n != 1 {
		t.Fatalf("insert: %d %v", n, err)
	}
	if err := c.trOp(protocol.OpRollback, tr); err != nil {
		t.Fatal(err)
	}
	tr = c.startTr()
	if n, err := c.execSQL(tr, "INSERT INTO T_KV VALUES (?, 'commit')", []protocol.Value{int32Value(1002)}); err != nil || n != 1 {
		t.Fatalf("insert: %d %v", n, err)
	}
	if err := c.trOp(protocol.OpCommit, tr); err != nil {
		t.Fatal(err)
	}
	rows, _ := c.query(c.startTr(), "SELECT ID FROM T_KV WHERE ID IN (1001, 1002)", nil, 10)
	if len(rows) != 1 || valueInt32(rows[0][0]) != 1002 {
		t.Fatalf("rows %+v", rows)
	}
	if err := c.trOp(protocol.OpCommit, tr); err == nil || err.Status[0].Num != fb.ErrBadTransHandle {
		t.Fatalf("commit of finished transaction: %+v", err)
	}
}

func TestTwoTransactionsOneSession(t *testing.T) {
	e := newEnv(t, nil)
	c := e.attach(t)
	t1, t2 := c.startTr(), c.startTr()
	if _, err := c.execSQL(t1, "UPDATE OR INSERT INTO T_KV VALUES (2001, 'a')", nil); err != nil {
		t.Fatal(err)
	}
	rows, _ := c.query(t2, "SELECT ID FROM T_KV WHERE ID = 2001", nil, 10)
	if len(rows) != 0 {
		t.Fatal("uncommitted row visible to second transaction")
	}
	c.trOp(protocol.OpRollback, t1)
	c.trOp(protocol.OpRollback, t2)
}

func TestSessionIsolation(t *testing.T) {
	e := newEnv(t, nil)
	a, b := e.attach(t), e.attach(t)
	ta := a.startTr()
	if _, err := a.execSQL(ta, "UPDATE OR INSERT INTO T_KV VALUES (3001, 'a')", nil); err != nil {
		t.Fatal(err)
	}
	rows, _ := b.query(b.startTr(), "SELECT ID FROM T_KV WHERE ID = 3001", nil, 10)
	if len(rows) != 0 {
		t.Fatal("uncommitted row visible to other session")
	}
	a.trOp(protocol.OpRollback, ta)
}

func TestPrimaryKeyViolationKeepsSession(t *testing.T) {
	e := newEnv(t, nil)
	c := e.attach(t)
	tr := c.startTr()
	c.execSQL(tr, "UPDATE OR INSERT INTO T_KV VALUES (4001, 'x')", nil)
	_, err := c.execSQL(tr, "INSERT INTO T_KV VALUES (4001, 'dup')", nil)
	if err == nil || err.Category != protocol.CatFirebird || err.SQLCode != -803 || len(err.Messages) == 0 {
		t.Fatalf("got %+v", err)
	}
	if rows, _ := c.query(tr, "SELECT 1 FROM RDB$DATABASE", nil, 1); len(rows) != 1 {
		t.Fatal("session not usable after error")
	}
	c.trOp(protocol.OpRollback, tr)
}

func TestInvalidStatementHandle(t *testing.T) {
	e := newEnv(t, nil)
	c := e.attach(t)
	_, err := c.one(op(protocol.OpFetch, func(w *protocol.Writer) { w.U32(999); protocol.WriteLayout(w, nil); w.U32(1) }))
	if err == nil || err.Status[0].Num != fb.ErrBadStmtHandle || len(err.Messages) == 0 {
		t.Fatalf("got %+v", err)
	}
}

func TestRetryInsertExecutesOnce(t *testing.T) {
	e := newEnv(t, nil)
	c := e.attach(t)
	tr := c.startTr()
	c.execSQL(tr, "DELETE FROM T_KV WHERE ID = 5001", nil)
	p, _ := c.prepare(tr, "INSERT INTO T_KV VALUES (5001, 'once')")
	c.seq++
	first, _ := c.post(c.seq, executeOp(tr, p, nil, nil, 0))
	again, _ := c.post(c.seq, executeOp(tr, p, nil, nil, 0)) // response "lost", same seq
	if !reflect.DeepEqual(first, again) || first[0].Status != protocol.StatusOK {
		t.Fatalf("retry returned a different response: %+v %+v", first, again)
	}
	rows, _ := c.query(tr, "SELECT COUNT(*) FROM T_KV WHERE ID = 5001", nil, 1)
	if n := rows[0][0].Data[0]; n != 1 {
		t.Fatalf("count %d", n)
	}
	if res, _ := c.post(c.seq+5, executeOp(tr, p, nil, nil, 0)); res[0].Status != protocol.StatusError {
		t.Fatal("out of order seq accepted")
	}
	c.trOp(protocol.OpRollback, tr)
}

const slowSQL = `EXECUTE BLOCK RETURNS (N INTEGER) AS DECLARE I INTEGER = 0; BEGIN
	WHILE (I < 3000000) DO I = I + 1; N = I; SUSPEND; END`

func TestRetryAndPingDuringSlowQuery(t *testing.T) {
	e := newEnv(t, nil)
	c := e.attach(t)
	tr := c.startTr()
	p, perr := c.prepare(tr, slowSQL)
	if perr != nil {
		t.Fatal(perr)
	}
	c.seq++
	seq := c.seq
	var wg sync.WaitGroup
	results := make([][]protocol.Result, 2)
	start := time.Now()
	for i := range results {
		wg.Add(1)
		go func() {
			defer wg.Done()
			results[i], _ = c.post(seq, executeOp(tr, p, nil, layoutOf(p.out), 10))
		}()
		time.Sleep(200 * time.Millisecond) // second request is a retry while the first runs
	}
	// Keep-alive must answer immediately while the session is busy.
	pingStart := time.Now()
	req, _ := http.NewRequest("POST", e.http.URL+"/v1/ping", nil)
	req.Header.Set("X-Session", c.token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil || resp.StatusCode != http.StatusNoContent || time.Since(pingStart) > 500*time.Millisecond {
		t.Fatalf("ping: %v %v %v", err, resp, time.Since(pingStart))
	}
	wg.Wait()
	if time.Since(start) < 300*time.Millisecond {
		t.Skip("query too fast to test the overlap")
	}
	if !reflect.DeepEqual(results[0], results[1]) || results[0][0].Status != protocol.StatusOK {
		t.Fatal("retry during execution returned a different response")
	}
	if strings.Count(e.logs.String(), fmt.Sprintf(`"seq":%d`, seq)) != 2 {
		t.Log(e.logs.String())
	}
}

func TestIdleSessionRollsBack(t *testing.T) {
	e := newEnv(t, func(c *config.Config) { c.IdleTimeoutSec = 1 })
	c := e.attach(t)
	tr := c.startTr()
	if _, err := c.execSQL(tr, "UPDATE OR INSERT INTO T_KV VALUES (6001, 'idle')", nil); err != nil {
		t.Fatal(err)
	}
	e.srv.Reap(time.Now().Add(2 * time.Second))
	if e.srv.SessionCount() != 0 {
		t.Fatal("session not reaped")
	}
	if _, err := c.one(op(protocol.OpCommit, func(w *protocol.Writer) { w.U32(tr) })); err == nil || err.Category != protocol.CatSession {
		t.Fatalf("got %v", err)
	}
	other := e.attach(t)
	if rows, _ := other.query(other.startTr(), "SELECT 1 FROM T_KV WHERE ID = 6001", nil, 1); len(rows) != 0 {
		t.Fatal("reaped transaction was committed")
	}
}

func TestSessionLimits(t *testing.T) {
	e := newEnv(t, func(c *config.Config) { c.MaxSessions = 2 })
	a := e.attach(t)
	e.attach(t)
	_, err := attachClient(t, e.http.URL, "test", testUser, testPassword)
	if err == nil || err.Category != protocol.CatLimit {
		t.Fatalf("got %v", err)
	}
	if rows, _ := a.query(a.startTr(), "SELECT 1 FROM RDB$DATABASE", nil, 1); len(rows) != 1 {
		t.Fatal("existing session broken")
	}

	e2 := newEnv(t, func(c *config.Config) { c.MaxSessionsPerIP = 1 })
	e2.attach(t)
	if _, err := attachClient(t, e2.http.URL, "test", testUser, testPassword); err == nil || err.Category != protocol.CatLimit {
		t.Fatalf("per ip: got %v", err)
	}
}

func TestCloseAllRollsBack(t *testing.T) {
	e := newEnv(t, nil)
	c := e.attach(t)
	tr := c.startTr()
	c.execSQL(tr, "UPDATE OR INSERT INTO T_KV VALUES (7001, 'shutdown')", nil)
	e.srv.CloseAll()
	if e.srv.SessionCount() != 0 {
		t.Fatal("sessions left")
	}
	if !strings.Contains(e.logs.String(), `"reason":"shutdown"`) {
		t.Fatal("shutdown not logged")
	}
	e2 := newEnv(t, nil)
	o := e2.attach(t)
	if rows, _ := o.query(o.startTr(), "SELECT 1 FROM T_KV WHERE ID = 7001", nil, 1); len(rows) != 0 {
		t.Fatal("transaction committed on shutdown")
	}
	if _, err := attachClient(t, e.http.URL, "test", testUser, testPassword); err == nil || err.Category != protocol.CatLimit {
		t.Fatal("new session accepted while closing")
	}
}

func TestLogsHaveNoSecrets(t *testing.T) {
	e := newEnv(t, nil)
	c := e.attach(t)
	tr := c.startTr()
	c.query(tr, "SELECT NAME FROM T_ROWS WHERE NAME = ?", []protocol.Value{{Data: []byte("secret-param-value")}}, 1)
	attachClient(t, e.http.URL, "test", testUser, "secret-wrong-password")
	logs := e.logs.String()
	for _, s := range []string{testPassword, "secret-param-value", "secret-wrong-password", c.token} {
		if strings.Contains(logs, s) {
			t.Fatalf("log contains %q", s)
		}
	}
	if !strings.Contains(logs, `"msg":"session open"`) || !strings.Contains(logs, `"user":"`+testUser+`"`) || !strings.Contains(logs, `"alias":"test"`) {
		t.Fatal(logs)
	}
}

func TestDatabaseAndTransactionInfo(t *testing.T) {
	e := newEnv(t, nil)
	c := e.attach(t)
	items := []byte{62 /* isc_info_db_sql_dialect */, 103 /* isc_info_firebird_version */, 1}
	r := c.must(op(protocol.OpDatabaseInfo, func(w *protocol.Writer) { w.U32(c.db); w.Bytes(items); w.U32(1024) }))
	got := r.Bytes()

	db, _ := fb.Attach(testDB, dpb(testUser, testPassword))
	defer fb.Detach(&db)
	want, _ := fb.DatabaseInfo(db, items, 1024)
	if !bytes.Equal(got, want) {
		t.Fatalf("got %v want %v", got, want)
	}
	tr := c.startTr()
	r = c.must(op(protocol.OpTransactionInfo, func(w *protocol.Writer) { w.U32(tr); w.Bytes([]byte{4 /* isc_info_tra_id */, 1}); w.U32(16) }))
	if b := r.Bytes(); b[0] != 4 {
		t.Fatalf("tra info %v", b)
	}
}

func writeBlob(t *testing.T, c *client, tr uint32, data []byte) [8]byte {
	r := c.must(op(protocol.OpCreateBlob, func(w *protocol.Writer) { w.U32(c.db); w.U32(tr); w.Bytes(nil) }))
	blob := r.U32()
	var q [8]byte
	copy(q[:], r.Raw(8))
	for off := 0; off < len(data); off += 1 << 20 {
		chunk := data[off:min(off+1<<20, len(data))]
		c.must(op(protocol.OpPutSegments, func(w *protocol.Writer) {
			w.U32(blob)
			w.U32(1)
			w.Bytes(chunk)
		}))
	}
	c.must(op(protocol.OpCloseBlob, func(w *protocol.Writer) { w.U32(blob) }))
	return q
}

// readBlob returns the blob content and the number of requests used.
func readBlob(t *testing.T, c *client, tr uint32, q [8]byte) ([]byte, int) {
	r := c.must(op(protocol.OpOpenBlob, func(w *protocol.Writer) {
		w.U32(c.db)
		w.U32(tr)
		w.Raw(q[:])
		w.Bytes(nil)
		w.U32(64 << 10)
	}))
	blob, _, complete, data := r.U32(), r.Bytes(), r.U8(), r.Bytes()
	requests := 1
	if complete == 1 {
		return data, requests
	}
	for {
		r := c.must(op(protocol.OpGetSegments, func(w *protocol.Writer) { w.U32(blob); w.U32(1 << 20) }))
		requests++
		data = append(data, r.Bytes()...)
		if r.U8() == 1 {
			break
		}
	}
	c.must(op(protocol.OpCloseBlob, func(w *protocol.Writer) { w.U32(blob) }))
	return data, requests + 1
}

func TestBlobs(t *testing.T) {
	e := newEnv(t, nil)
	c := e.attach(t)
	tr := c.startTr()
	for _, size := range []int{2 << 10, 50 << 20} {
		data := make([]byte, size)
		for i := range data {
			data[i] = byte(i*7 + i>>8)
		}
		q := writeBlob(t, c, tr, data)
		// Store it, then read back the id from the table to use the real path.
		p, _ := c.prepare(tr, "UPDATE OR INSERT INTO T_BLOB (ID, B) VALUES (?, ?)")
		inL := layoutOf(p.in)
		_ = inL
		r := c.must(executeOp(tr, p, []protocol.Value{int32Value(int32(size)), {Data: q[:]}}, nil, 0))
		r.U8()
		rows, _ := c.query(tr, "SELECT B FROM T_BLOB WHERE ID = ?", []protocol.Value{int32Value(int32(size))}, 1)
		var id [8]byte
		copy(id[:], rows[0][0].Data)
		got, requests := readBlob(t, c, tr, id)
		if sha256.Sum256(got) != sha256.Sum256(data) {
			t.Fatalf("size %d: content differs (got %d bytes)", size, len(got))
		}
		if size == 2<<10 && requests != 1 {
			t.Fatalf("small blob used %d requests", requests)
		}
	}
	c.trOp(protocol.OpRollback, tr)
}

func TestExecuteProcedureAndImmediate(t *testing.T) {
	e := newEnv(t, nil)
	c := e.attach(t)
	tr := c.startTr()
	p, err := c.prepare(tr, "EXECUTE PROCEDURE P_ADD(?, ?)")
	if err != nil {
		t.Fatal(err)
	}
	outL := layoutOf(p.out)
	r := c.must(executeOp(tr, p, []protocol.Value{int32Value(20), int32Value(22)}, outL, 0))
	if kind := r.U8(); kind != 1 || r.U8() != 1 || valueInt32(protocol.ReadRow(r, outL)[0]) != 42 {
		t.Fatalf("execute2: kind %d", kind)
	}
	if recordsAffected(r.Bytes()) < 0 {
		t.Fatal("no records info")
	}

	// Singleton SELECT through execute2 (fetch 0 with output layout).
	p, _ = c.prepare(tr, "SELECT ID FROM T_ROWS WHERE ID = ?")
	outL = layoutOf(p.out)
	r = c.must(executeOp(tr, p, []protocol.Value{int32Value(5)}, outL, 0))
	if kind := r.U8(); kind != 1 || r.U8() != 1 || valueInt32(protocol.ReadRow(r, outL)[0]) != 5 {
		t.Fatalf("singleton: kind %d", kind)
	}
	// Native libfbclient reports isc_stream_eof; the gateway relays it.
	if _, err := c.one(executeOp(tr, p, []protocol.Value{int32Value(-99)}, outL, 0)); err == nil || err.Status[0].Num != 335544374 /* isc_stream_eof */ {
		t.Fatalf("singleton without rows: %+v", err)
	}

	// EXECUTE IMMEDIATE with SET TRANSACTION creates a transaction id.
	r = c.must(op(protocol.OpExecuteImmediate, func(w *protocol.Writer) {
		w.U32(c.db)
		w.U32(0)
		w.U16(3)
		w.Str("SET TRANSACTION")
		protocol.WriteLayout(w, nil)
		protocol.WriteLayout(w, nil)
	}))
	newTr := r.U32()
	if newTr == 0 {
		t.Fatal("no transaction from SET TRANSACTION")
	}
	if err := c.trOp(protocol.OpCommit, newTr); err != nil {
		t.Fatal(err)
	}
	c.trOp(protocol.OpRollback, tr)
}

func TestDeferredFreeInBatch(t *testing.T) {
	e := newEnv(t, nil)
	c := e.attach(t)
	tr := c.startTr()
	p, _ := c.prepare(tr, "SELECT 1 FROM RDB$DATABASE")
	free := op(protocol.OpFree, func(w *protocol.Writer) { w.U32(p.stmt); w.U16(2) })
	free.Flags = protocol.FlagDeferred
	badFree := op(protocol.OpFree, func(w *protocol.Writer) { w.U32(9999); w.U16(2) })
	badFree.Flags = protocol.FlagDeferred
	res := c.call(free, badFree, op(protocol.OpCommit, func(w *protocol.Writer) { w.U32(tr) }))
	if len(res) != 3 || res[0].Status != 0 || res[1].Status != 1 || res[2].Status != 0 {
		t.Fatalf("results %+v", res)
	}
}

// TestExternalHoldSession opens a session on a running gateway container,
// writes in an open transaction and keeps it open, so a SIGTERM test can
// check the rollback. Runs only when FBHTTP_TEST_GATEWAY_URL is set.
func TestExternalHoldSession(t *testing.T) {
	url := os.Getenv("FBHTTP_TEST_GATEWAY_URL")
	if url == "" {
		t.Skip("FBHTTP_TEST_GATEWAY_URL not set")
	}
	c, err := attachClient(t, url, "test", testUser, testPassword)
	if err != nil {
		t.Fatal(err)
	}
	tr := c.startTr()
	if _, err := c.execSQL(tr, "UPDATE OR INSERT INTO T_KV VALUES (8001, 'sigterm')", nil); err != nil {
		t.Fatal(err)
	}
	t.Log("session open with uncommitted row 8001; holding")
	time.Sleep(time.Minute)
}

func TestClientTransactionIDInSameBatch(t *testing.T) {
	e := newEnv(t, nil)
	c := e.attach(t)
	const tr = 0x80000001
	start := op(protocol.OpStartTransaction, func(w *protocol.Writer) { w.U32(c.db); w.Bytes(tpbDefault); w.U32(tr) })
	prep := op(protocol.OpPrepare, func(w *protocol.Writer) {
		w.U32(c.db)
		w.U32(tr)
		w.U32(0)
		w.U16(3)
		w.Str("SELECT 1 FROM RDB$DATABASE")
		w.Bytes(nil)
		w.U32(0)
	})
	res := c.call(start, prep)
	if len(res) != 2 || res[0].Status != 0 || res[1].Status != 0 {
		t.Fatalf("results %+v", res)
	}
	if got := (&protocol.Reader{B: res[0].Payload}).U32(); got != tr {
		t.Fatalf("tr id %x", got)
	}
	if err := c.trOp(protocol.OpCommit, tr); err != nil {
		t.Fatal(err)
	}
	// Reusing an id that is not in the client range is refused.
	bad := op(protocol.OpStartTransaction, func(w *protocol.Writer) { w.U32(c.db); w.Bytes(tpbDefault); w.U32(5) })
	if _, err := c.one(bad); err == nil || err.Category != protocol.CatProtocol {
		t.Fatalf("got %v", err)
	}
}

func TestPrepareInfoAndCursorRecordsMatchNative(t *testing.T) {
	e := newEnv(t, nil)
	c := e.attach(t)
	tr := c.startTr()
	const sql = "SELECT R.ID, R.NAME FROM T_ROWS R WHERE R.ID < 10"
	p, err := c.prepare(tr, sql)
	if err != nil {
		t.Fatal(err)
	}
	r := c.must(executeOp(tr, p, nil, layoutOf(p.out), 5))
	if r.U8() != 2 {
		t.Fatal("not a cursor")
	}
	records := r.Bytes()

	db, _ := fb.Attach(testDB, dpb(testUser, testPassword))
	defer fb.Detach(&db)
	ntr, _ := fb.StartTransaction(db, tpbDefault)
	defer fb.Rollback(&ntr)
	st, _ := fb.Allocate(db)
	out, _, _ := st.Prepare(ntr, 3, sql)
	info, _ := st.SQLInfo(prepareInfoItems, 1024)
	if !bytes.Equal(p.info, info) {
		t.Fatalf("prepare info differs:\n%v\n%v", p.info, info)
	}
	st.Open(&ntr, 3, nil, nil, layoutOf(out))
	nrec, _ := st.RecordsInfo()
	if !bytes.Equal(records, nrec) {
		t.Fatalf("records differ:\n%v\n%v", records, nrec)
	}
}

func TestLegacyTypesByDefault(t *testing.T) {
	const sql = "SELECT SUM(AMOUNT), CURRENT_TIMESTAMP FROM T_ROWS"
	types := func(e *env) []int16 {
		c := e.attach(t)
		p, err := c.prepare(c.startTr(), sql)
		if err != nil {
			t.Fatal(err)
		}
		return []int16{p.out[0].Type &^ 1, p.out[1].Type &^ 1}
	}
	def := types(newEnv(t, nil))
	// FB3 has no INT128/time zone types; FB4/5 must be coerced to legacy.
	if def[0] != 580 || def[1] != 510 {
		t.Fatalf("default bind: got types %v, want [580 510]", def)
	}
	none := ""
	native := types(newEnv(t, func(c *config.Config) { c.SetBind = &none }))
	t.Logf("without set_bind: %v", native)
}
