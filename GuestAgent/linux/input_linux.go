//go:build linux

package main

import (
	"encoding/binary"
	"os"
	"syscall"
	"unsafe"
)

const (
	uiSetEVBit   = 0x40045564
	uiSetKeyBit  = 0x40045565
	uiSetRelBit  = 0x40045566
	uiDevCreate  = 0x5501
	uiDevDestroy = 0x5502
	uiDevSetup   = 0x405c5503
)

type uinputDevice struct{ file *os.File }

type uinputSetup struct {
	BusType, Vendor, Product, Version uint16
	Name                              [80]byte
	FFEffectsMax                      uint32
}

func newGuestInput() guestInput {
	file, err := os.OpenFile("/dev/uinput", os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return &uinputDevice{}
	}
	device := &uinputDevice{file: file}
	if device.ioctl(uiSetEVBit, 0) != nil || device.ioctl(uiSetEVBit, 1) != nil || device.ioctl(uiSetEVBit, 2) != nil {
		device.Close()
		return &uinputDevice{}
	}
	for _, code := range []uintptr{0, 1, 8} {
		if device.ioctl(uiSetRelBit, code) != nil {
			device.Close()
			return &uinputDevice{}
		}
	}
	for code := uintptr(0); code <= 767; code++ {
		if device.ioctl(uiSetKeyBit, code) != nil {
			device.Close()
			return &uinputDevice{}
		}
	}
	setup := uinputSetup{BusType: 0x06, Vendor: 0x1d6b, Product: 0x0104, Version: 1}
	copy(setup.Name[:], "EZVM Guest Input")
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, file.Fd(), uiDevSetup, uintptr(unsafe.Pointer(&setup)))
	if errno != 0 || device.ioctl(uiDevCreate, 0) != nil {
		device.Close()
		return &uinputDevice{}
	}
	return device
}

func (device *uinputDevice) Available() bool { return device != nil && device.file != nil }

func (device *uinputDevice) Write(events []inputEvent) error {
	for _, event := range events {
		// input_event on 64-bit Linux: timeval (16 bytes), then type,
		// code, value. A zero timestamp asks the input stack to timestamp it.
		data := make([]byte, 24)
		binary.LittleEndian.PutUint16(data[16:18], event.Type)
		binary.LittleEndian.PutUint16(data[18:20], event.Code)
		binary.LittleEndian.PutUint32(data[20:24], uint32(event.Value))
		if _, err := device.file.Write(data); err != nil {
			return err
		}
	}
	return nil
}

func (device *uinputDevice) Close() error {
	if device == nil || device.file == nil {
		return nil
	}
	_ = device.ioctl(uiDevDestroy, 0)
	err := device.file.Close()
	device.file = nil
	return err
}

func (device *uinputDevice) ioctl(request, argument uintptr) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, device.file.Fd(), request, argument)
	if errno != 0 {
		return errno
	}
	return nil
}
