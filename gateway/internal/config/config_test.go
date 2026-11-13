package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func envOf(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

func TestTLSWithoutCertificate(t *testing.T) {
	_, err := Load("", envOf(map[string]string{"FBHTTP_ALIASES": "erp=fb:/db/erp.fdb", "FBHTTP_TLS_CERT": "/missing.pem"}))
	if err == nil || !strings.Contains(err.Error(), "tls_cert") || !strings.Contains(err.Error(), "tls_key") {
		t.Fatalf("got %v", err)
	}
}

func TestNoAliases(t *testing.T) {
	_, err := Load("", envOf(map[string]string{"FBHTTP_PLAIN_HTTP": "true"}))
	if err == nil || !strings.Contains(err.Error(), "aliases") {
		t.Fatalf("got %v", err)
	}
}

func TestFileAndEnvPriority(t *testing.T) {
	p := filepath.Join(t.TempDir(), "c.json")
	os.WriteFile(p, []byte(`{"plain_http":true,"listen":":1","max_sessions":3,"aliases":{"a":"fb:/a.fdb"}}`), 0o600)
	c, err := Load(p, envOf(map[string]string{"FBHTTP_LISTEN": ":2"}))
	if err != nil {
		t.Fatal(err)
	}
	if c.Listen != ":2" || c.MaxSessions != 3 || c.Aliases["a"] != "fb:/a.fdb" {
		t.Fatalf("got %+v", c)
	}
}

func TestBadAliasName(t *testing.T) {
	_, err := Load("", envOf(map[string]string{"FBHTTP_PLAIN_HTTP": "1", "FBHTTP_ALIASES": "/db/x.fdb=fb:/x.fdb"}))
	if err == nil {
		t.Fatal("expected error")
	}
}

func TestResolveAlias(t *testing.T) {
	c := &Config{Aliases: map[string]string{"erp": "fb:/db/erp.fdb"}}
	for in, want := range map[string]bool{
		"erp": true, "server:erp": true, "localhost/3050:erp": true,
		"/db/erp.fdb": false, "fb:/db/erp.fdb": false, "server:other": false, "": false,
	} {
		if _, _, ok := c.ResolveAlias(in); ok != want {
			t.Errorf("%q: got %v", in, ok)
		}
	}
}
