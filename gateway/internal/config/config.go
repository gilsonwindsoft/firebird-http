// Package config loads the gateway configuration from a JSON file and
// FBHTTP_* environment variables. Environment variables win.
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Listen string `json:"listen"`
	// TLS certificate and key (PEM). Required unless PlainHTTP is true.
	TLSCert string `json:"tls_cert"`
	TLSKey  string `json:"tls_key"`
	// PlainHTTP serves without TLS. Use only behind a TLS reverse proxy or in tests.
	PlainHTTP bool `json:"plain_http"`
	// Aliases maps the name clients send to the real Firebird connection string.
	Aliases map[string]string `json:"aliases"`

	// SetBind is sent as isc_dpb_set_bind (Firebird 4+) unless the client
	// sends its own. The default makes Firebird 4/5 return the legacy types
	// (BIGINT, DOUBLE, TIMESTAMP) that clients built for Firebird 3 expect.
	// Nil means the default; an empty string disables it.
	SetBind *string `json:"set_bind"`

	MaxSessions      int `json:"max_sessions"`
	MaxSessionsPerIP int `json:"max_sessions_per_ip"`
	MaxBodyBytes     int `json:"max_body_bytes"`
	MaxFetchRows     int `json:"max_fetch_rows"`
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
		MaxInlineBlob:    1 << 20,
		IdleTimeoutSec:   1800,
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
	return &c, c.validate()
}

func applyEnv(c *Config, env func(string) string) error {
	str := map[string]*string{"FBHTTP_LISTEN": &c.Listen, "FBHTTP_TLS_CERT": &c.TLSCert, "FBHTTP_TLS_KEY": &c.TLSKey}
	for k, p := range str {
		if v := env(k); v != "" {
			*p = v
		}
	}
	num := map[string]*int{
		"FBHTTP_MAX_SESSIONS": &c.MaxSessions, "FBHTTP_MAX_SESSIONS_PER_IP": &c.MaxSessionsPerIP,
		"FBHTTP_MAX_BODY_BYTES": &c.MaxBodyBytes, "FBHTTP_MAX_FETCH_ROWS": &c.MaxFetchRows,
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
	// FBHTTP_ALIASES=name=host:/path.fdb;other=host:/other.fdb
	if v := env("FBHTTP_ALIASES"); v != "" {
		c.Aliases = map[string]string{}
		for _, part := range strings.Split(v, ";") {
			name, target, ok := strings.Cut(strings.TrimSpace(part), "=")
			if !ok || name == "" || target == "" {
				return fmt.Errorf("config: FBHTTP_ALIASES: invalid item %q", part)
			}
			c.Aliases[name] = target
		}
	}
	return nil
}

func (c *Config) validate() error {
	var errs []error
	if len(c.Aliases) == 0 {
		errs = append(errs, errors.New("aliases: at least one alias is required"))
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
		"max_body_bytes": c.MaxBodyBytes, "max_fetch_rows": c.MaxFetchRows, "idle_timeout_seconds": c.IdleTimeoutSec} {
		if v <= 0 {
			errs = append(errs, fmt.Errorf("%s: must be > 0", k))
		}
	}
	if c.MaxInlineBlob < 0 {
		errs = append(errs, errors.New("max_inline_blob: must be >= 0"))
	}
	if len(errs) > 0 {
		return fmt.Errorf("invalid configuration: %w", errors.Join(errs...))
	}
	return nil
}

// ResolveAlias maps the database string a client sent to a published target.
// It tries an exact match, then the text after the first ':' (D9).
// Anything else, including file paths, is rejected.
func (c *Config) ResolveAlias(db string) (alias, target string, ok bool) {
	if t, ok := c.Aliases[db]; ok {
		return db, t, true
	}
	if _, rest, found := strings.Cut(db, ":"); found {
		if t, ok := c.Aliases[rest]; ok {
			return rest, t, true
		}
	}
	return "", "", false
}
