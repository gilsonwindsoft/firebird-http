// Command fbhttp-gateway serves the fbhttp protocol and forwards calls to Firebird.
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"fbhttp/gateway/internal/config"
	"fbhttp/gateway/internal/fb"
	"fbhttp/gateway/internal/protocol"
	"fbhttp/gateway/internal/server"
)

func main() {
	path := flag.String("config", os.Getenv("FBHTTP_CONFIG"), "JSON configuration file (optional; FBHTTP_* variables override it)")
	health := flag.String("healthcheck", "", "probe this URL and exit 0 when healthy (for Docker HEALTHCHECK)")
	flag.Parse()
	if *health != "" {
		os.Exit(probe(*health))
	}

	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	cfg, err := config.Load(*path, os.Getenv)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if err := run(cfg, log); err != nil {
		log.Error("gateway stopped", "error", err.Error())
		os.Exit(1)
	}
}

func probe(url string) int {
	c := &http.Client{Timeout: 3 * time.Second, Transport: &http.Transport{
		// The probe runs inside the container against its own listener.
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
	}}
	resp, err := c.Get(url)
	if err != nil {
		return 1
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		return 1
	}
	return 0
}

func run(cfg *config.Config, log *slog.Logger) error {
	srv := server.New(cfg, log)
	hs := &http.Server{
		Addr:              cfg.Listen,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       2 * time.Minute,
		TLSConfig:         &tls.Config{MinVersion: tls.VersionTLS12},
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()
	go srv.RunReaper(ctx)

	errc := make(chan error, 1)
	go func() {
		if cfg.PlainHTTP {
			errc <- hs.ListenAndServe()
		} else {
			errc <- hs.ListenAndServeTLS(cfg.TLSCert, cfg.TLSKey)
		}
	}()
	log.Info("gateway started", "listen", cfg.Listen, "tls", !cfg.PlainHTTP, "protocol", protocol.Version,
		"fbclient", fb.ClientVersion(), "aliases", len(cfg.Aliases))

	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	log.Info("shutdown started", "sessions", srv.SessionCount())
	grace, cancel := context.WithTimeout(context.Background(), time.Duration(cfg.ShutdownGraceSec)*time.Second)
	defer cancel()
	err := hs.Shutdown(grace) // stops new requests and waits for running ones
	srv.CloseAll()            // rollback + detach every session
	log.Info("shutdown complete")
	if errors.Is(err, context.DeadlineExceeded) {
		log.Warn("shutdown grace period exceeded; running requests were cut")
	}
	return nil
}
