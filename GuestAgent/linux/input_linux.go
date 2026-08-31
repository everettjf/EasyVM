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
	uiSetAbsBit  = 0x40045567
	uiDevCreate  = 0x5501
	uiDevDestroy = 0x5502
	uiDevSetup   = 0x405c5503
	uiAbsSetup   = 0x401c5504
)

type uinputDevice struct {
	file         *os.File
	absoluteFile *os.File
}

type uinputSetup struct {
	BusType, Vendor, Product, Version uint16
	Name                              [80]byte
	FFEffectsMax                      uint32
}

type inputAbsInfo struct {
	Value, Minimum, Maximum, Fuzz, Flat, Resolution int32
}

type uinputAbsSetup struct {
	Code    uint16
	Padding uint16
	AbsInfo inputAbsInfo
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
	device.absoluteFile = createAbsolutePointer()
	return device
}

func (device *uinputDevice) Available() bool { return device != nil && device.file != nil }

func (device *uinputDevice) AbsolutePointerAvailable() bool {
	return device != nil && device.file != nil && device.absoluteFile != nil
}

func (device *uinputDevice) Write(events []inputEvent) error {
	// The host may coalesce several independently synchronized reports into
	// one request. Route each report separately so a keyboard report adjacent
	// to an absolute-pointer report never gets written to the tablet device.
	start := 0
	for index, event := range events {
		if event.Type != 0 {
			continue
		}
		report := events[start : index+1]
		file := device.file
		for _, item := range report {
			if item.Type == 3 || (item.Type == 1 && item.Code >= 272 && item.Code <= 274) {
				if device.absoluteFile == nil {
					return syscall.ENODEV
				}
				file = device.absoluteFile
				break
			}
		}
		if err := writeInputEvents(file, report); err != nil {
			return err
		}
		start = index + 1
	}
	return nil
}

func writeInputEvents(file *os.File, events []inputEvent) error {
	for _, event := range events {
		// input_event on 64-bit Linux: timeval (16 bytes), then type,
		// code, value. A zero timestamp asks the input stack to timestamp it.
		data := make([]byte, 24)
		binary.LittleEndian.PutUint16(data[16:18], event.Type)
		binary.LittleEndian.PutUint16(data[18:20], event.Code)
		binary.LittleEndian.PutUint32(data[20:24], uint32(event.Value))
		if _, err := file.Write(data); err != nil {
			return err
		}
	}
	return nil
}

func (device *uinputDevice) Close() error {
	if device == nil || device.file == nil {
		return nil
	}
	if device.absoluteFile != nil {
		_ = ioctlFile(device.absoluteFile, uiDevDestroy, 0)
		_ = device.absoluteFile.Close()
		device.absoluteFile = nil
	}
	_ = device.ioctl(uiDevDestroy, 0)
	err := device.file.Close()
	device.file = nil
	return err
}

func (device *uinputDevice) ioctl(request, argument uintptr) error {
	return ioctlFile(device.file, request, argument)
}

func ioctlFile(file *os.File, request, argument uintptr) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, file.Fd(), request, argument)
	if errno != 0 {
		return errno
	}
	return nil
}

func createAbsolutePointer() *os.File {
	file, err := os.OpenFile("/dev/uinput", os.O_WRONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil
	}
	fail := func() *os.File {
		_ = file.Close()
		return nil
	}
	if ioctlFile(file, uiSetEVBit, 0) != nil ||
		ioctlFile(file, uiSetEVBit, 1) != nil ||
		ioctlFile(file, uiSetEVBit, 3) != nil {
		return fail()
	}
	for _, code := range []uintptr{272, 273, 274} {
		if ioctlFile(file, uiSetKeyBit, code) != nil {
			return fail()
		}
	}
	if ioctlFile(file, uiSetAbsBit, 0) != nil || ioctlFile(file, uiSetAbsBit, 1) != nil {
		return fail()
	}
	x := uinputAbsSetup{Code: 0, AbsInfo: inputAbsInfo{Maximum: 32767}}
	y := uinputAbsSetup{Code: 1, AbsInfo: inputAbsInfo{Maximum: 32767}}
	if ioctlFile(file, uiAbsSetup, uintptr(unsafe.Pointer(&x))) != nil ||
		ioctlFile(file, uiAbsSetup, uintptr(unsafe.Pointer(&y))) != nil {
		return fail()
	}
	setup := uinputSetup{BusType: 0x06, Vendor: 0x1d6b, Product: 0x0105, Version: 1}
	copy(setup.Name[:], "EZVM Absolute Pointer")
	if ioctlFile(file, uiDevSetup, uintptr(unsafe.Pointer(&setup))) != nil ||
		ioctlFile(file, uiDevCreate, 0) != nil {
		return fail()
	}
	return file
}
