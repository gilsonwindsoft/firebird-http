package server

import (
	"sync"
	"sync/atomic"
	"time"

	"fbhttp/gateway/internal/fb"
	"fbhttp/gateway/internal/protocol"
)

type kind uint8

const (
	kindDB kind = iota + 1
	kindTr
	kindStmt
	kindBlob
)

type handle struct {
	kind kind
	h    fb.Handle
	stmt *fb.Stmt
	out  protocol.Layout // fetch layout of an open cursor
}

// Session is one Firebird attachment and all handles created on it.
// mu serializes every call to the attachment.
type Session struct {
	ID       string // short id for logs; never the token
	Token    string
	Alias    string
	User     string
	RemoteIP string

	mu       sync.Mutex
	lastSeq  uint32
	lastResp []byte
	closed   bool
	handles  map[uint32]*handle
	nextID   uint32

	busy       atomic.Int32
	lastActive atomic.Int64
}

func newSession() *Session {
	s := &Session{handles: map[uint32]*handle{}}
	s.touch()
	return s
}

func (s *Session) touch() { s.lastActive.Store(time.Now().UnixNano()) }

func (s *Session) idleFor(now time.Time) time.Duration {
	return now.Sub(time.Unix(0, s.lastActive.Load()))
}

func (s *Session) add(h *handle) uint32 {
	s.nextID++
	s.handles[s.nextID] = h
	return s.nextID
}

func (s *Session) get(id uint32, k kind) (*handle, *protocol.Error) {
	if h, ok := s.handles[id]; ok && h.kind == k {
		return h, nil
	}
	return nil, fb.CodeError(badHandleCode[k])
}

var badHandleCode = map[kind]int64{
	kindDB:   fb.ErrBadDBHandle,
	kindTr:   fb.ErrBadTransHandle,
	kindStmt: fb.ErrBadStmtHandle,
	kindBlob: fb.ErrBadBlobHandle,
}

// release rolls back open transactions and detaches. Caller holds mu.
func (s *Session) release() {
	if s.closed {
		return
	}
	s.closed = true
	var db *handle
	for _, h := range s.handles {
		switch h.kind {
		case kindBlob:
			fb.CancelBlob(&h.h)
		case kindDB:
			db = h
		}
	}
	for _, h := range s.handles {
		if h.kind == kindTr {
			fb.Rollback(&h.h)
		}
	}
	if db != nil {
		fb.Detach(&db.h)
	}
	s.handles = nil
}
