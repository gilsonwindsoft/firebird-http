package server

import (
	"bytes"
	"compress/gzip"
	"io"
	"net/http/httptest"
	"testing"
)

func TestWriteBodyGzip(t *testing.T) {
	big := bytes.Repeat([]byte("row data "), 500)
	cases := []struct {
		name   string
		accept string
		body   []byte
		gzip   bool
	}{
		{"large, accepts gzip", "gzip", big, true},
		{"large, no accept", "", big, false},
		{"small, accepts gzip", "gzip, deflate", []byte("tiny"), false},
	}
	for _, c := range cases {
		r := httptest.NewRequest("POST", "/v1/rpc", nil)
		if c.accept != "" {
			r.Header.Set("Accept-Encoding", c.accept)
		}
		w := httptest.NewRecorder()
		writeBody(w, r, c.body)
		got := w.Body.Bytes()
		if enc := w.Header().Get("Content-Encoding"); (enc == "gzip") != c.gzip {
			t.Fatalf("%s: Content-Encoding %q", c.name, enc)
		}
		if c.gzip {
			if len(got) >= len(c.body) {
				t.Fatalf("%s: not smaller (%d >= %d)", c.name, len(got), len(c.body))
			}
			zr, err := gzip.NewReader(bytes.NewReader(got))
			if err != nil {
				t.Fatal(err)
			}
			if got, err = io.ReadAll(zr); err != nil {
				t.Fatal(err)
			}
		}
		if !bytes.Equal(got, c.body) {
			t.Fatalf("%s: body differs", c.name)
		}
	}
}
