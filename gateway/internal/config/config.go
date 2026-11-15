// Package config loads the gateway configuration from a JSON file and
// FBHTTP_* environment variables. Environment variables win.
package config

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"net/netip"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

type Config struct {
	Listen string `json:"listen"`
	// TLS certificate and key (PEM). Required unless PlainHTTP is true.
	TLSCert string `json:"tls_cert"`
	TLSKey  string `json:"tls_key"`
	// PlainHTTP serves without TLS. Use only behind a TLS reverse proxy or in tests.
	PlainHTTP bool `json:"plain_http"`
	// TrustedProxies lists the addresses (IP or CIDR) of the reverse proxy.
	// Requests from them take the client address from X-Real-IP.
	TrustedProxies []string `json:"trusted_proxies"`
	trusted        []netip.Prefix
	// FirebirdHost ("host" or "host/port") receives every database the client
	// sends that is not in Aliases. The host part the client sends is ignored.
	FirebirdHost string `json:"firebird_host"`
	// Aliases maps the name clients send to the real Firebird connection string.
	Aliases map[string]string `json:"aliases"`
	// AliasesFile holds the aliases, one "name = target" per line. It is
	// reread every AliasReloadInterval. It excludes Aliases.
	AliasesFile string `json:"aliases_file"`
	// table is the alias table in use after Load; reloads swap it whole.
	table *atomic.Pointer[map[string]string]
	// lastFile is the content of the last AliasesFile read (reload goroutine only).
	lastFile []byte

	// SetBind is sent as isc_dpb_set_bind (Firebird 4+) unless the client
	// sends its own. The default makes Firebird 4/5 return the legacy types
	// (BIGINT, DOUBLE, TIMESTAMP) that clients built for Firebird 3 expect.
	// Nil means the default; an empty string disables it.
	SetBind *string `json:"set_bind"`

	MaxSessions      int `json:"max_sessions"`
	MaxSessionsPerIP int `json:"max_sessions_per_ip"`
	MaxBodyBytes     int `json:"max_body_bytes"`
	MaxFetchRows     int `json:"max_fetch_rows"`
	// MaxBatchBytes stops a row batch early (at least one row) when the
	// encoded rows reach this size, before gzip.
	MaxBatchBytes    int `json:"max_batch_bytes"`
	MaxInlineBlob    int `json:"max_inline_blob"`
	IdleTimeoutSec   int `json:"idle_timeout_seconds"`
	ShutdownGraceSec int `json:"shutdown_grace_seconds"`
}

func defaults() Config {
	return Config{
		Listen:           ":8443",
		MaxSessions:      500,
		MaxSessionsPerIP: 50,
		MaxBodyBytes:     64 << 20,
		MaxFetchRows:     5000,
		MaxBatchBytes:    4 << 20,
		MaxInlineBlob:    1 << 20,
		IdleTimeoutSec:   600,
		ShutdownGraceSec: 20,
	}
}

const DefaultSetBind = "int128 to legacy;decfloat to legacy;time zone to legacy"

// Bind returns the isc_dpb_set_bind value to use ("" = none).
func (c *Config) Bind() string {
	if c.SetBind == nil {
		return DefaultSetBind
	}
	return *c.SetBind
}

func (c *Config) IdleTimeout() time.Duration { return time.Duration(c.IdleTimeoutSec) * time.Second }

// Load reads path (optional when empty) and applies environment overrides.
func Load(path string, env func(string) string) (*Config, error) {
	c := defaults()
	if path != "" {
		b, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("config: %w", err)
		}
		if err := json.Unmarshal(b, &c); err != nil {
			return nil, fmt.Errorf("config %s: %w", path, err)
		}
	}
	if err := applyEnv(&c, env); err != nil {
		return nil, err
	}
	if c.AliasesFile != "" {
		if len(c.Aliases) > 0 {
			return nil, errors.New("invalid configuration: aliases_file and aliases: use only one")
		}
		// A missing file starts with no aliases; WatchAliases loads it once it appears.
		b, err := os.ReadFile(c.AliasesFile)
		if err != nil && !errors.Is(err, fs.ErrNotExist) {
			return nil, fmt.Errorf("config: aliases_file: %w", err)
		}
		if err == nil {
			if c.Aliases, err = parseAliases(b); err != nil {
				return nil, fmt.Errorf("config: aliases_file %s: %w", c.AliasesFile, err)
			}
			c.lastFile = b
		}
	}
	if err := c.validate(); err != nil {
		return &c, err
	}
	c.table = &atomic.Pointer[map[string]string]{}
	c.table.Store(&c.Aliases)
	return &c, nil
}

// AliasReloadInterval is how often WatchAliases rereads AliasesFile.
const AliasReloadInterval = 60 * time.Second

// parseAliases reads "name = target" lines. Blank lines and lines starting
// with '#' are skipped.
func parseAliases(b []byte) (map[string]string, error) {
	m := map[string]string{}
	b = bytes.TrimPrefix(b, []byte("\xef\xbb\xbf")) // UTF-8 BOM from Windows editors
	for i, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		name, target, ok := strings.Cut(line, "=")
		name, target = strings.TrimSpace(name), strings.TrimSpace(target)
		switch {
		case !ok || name == "" || target == "":
			return nil, fmt.Errorf("line %d: expected \"name = target\"", i+1)
		case strings.ContainsAny(name, ":/\\"):
			return nil, fmt.Errorf("line %d: name %q must not contain ':', '/' or '\\'", i+1, name)
		}
		if _, dup := m[name]; dup {
			return nil, fmt.Errorf("line %d: duplicate name %q", i+1, name)
		}
		m[name] = target
	}
	return m, nil
}

// ReloadAliases rereads AliasesFile. It does nothing when the content did not
// change. On error the current table stays in use.
func (c *Config) ReloadAliases() (added, removed []string, changed bool, err error) {
	b, err := os.ReadFile(c.AliasesFile)
	if err != nil {
		return nil, nil, false, err
	}
	if bytes.Equal(b, c.lastFile) {
		return nil, nil, false, nil
	}
	c.lastFile = b // a bad file is reported once, not on every tick
	m, err := parseAliases(b)
	if err != nil {
		return nil, nil, true, err
	}
	if len(m) == 0 && c.FirebirdHost == "" {
		return nil, nil, true, errors.New("no aliases and no firebird_host")
	}
	old := c.aliases()
	for k := range m {
		if _, ok := old[k]; !ok {
			added = append(added, k)
		}
	}
	for k := range old {
		if _, ok := m[k]; !ok {
			removed = append(removed, k)
		}
	}
	slices.Sort(added)
	slices.Sort(removed)
	c.table.Store(&m)
	return added, removed, true, nil
}

// WatchAliases calls ReloadAliases every interval until ctx ends.
func (c *Config) WatchAliases(ctx context.Context, every time.Duration, log *slog.Logger) {
	t := time.NewTicker(every)
	defer t.Stop()
	lastErr := ""
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		added, removed, changed, err := c.ReloadAliases()
		switch {
		case err != nil:
			if err.Error() != lastErr { // a missing file is reported once, not every tick
				log.Warn("aliases reload failed; previous aliases kept", "file", c.AliasesFile, "error", err.Error())
			}
			lastErr = err.Error()
		case changed:
			lastErr = ""
			log.Info("aliases reloaded", "file", c.AliasesFile, "aliases", c.AliasCount(), "added", added, "removed", removed)
		}
	}
}

// aliases returns the alias table in use. A Config built without Load uses Aliases.
func (c *Config) aliases() map[string]string {
	if c.table != nil {
		return *c.table.Load()
	}
	return c.Aliases
}

// AliasCount returns the number of aliases in use.
func (c *Config) AliasCount() int { return len(c.aliases()) }

func applyEnv(c *Config, env func(string) string) error {
	str := map[string]*string{"FBHTTP_LISTEN": &c.Listen, "FBHTTP_TLS_CERT": &c.TLSCert, "FBHTTP_TLS_KEY": &c.TLSKey,
		"FBHTTP_FIREBIRD_HOST": &c.FirebirdHost, "FBHTTP_ALIASES_FILE": &c.AliasesFile}
	for k, p := range str {
		if v := env(k); v != "" {
			*p = v
		}
	}
	num := map[string]*int{
		"FBHTTP_MAX_SESSIONS": &c.MaxSessions, "FBHTTP_MAX_SESSIONS_PER_IP": &c.MaxSessionsPerIP,
		"FBHTTP_MAX_BODY_BYTES": &c.MaxBodyBytes, "FBHTTP_MAX_FETCH_ROWS": &c.MaxFetchRows,
		"FBHTTP_MAX_BATCH_BYTES": &c.MaxBatchBytes,
		"FBHTTP_MAX_INLINE_BLOB": &c.MaxInlineBlob, "FBHTTP_IDLE_TIMEOUT_SECONDS": &c.IdleTimeoutSec,
		"FBHTTP_SHUTDOWN_GRACE_SECONDS": &c.ShutdownGraceSec,
	}
	for k, p := range num {
		if v := env(k); v != "" {
			n, err := strconv.Atoi(v)
			if err != nil {
				return fmt.Errorf("config: %s: %w", k, err)
			}
			*p = n
		}
	}
	// FBHTTP_SET_BIND=none disables it.
	if v := env("FBHTTP_SET_BIND"); v != "" {
		if v == "none" {
			v = ""
		}
		c.SetBind = &v
	}
	if v := env("FBHTTP_PLAIN_HTTP"); v != "" {
		b, err := strconv.ParseBool(v)
		if err != nil {
			return fmt.Errorf("config: FBHTTP_PLAIN_HTTP: %w", err)
		}
		c.PlainHTTP = b
	}
	// FBHTTP_TRUSTED_PROXIES=127.0.0.1,172.16.0.0/12
	if v := env("FBHTTP_TRUSTED_PROXIES"); v != "" {
		c.TrustedProxies = strings.Split(v, ",")
	}
	return nil
}

func (c *Config) validate() error {
	var errs []error
	if len(c.Aliases) == 0 && c.FirebirdHost == "" {
		errs = append(errs, errors.New("firebird_host or aliases: at least one is required"))
	}
	if c.FirebirdHost != "" && (strings.ContainsAny(c.FirebirdHost, ":\\ ") || strings.HasPrefix(c.FirebirdHost, "/")) {
		errs = append(errs, fmt.Errorf("firebird_host: %q must be \"host\" or \"host/port\"", c.FirebirdHost))
	}
	for name := range c.Aliases {
		if strings.ContainsAny(name, ":/\\") {
			errs = append(errs, fmt.Errorf("aliases: name %q must not contain ':', '/' or '\\'", name))
		}
	}
	if !c.PlainHTTP {
		for k, p := range map[string]string{"tls_cert": c.TLSCert, "tls_key": c.TLSKey} {
			if p == "" {
				errs = append(errs, fmt.Errorf("%s: required when plain_http is false", k))
			} else if f, err := os.Open(p); err != nil {
				errs = append(errs, fmt.Errorf("%s: %w", k, err))
			} else {
				f.Close()
			}
		}
	}
	for k, v := range map[string]int{"max_sessions": c.MaxSessions, "max_sessions_per_ip": c.MaxSessionsPerIP,
		"max_body_bytes": c.MaxBodyBytes, "max_fetch_rows": c.MaxFetchRows, "max_batch_bytes": c.MaxBatchBytes,
		"idle_timeout_seconds": c.IdleTimeoutSec} {
		if v <= 0 {
			errs = append(errs, fmt.Errorf("%s: must be > 0", k))
		}
	}
	c.trusted = nil
	for _, v := range c.TrustedProxies {
		v = strings.TrimSpace(v)
		p, err := netip.ParsePrefix(v)
		if err != nil {
			a, aerr := netip.ParseAddr(v)
			if aerr != nil {
				errs = append(errs, fmt.Errorf("trusted_proxies: invalid address %q", v))
				continue
			}
			p = netip.PrefixFrom(a, a.BitLen())
		}
		c.trusted = append(c.trusted, p.Masked())
	}
	if c.MaxInlineBlob < 0 {
		errs = append(errs, errors.New("max_inline_blob: must be >= 0"))
	}
	if len(errs) > 0 {
		return fmt.Errorf("invalid configuration: %w", errors.Join(errs...))
	}
	return nil
}

// IsTrustedProxy reports whether addr belongs to trusted_proxies.
func (c *Config) IsTrustedProxy(addr netip.Addr) bool {
	addr = addr.Unmap()
	for _, p := range c.trusted {
		if p.Contains(addr) {
			return true
		}
	}
	return false
}

// ResolveAlias maps the database string a client sent to a Firebird target.
// It tries an exact alias, then the text after the first ':' as an alias (D9).
// Otherwise, when firebird_host is set, the database part (path or server
// alias) is opened on that host and the host the client sent is ignored.
func (c *Config) ResolveAlias(db string) (alias, target string, ok bool) {
	aliases := c.aliases()
	if t, ok := aliases[db]; ok {
		return db, t, true
	}
	rest := db
	if !isDrivePath(db) {
		if _, r, found := strings.Cut(db, ":"); found {
			rest = r
		}
	}
	if t, ok := aliases[rest]; ok {
		return rest, t, true
	}
	if c.FirebirdHost == "" || !safeDatabase(rest) {
		return "", "", false
	}
	return rest, c.FirebirdHost + ":" + rest, true
}

// isDrivePath reports a Windows path such as C:\data\x.fdb.
func isDrivePath(s string) bool {
	return len(s) >= 3 && s[1] == ':' && (s[2] == '\\' || s[2] == '/') &&
		(s[0]|0x20 >= 'a' && s[0]|0x20 <= 'z')
}

// safeDatabase rejects anything Firebird could read as another server:
// a second "host:", UNC (\\host\path) and URL forms (inet://, xnet://).
func safeDatabase(s string) bool {
	if s == "" || strings.HasPrefix(s, "\\\\") || strings.HasPrefix(s, "//") || strings.ContainsAny(s, "\x00\r\n") {
		return false
	}
	if isDrivePath(s) {
		s = s[2:]
	}
	return !strings.Contains(s, ":")
}
