//go:build darwin

package main

import "errors"

func listenVSock(uint32) (int, error) { return -1, errors.New("AF_VSOCK is Linux-only") }
func acceptSocket(int) (int, error)   { return -1, errors.New("AF_VSOCK is Linux-only") }
func closeSocket(int)                 {}

type fdStream struct{ fd int }

func (fdStream) Read([]byte) (int, error)  { return 0, errors.New("AF_VSOCK is Linux-only") }
func (fdStream) Write([]byte) (int, error) { return 0, errors.New("AF_VSOCK is Linux-only") }
func power(string)                         {}

type unavailableInput struct{}

func newGuestInput() guestInput                         { return unavailableInput{} }
func (unavailableInput) Available() bool                { return false }
func (unavailableInput) AbsolutePointerAvailable() bool { return false }
func (unavailableInput) Write([]inputEvent) error       { return errors.New("uinput is Linux-only") }
func (unavailableInput) Close() error                   { return nil }
