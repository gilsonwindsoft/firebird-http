// Package server implements the fbhttp HTTP endpoints and session lifecycle.
package server

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"sync"
	"time"

	"fbhttp/gateway/internal/config"
	"fbhttp/gateway/internal/fb"
	"fbhttp/gateway/internal/protocol"
)

const contentType = "application/x-fbhttp"

type Server struct {
	cfg *config.Config
	log *slog.Logger
	// debugSQL logs SQL text, column types and the first row of each cursor.
	// Test environments only: it writes data to the log (FBHTTP_DEBUG_SQL=1).
	debugSQL bool

	mu       sync.Mutex
	sessions map[string]*Session // by token
	perIP    map[string]int
	closing  bool
}

func New(cfg *config.Config, log *slog.Logger) *Server {
	srv := &Server{cfg: cfg, log: log, sessions: map[string]*Session{}, perIP: map[string]int{}}
	srv.debugSQL = os.Getenv("FBHTTP_DEBUG_SQL") == "1"
	if srv.debugSQL {
		log.Warn("FBHTTP_DEBUG_SQL=1: SQL text and row data are written to the log")
	}
	return srv
}

func (srv *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/rpc", srv.handleRPC)
	mux.HandleFunc("POST /v1/ping", srv.handlePing)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNoContent) })
	return mux
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func writeBody(w http.ResponseWriter, b []byte) {
	w.Header().Set("Content-Type", contentType)
	w.Write(b)
}

func errorResponse(code uint16, e *protocol.Error) []byte {
	return protocol.EncodeResponse([]protocol.Result{{Code: code, Status: protocol.StatusError, Payload: protocol.EncodeError(e)}})
}

func (srv *Server) lookup(token string) *Session {
	srv.mu.Lock()
	defer srv.mu.Unlock()
	return srv.sessions[token]
}

func (srv *Server) handlePing(w http.ResponseWriter, r *http.Request) {
	s := srv.lookup(r.Header.Get("X-Session"))
	if s == nil {
		w.WriteHeader(http.StatusGone)
		return
	}
	s.touch()
	w.WriteHeader(http.StatusNoContent)
}

func (srv *Server) handleRPC(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, int64(srv.cfg.MaxBodyBytes)))
	if err != nil {
		var tooBig *http.MaxBytesError
		if errors.As(err, &tooBig) {
			http.Error(w, "request body too large", http.StatusRequestEntityTooLarge)
		} else {
			http.Error(w, "read error", http.StatusBadRequest)
		}
		return
	}
	req, err := protocol.DecodeRequest(body)
	if err != nil || len(req.Ops) == 0 {
		http.Error(w, "malformed request", http.StatusBadRequest)
		return
	}
	if req.Version != protocol.Version {
		writeBody(w, errorResponse(req.Ops[0].Code, protoErr(protocol.CatProtocol,
			"unsupported fbhttp protocol version %d; supported versions: %d", req.Version, protocol.Version)))
		return
	}
	if req.Ops[0].Code == protocol.OpAttach {
		writeBody(w, srv.attach(r, req))
		return
	}

	s := srv.lookup(r.Header.Get("X-Session"))
	if s == nil {
		writeBody(w, errorResponse(req.Ops[0].Code, protoErr(protocol.CatSession, "fbhttp: invalid or expired session")))
		return
	}
	s.busy.Add(1)
	s.touch()
	defer func() { s.touch(); s.busy.Add(-1) }()

	s.mu.Lock()
	resp, failed, ferr := srv.run(s, req)
	closed := s.closed
	s.mu.Unlock()
	if closed {
		srv.remove(s, "detach")
	}
	writeBody(w, resp)
	attrs := []any{"session", s.ID, "seq", req.Seq, "ops", opcodes(req), "error", failed, "ms", time.Since(start).Milliseconds()}
	if ferr != nil {
		// Category and gds codes only: messages can contain data values.
		attrs = append(attrs, "category", ferr.Category, "gds", gdsCodes(ferr))
		if srv.debugSQL {
			attrs = append(attrs, "message", ferr.Messages)
		}
	}
	srv.log.Info("request", attrs...)
}

func opcodes(req protocol.Request) []uint16 {
	ops := make([]uint16, len(req.Ops))
	for i, op := range req.Ops {
		ops[i] = op.Code
	}
	return ops
}

// run applies the seq rules and executes the batch. Caller holds s.mu.
// Waiting on s.mu also covers "same seq still running": the retry gets the
// stored response once the original finishes.
func (srv *Server) run(s *Session, req protocol.Request) (resp []byte, failed bool, ferr *protocol.Error) {
	switch {
	case s.closed:
		e := protoErr(protocol.CatSession, "fbhttp: invalid or expired session")
		return errorResponse(req.Ops[0].Code, e), true, e
	case req.Seq == s.lastSeq:
		return s.lastResp, false, nil
	case req.Seq != s.lastSeq+1:
		e := protoErr(protocol.CatProtocol, "fbhttp: out of order request: seq %d, expected %d", req.Seq, s.lastSeq+1)
		return errorResponse(req.Ops[0].Code, e), true, e
	}
	var results []protocol.Result
	for _, op := range req.Ops {
		if op.Code == protocol.OpAttach {
			ferr = protoErr(protocol.CatProtocol, "ATTACH must be the only operation")
			results = append(results, protocol.Result{Code: op.Code, Status: protocol.StatusError, Payload: protocol.EncodeError(ferr)})
			failed = true
			break
		}
		payload, e := srv.execSafe(s, op)
		if e != nil {
			results = append(results, protocol.Result{Code: op.Code, Status: protocol.StatusError, Payload: protocol.EncodeError(e)})
			if op.Flags&protocol.FlagDeferred != 0 {
				continue
			}
			failed, ferr = true, e
			break
		}
		results = append(results, protocol.Result{Code: op.Code, Status: protocol.StatusOK, Payload: payload})
		if s.closed {
			break
		}
	}
	resp = protocol.EncodeResponse(results)
	s.lastSeq, s.lastResp = req.Seq, resp
	return resp, failed, ferr
}

func gdsCodes(e *protocol.Error) []int64 {
	var codes []int64
	for _, it := range e.Status {
		if it.Tag == 1 || it.Tag == 18 { // isc_arg_gds, isc_arg_warning
			codes = append(codes, it.Num)
		}
	}
	return codes
}

func (srv *Server) execSafe(s *Session, op protocol.Op) (payload []byte, e *protocol.Error) {
	defer func() {
		if p := recover(); p != nil {
			srv.log.Error("panic in operation", "session", s.ID, "op", op.Code, "panic", p)
			payload, e = nil, protoErr(protocol.CatInternal, "fbhttp: internal error")
		}
	}()
	return srv.exec(s, op)
}

func newToken() string {
	b := make([]byte, 16)
	rand.Read(b)
	return hex.EncodeToString(b)
}

func (srv *Server) attach(r *http.Request, req protocol.Request) []byte {
	op := req.Ops[0]
	if len(req.Ops) != 1 || req.Seq != 1 {
		return errorResponse(op.Code, protoErr(protocol.CatProtocol, "ATTACH must be the only operation and use seq 1"))
	}
	rd := &protocol.Reader{B: op.Payload}
	dbname, dpb := rd.Str(), rd.Bytes()
	if rd.Err != nil || len(rd.B) != 0 {
		return errorResponse(op.Code, protoErr(protocol.CatProtocol, "malformed ATTACH payload"))
	}
	ip := clientIP(r)
	user := fb.DPBUser(dpb)
	alias, target, ok := srv.cfg.ResolveAlias(dbname)
	if !ok {
		srv.log.Warn("attach refused", "reason", "alias not published", "user", user, "ip", ip)
		return errorResponse(op.Code, protoErr(protocol.CatSession, "fbhttp: database %q is not published by this gateway", dbname))
	}
	clean, ok := fb.SanitizeDPB(dpb)
	if !ok {
		return errorResponse(op.Code, protoErr(protocol.CatProtocol, "malformed DPB"))
	}
	clean = fb.AddDPBDefault(clean, fb.DPBSetBind, srv.cfg.Bind())
	if e := srv.reserve(ip); e != nil {
		srv.log.Warn("attach refused", "reason", "limit", "user", user, "alias", alias, "ip", ip)
		return errorResponse(op.Code, e)
	}
	db, e := fb.Attach(target, clean)
	if e != nil {
		srv.unreserve(ip)
		srv.log.Warn("attach failed", "user", user, "alias", alias, "ip", ip, "error", e.Error())
		return errorResponse(op.Code, e)
	}
	s := newSession()
	s.Token, s.Alias, s.User, s.RemoteIP = newToken(), alias, user, ip
	sum := sha256.Sum256([]byte(s.Token))
	s.ID = hex.EncodeToString(sum[:4])
	dbID := s.add(&handle{kind: kindDB, h: db})
	w := &protocol.Writer{}
	w.Str(s.Token)
	w.U32(dbID)
	s.lastSeq = 1
	s.lastResp = protocol.EncodeResponse([]protocol.Result{{Code: op.Code, Status: protocol.StatusOK, Payload: w.B}})

	srv.mu.Lock()
	srv.sessions[s.Token] = s
	srv.mu.Unlock()
	srv.log.Info("session open", "session", s.ID, "user", user, "alias", alias, "ip", ip)
	return s.lastResp
}

func (srv *Server) reserve(ip string) *protocol.Error {
	srv.mu.Lock()
	defer srv.mu.Unlock()
	switch {
	case srv.closing:
		return protoErr(protocol.CatLimit, "fbhttp: gateway is shutting down")
	case len(srv.sessions)+srv.pending() >= srv.cfg.MaxSessions:
		return protoErr(protocol.CatLimit, "fbhttp: session limit reached (%d)", srv.cfg.MaxSessions)
	case srv.perIP[ip] >= srv.cfg.MaxSessionsPerIP:
		return protoErr(protocol.CatLimit, "fbhttp: session limit per client address reached (%d)", srv.cfg.MaxSessionsPerIP)
	}
	srv.perIP[ip]++
	return nil
}

// pending counts reserved slots whose attach is still running.
func (srv *Server) pending() int {
	n := 0
	for _, c := range srv.perIP {
		n += c
	}
	return n - len(srv.sessions)
}

func (srv *Server) unreserve(ip string) {
	srv.mu.Lock()
	defer srv.mu.Unlock()
	if srv.perIP[ip]--; srv.perIP[ip] <= 0 {
		delete(srv.perIP, ip)
	}
}

// remove forgets a session whose attachment is already released.
func (srv *Server) remove(s *Session, reason string) {
	srv.mu.Lock()
	_, ok := srv.sessions[s.Token]
	delete(srv.sessions, s.Token)
	srv.mu.Unlock()
	if ok {
		srv.unreserve(s.RemoteIP)
		srv.log.Info("session close", "session", s.ID, "user", s.User, "alias", s.Alias, "reason", reason)
	}
}

// close releases a session. It waits for a running request to finish.
func (srv *Server) close(s *Session, reason string) {
	s.mu.Lock()
	s.release()
	s.mu.Unlock()
	srv.remove(s, reason)
}

// Reap closes sessions idle longer than the timeout. Busy sessions are skipped.
func (srv *Server) Reap(now time.Time) {
	srv.mu.Lock()
	var idle []*Session
	for _, s := range srv.sessions {
		if s.busy.Load() == 0 && s.idleFor(now) > srv.cfg.IdleTimeout() {
			idle = append(idle, s)
		}
	}
	srv.mu.Unlock()
	for _, s := range idle {
		if s.mu.TryLock() {
			if s.busy.Load() == 0 && s.idleFor(now) > srv.cfg.IdleTimeout() {
				s.release()
				s.mu.Unlock()
				srv.remove(s, "idle timeout")
				continue
			}
			s.mu.Unlock()
		}
	}
}

// RunReaper calls Reap periodically until ctx ends.
func (srv *Server) RunReaper(ctx context.Context) {
	t := time.NewTicker(max(srv.cfg.IdleTimeout()/10, time.Second))
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			srv.Reap(now)
		}
	}
}

// CloseAll refuses new sessions and rolls back and detaches every session.
func (srv *Server) CloseAll() {
	srv.mu.Lock()
	srv.closing = true
	all := make([]*Session, 0, len(srv.sessions))
	for _, s := range srv.sessions {
		all = append(all, s)
	}
	srv.mu.Unlock()
	for _, s := range all {
		srv.close(s, "shutdown")
	}
}

// SessionCount is used by tests and logs.
func (srv *Server) SessionCount() int {
	srv.mu.Lock()
	defer srv.mu.Unlock()
	return len(srv.sessions)
}
