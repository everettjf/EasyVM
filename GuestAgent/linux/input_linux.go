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
	keyboardFile *os.File
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
	device := &uinputDevice{keyboardFile: createKeyboardAndRelativePointer()}
	if device.keyboardFile == nil {
		_ = device.Close()
		return &uinputDevice{}
	}
	device.absoluteFile = createAbsolutePointer()
	return device
}

func (device *uinputDevice) Available() bool { return device != nil && device.keyboardFile != nil }

func (device *uinputDevice) AbsolutePointerAvailable() bool {
	return device != nil && device.keyboardFile != nil && device.absoluteFile != nil
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
		file := device.keyboardFile
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
	if device == nil {
		return nil
	}
	if device.absoluteFile != nil {
		_ = ioctlFile(device.absoluteFile, uiDevDestroy, 0)
		_ = device.absoluteFile.Close()
		device.absoluteFile = nil
	}
	if device.keyboardFile != nil {
		_ = ioctlFile(device.keyboardFile, uiDevDestroy, 0)
		err := device.keyboardFile.Close()
		device.keyboardFile = nil
		return err
	}
	return nil
}

func ioctlFile(file *os.File, request, argument uintptr) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, file.Fd(), request, argument)
	if errno != 0 {
		return errno
	}
	return nil
}

func createKeyboardAndRelativePointer() *os.File {
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
		ioctlFile(file, uiSetEVBit, 2) != nil {
		return fail()
	}
	for _, code := range []uintptr{0, 1, 6, 8, 11, 12} {
		if ioctlFile(file, uiSetRelBit, code) != nil {
			return fail()
		}
	}
	for code := uintptr(1); code <= 0xff; code++ {
		if ioctlFile(file, uiSetKeyBit, code) != nil {
			return fail()
		}
	}
	for _, code := range []uintptr{272, 273, 274} {
		if ioctlFile(file, uiSetKeyBit, code) != nil {
			return fail()
		}
	}
	setup := uinputSetup{BusType: 0x06, Vendor: 0x1d6b, Product: 0x0104, Version: 2}
	copy(setup.Name[:], "EZVM Keyboard and Pointer")
	if ioctlFile(file, uiDevSetup, uintptr(unsafe.Pointer(&setup))) != nil ||
		ioctlFile(file, uiDevCreate, 0) != nil {
		return fail()
	}
	return file
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
