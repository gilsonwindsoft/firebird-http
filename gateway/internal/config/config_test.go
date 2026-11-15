package config

import (
	"context"
	"fmt"
	"log/slog"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

func envOf(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

func TestTLSWithoutCertificate(t *testing.T) {
	_, err := Load("", envOf(map[string]string{"FBHTTP_FIREBIRD_HOST": "fb", "FBHTTP_TLS_CERT": "/missing.pem"}))
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
	base := map[string]string{"FBHTTP_PLAIN_HTTP": "1", "FBHTTP_FIREBIRD_HOST": "fb"}
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
	p := filepath.Join(t.TempDir(), "c.json")
	os.WriteFile(p, []byte(`{"plain_http":true,"aliases":{"/db/x.fdb":"fb:/x.fdb"}}`), 0o600)
	if _, err := Load(p, envOf(nil)); err == nil {
		t.Fatal("expected error")
	}
}

func writeAliases(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func loadWithFile(t *testing.T, content string, extra map[string]string) (*Config, string, error) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "aliases.conf")
	writeAliases(t, p, content)
	env := map[string]string{"FBHTTP_PLAIN_HTTP": "1", "FBHTTP_ALIASES_FILE": p}
	for k, v := range extra {
		env[k] = v
	}
	c, err := Load("", envOf(env))
	return c, p, err
}

func TestOldAliasesVariableIgnored(t *testing.T) {
	c, err := Load("", envOf(map[string]string{"FBHTTP_PLAIN_HTTP": "1", "FBHTTP_FIREBIRD_HOST": "fb", "FBHTTP_ALIASES": "erp=other:/erp.fdb"}))
	if err != nil {
		t.Fatal(err)
	}
	if _, target, _ := c.ResolveAlias("erp"); target != "fb:erp" || c.AliasCount() != 0 {
		t.Fatalf("FBHTTP_ALIASES still read: %q %d", target, c.AliasCount())
	}
}

func TestParseAliases(t *testing.T) {
	m, err := parseAliases([]byte("\xef\xbb\xbf# servidores\r\nerp = fb:/db/erp.fdb\r\n\n  filial2=10.0.0.7:/d/erp.fdb  \n#x=y\n"))
	if err != nil || len(m) != 2 || m["erp"] != "fb:/db/erp.fdb" || m["filial2"] != "10.0.0.7:/d/erp.fdb" {
		t.Fatalf("got %v %v", m, err)
	}
	for in, want := range map[string]string{
		"a = x\nsem-igual":      "line 2",
		"a = x\n = y":           "line 2",
		"a =":                   "line 1",
		"a/b = x":               "line 1",
		"a = x\n\na = y":        "duplicate",
		"# ok\nc:d = fb:/x.fdb": "line 2",
	} {
		if _, err := parseAliases([]byte(in)); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%q: got %v want %q", in, err, want)
		}
	}
}

func TestAliasesFileLoad(t *testing.T) {
	c, _, err := loadWithFile(t, "erp = fb:/db/erp.fdb\n", nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, target, ok := c.ResolveAlias("localhost:erp"); !ok || target != "fb:/db/erp.fdb" {
		t.Fatalf("got %q %v", target, ok)
	}
	if _, _, err := loadWithFile(t, "erp\n", nil); err == nil || !strings.Contains(err.Error(), "aliases_file") || !strings.Contains(err.Error(), "line 1") {
		t.Fatalf("invalid file: %v", err)
	}
	if _, _, err := loadWithFile(t, "# vazio\n", nil); err == nil || !strings.Contains(err.Error(), "firebird_host or aliases") {
		t.Fatalf("empty file without host: %v", err)
	}
	if _, _, err := loadWithFile(t, "", map[string]string{"FBHTTP_FIREBIRD_HOST": "fb"}); err != nil {
		t.Fatalf("empty file with host: %v", err)
	}
	if _, err := Load("", envOf(map[string]string{"FBHTTP_PLAIN_HTTP": "1", "FBHTTP_ALIASES_FILE": "/missing/aliases.conf"})); err == nil || !strings.Contains(err.Error(), "aliases_file") {
		t.Fatalf("missing file: %v", err)
	}
	dir := t.TempDir()
	af := filepath.Join(dir, "aliases.conf")
	writeAliases(t, af, "a = fb:/a.fdb\n")
	cf := filepath.Join(dir, "c.json")
	os.WriteFile(cf, []byte(`{"plain_http":true,"aliases":{"b":"fb:/b.fdb"},"aliases_file":"`+af+`"}`), 0o600)
	if _, err := Load(cf, envOf(nil)); err == nil || !strings.Contains(err.Error(), "aliases_file and aliases") {
		t.Fatalf("two sources: %v", err)
	}
}

func TestReloadAliases(t *testing.T) {
	c, p, err := loadWithFile(t, "a = fb:/a.fdb\nb = fb:/b.fdb\n", nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, changed, err := c.ReloadAliases(); changed || err != nil {
		t.Fatalf("unchanged file: %v %v", changed, err)
	}
	writeAliases(t, p, "b = fb:/b.fdb\nc = fb:/c.fdb\n")
	added, removed, changed, err := c.ReloadAliases()
	if err != nil || !changed || !slices.Equal(added, []string{"c"}) || !slices.Equal(removed, []string{"a"}) {
		t.Fatalf("got %v %v %v %v", added, removed, changed, err)
	}
	if _, _, ok := c.ResolveAlias("a"); ok {
		t.Fatal("removed alias still resolves")
	}
	if _, target, ok := c.ResolveAlias("c"); !ok || target != "fb:/c.fdb" {
		t.Fatalf("new alias: %q %v", target, ok)
	}
	// Invalid or empty files keep the current table.
	for _, bad := range []string{"b = fb:/b.fdb\nlinha ruim\n", "# nada\n"} {
		writeAliases(t, p, bad)
		if _, _, _, err := c.ReloadAliases(); err == nil {
			t.Fatalf("%q: expected error", bad)
		}
		if _, _, ok := c.ResolveAlias("c"); !ok || c.AliasCount() != 2 {
			t.Fatalf("%q: table changed", bad)
		}
	}
	os.Remove(p)
	if _, _, _, err := c.ReloadAliases(); err == nil || c.AliasCount() != 2 {
		t.Fatalf("missing file: %v %d", err, c.AliasCount())
	}
}

func TestReloadDuringResolve(t *testing.T) {
	c, p, err := loadWithFile(t, "a = fb:/a.fdb\n", nil)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < 200; i++ {
			c.ResolveAlias("a")
			c.ResolveAlias("b")
		}
	}()
	for i := 0; i < 50; i++ {
		writeAliases(t, p, fmt.Sprintf("a = fb:/a.fdb\nb = fb:/b%d.fdb\n", i))
		if _, _, _, err := c.ReloadAliases(); err != nil {
			t.Fatal(err)
		}
	}
	<-done
}

func TestWatchAliases(t *testing.T) {
	c, p, err := loadWithFile(t, "a = fb:/a.fdb\n", nil)
	if err != nil {
		t.Fatal(err)
	}
	var logs strings.Builder
	var mu sync.Mutex
	log := slog.New(slog.NewTextHandler(writerFunc(func(b []byte) (int, error) {
		mu.Lock()
		defer mu.Unlock()
		return logs.Write(b)
	}), nil))
	ctx, cancel := context.WithCancel(context.Background())
	stopped := make(chan struct{})
	go func() { c.WatchAliases(ctx, 10*time.Millisecond, log); close(stopped) }()
	writeAliases(t, p, "a = fb:/a.fdb\nnovo = fb:/n.fdb\n")
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, _, ok := c.ResolveAlias("novo"); ok {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("alias not reloaded")
		}
		time.Sleep(5 * time.Millisecond)
	}
	writeAliases(t, p, "ruim\n")
	time.Sleep(100 * time.Millisecond)
	cancel()
	<-stopped
	mu.Lock()
	out := logs.String()
	mu.Unlock()
	if !strings.Contains(out, "aliases reloaded") || !strings.Contains(out, "added=[novo]") {
		t.Fatalf("reload not logged: %s", out)
	}
	if n := strings.Count(out, "aliases reload failed"); n != 1 {
		t.Fatalf("failure logged %d times: %s", n, out)
	}
}

type writerFunc func([]byte) (int, error)

func (f writerFunc) Write(b []byte) (int, error) { return f(b) }

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
	c, err := Load("", envOf(map[string]string{"FBHTTP_PLAIN_HTTP": "1", "FBHTTP_FIREBIRD_HOST": "fb",
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
	if _, err := Load("", envOf(map[string]string{"FBHTTP_PLAIN_HTTP": "1", "FBHTTP_FIREBIRD_HOST": "fb",
		"FBHTTP_TRUSTED_PROXIES": "nginx"})); err == nil || !strings.Contains(err.Error(), "trusted_proxies") {
		t.Fatalf("got %v", err)
	}
}
