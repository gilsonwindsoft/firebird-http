package server

import (
	"net/http/httptest"
	"testing"

	"fbhttp/gateway/internal/config"
)

func TestClientIPBehindProxy(t *testing.T) {
	env := map[string]string{"FBHTTP_PLAIN_HTTP": "1", "FBHTTP_FIREBIRD_HOST": "fb", "FBHTTP_TRUSTED_PROXIES": "172.16.0.0/12"}
	cfg, err := config.Load("", func(k string) string { return env[k] })
	if err != nil {
		t.Fatal(err)
	}
	srv := &Server{cfg: cfg}
	for _, c := range []struct{ remote, real, want string }{
		{"172.18.0.1:5000", "10.211.55.4", "10.211.55.4"}, // from nginx
		{"172.18.0.1:5000", "", "172.18.0.1"},             // nginx without header
		{"10.0.0.9:5000", "1.2.3.4", "10.0.0.9"},          // untrusted caller cannot spoof
	} {
		r := httptest.NewRequest("POST", "/v1/rpc", nil)
		r.RemoteAddr = c.remote
		if c.real != "" {
			r.Header.Set("X-Real-IP", c.real)
		}
		if got := srv.clientIP(r); got != c.want {
			t.Errorf("%s/%s: got %s want %s", c.remote, c.real, got, c.want)
		}
	}
}
