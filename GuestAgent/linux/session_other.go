//go:build !linux

package main

import (
	"errors"
	"time"
)

func startSessionRegistry() error                    { return nil }
func runSessionAgent() error                         { return errors.New("session mode is supported only on Linux") }
func activeSessionCapabilities(_ time.Time) []string { return nil }
