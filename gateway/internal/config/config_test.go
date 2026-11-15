package config

import (
	"net/netip"
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
	if err == nil || !strings.Contains(err.Error(), "firebird_host or aliases") {
		t.Fatalf("got %v", err)
	}
	if _, err := Load("", envOf(map[string]string{"FBHTTP_PLAIN_HTTP": "true", "FBHTTP_FIREBIRD_HOST": "10.0.0.5/3050"})); err != nil {
		t.Fatalf("firebird_host only: %v", err)
	}
	for _, bad := range []string{"10.0.0.5:/db", "/db/x.fdb", "a b"} {
		if _, err := Load("", envOf(map[string]string{"FBHTTP_PLAIN_HTTP": "true", "FBHTTP_FIREBIRD_HOST": bad})); err == nil {
			t.Errorf("%q: expected error", bad)
		}
	}
}

func TestResolveFirebirdHost(t *testing.T) {
	c := &Config{FirebirdHost: "fb", Aliases: map[string]string{"erp": "other:/db/erp.fdb"}}
	for in, want := range map[string]string{
		"erp":                  "other:/db/erp.fdb",
		"localhost:erp":        "other:/db/erp.fdb",
		"ws-servico-trunk":     "fb:ws-servico-trunk",
		"localhost:ws-servico": "fb:ws-servico",
		"srv/3050:/data/x.fdb": "fb:/data/x.fdb",
		"/data/x.fdb":          "fb:/data/x.fdb",
		`C:\data\x.fdb`:        `fb:C:\data\x.fdb`,
		`srv:C:\data\x.fdb`:    `fb:C:\data\x.fdb`,
		"a:evil:/db.fdb":       "",
		"inet://evil/db.fdb":   "",
		`\\evil\share\x.fdb`:   "",
		"srv:":                 "",
		"":                     "",
	} {
		_, got, ok := c.ResolveAlias(in)
		if (want == "") == ok || got != want {
			t.Errorf("%q: got %q %v want %q", in, got, ok, want)
		}
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

func TestMaxBatchBytes(t *testing.T) {
	base := map[string]string{"FBHTTP_PLAIN_HTTP": "1", "FBHTTP_ALIASES": "a=fb:/a.fdb"}
	c, err := Load("", envOf(base))
	if err != nil || c.MaxBatchBytes != 4<<20 {
		t.Fatalf("default: %v %d", err, c.MaxBatchBytes)
	}
	base["FBHTTP_MAX_BATCH_BYTES"] = "65536"
	if c, err = Load("", envOf(base)); err != nil || c.MaxBatchBytes != 65536 {
		t.Fatalf("env: %v %d", err, c.MaxBatchBytes)
	}
	base["FBHTTP_MAX_BATCH_BYTES"] = "0"
	if _, err = Load("", envOf(base)); err == nil || !strings.Contains(err.Error(), "max_batch_bytes") {
		t.Fatalf("zero: %v", err)
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

func TestTrustedProxies(t *testing.T) {
	c, err := Load("", envOf(map[string]string{"FBHTTP_PLAIN_HTTP": "1", "FBHTTP_ALIASES": "a=fb:/a.fdb",
		"FBHTTP_TRUSTED_PROXIES": "127.0.0.1, 172.16.0.0/12"}))
	if err != nil {
		t.Fatal(err)
	}
	for in, want := range map[string]bool{"127.0.0.1": true, "::ffff:127.0.0.1": true, "172.20.0.1": true,
		"127.0.0.2": false, "10.0.0.1": false} {
		if got := c.IsTrustedProxy(netip.MustParseAddr(in)); got != want {
			t.Errorf("%s: got %v", in, got)
		}
	}
	if _, err := Load("", envOf(map[string]string{"FBHTTP_PLAIN_HTTP": "1", "FBHTTP_ALIASES": "a=fb:/a.fdb",
		"FBHTTP_TRUSTED_PROXIES": "nginx"})); err == nil || !strings.Contains(err.Error(), "trusted_proxies") {
		t.Fatalf("got %v", err)
	}
}
