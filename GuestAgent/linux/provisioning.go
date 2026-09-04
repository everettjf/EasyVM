package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode"
)

const ownerProvisioningCapability = "owner-provisioning-v1"

var (
	ownerUsernamePattern   = regexp.MustCompile(`^[a-z_][a-z0-9_-]*[$]?$`)
	ownerHostnamePattern   = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$`)
	ownerKeyboardPattern   = regexp.MustCompile(`^[A-Za-z0-9_-]{1,32}$`)
	ownerTimezonePattern   = regexp.MustCompile(`^[A-Za-z0-9_+.-]+(?:/[A-Za-z0-9_+.-]+)*$`)
	ownerReservedUsernames = map[string]struct{}{
		"root": {}, "bin": {}, "daemon": {}, "mail": {}, "ftp": {}, "http": {}, "nobody": {},
		"dbus": {}, "systemd-coredump": {}, "systemd-network": {}, "systemd-oom": {},
		"systemd-journal-remote": {}, "systemd-resolve": {}, "systemd-timesync": {}, "tss": {},
		"uuidd": {}, "alpm": {}, "git": {}, "avahi": {}, "cups": {}, "cups-browsed": {}, "lp": {},
		"_talkd": {}, "polkitd": {}, "rtkit": {}, "qemu": {}, "brltty": {}, "gluster": {}, "rpc": {},
		"libvirt-qemu": {}, "pcscd": {}, "nvidia-persistenced": {}, "sddm": {},
	}
)

type ownerProvisioningRequest struct {
	SchemaVersion int    `json:"schemaVersion"`
	Username      string `json:"username"`
	Password      string `json:"password"`
	Keyboard      string `json:"keyboard"`
	FullName      string `json:"fullName,omitempty"`
	EmailAddress  string `json:"emailAddress,omitempty"`
	Hostname      string `json:"hostname"`
	Timezone      string `json:"timezone"`
}

func ownerProvisioningAvailable(pendingPath string) bool {
	info, err := os.Lstat(pendingPath)
	return err == nil && info.Mode().IsRegular()
}

func handleOwnerProvisioning(payload []byte) inputResult {
	return handleOwnerProvisioningAt(
		payload,
		"/var/lib/omarchy/provisioning/pending",
		"/run/ezvm-owner-provisioning.json",
		"/usr/share/zoneinfo",
	)
}

func handleOwnerProvisioningAt(payload []byte, pendingPath, destination, zoneinfoRoot string) inputResult {
	if !ownerProvisioningAvailable(pendingPath) {
		return inputResult{Success: false, Message: "Owner provisioning is not pending."}
	}
	var request ownerProvisioningRequest
	decoder := json.NewDecoder(bytes.NewReader(payload))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		return inputResult{Success: false, Message: "Owner provisioning payload is invalid."}
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return inputResult{Success: false, Message: "Owner provisioning payload is invalid."}
	}
	if err := validateOwnerProvisioning(request, zoneinfoRoot); err != nil {
		return inputResult{Success: false, Message: err.Error()}
	}
	data, err := json.Marshal(request)
	if err != nil {
		return inputResult{Success: false, Message: "Owner provisioning payload could not be encoded."}
	}
	if err := writeOncePrivate(destination, data); err != nil {
		return inputResult{Success: false, Message: "Owner provisioning request was already submitted or could not be staged."}
	}
	return inputResult{Success: true, Message: "Owner provisioning request staged."}
}

func validateOwnerProvisioning(request ownerProvisioningRequest, zoneinfoRoot string) error {
	if request.SchemaVersion != 1 {
		return errors.New("Owner provisioning schema is unsupported.")
	}
	_, reservedUsername := ownerReservedUsernames[request.Username]
	if !ownerUsernamePattern.MatchString(request.Username) || len(request.Username) > 32 || reservedUsername {
		return errors.New("Owner username is invalid.")
	}
	if len(request.Password) < 1 || len(request.Password) > 128 || containsControl(request.Password) {
		return errors.New("Owner password is invalid.")
	}
	if !ownerKeyboardPattern.MatchString(request.Keyboard) {
		return errors.New("Owner keyboard layout is invalid.")
	}
	if len(request.FullName) > 128 || containsControl(request.FullName) ||
		len(request.EmailAddress) > 254 || containsControl(request.EmailAddress) {
		return errors.New("Owner identity is invalid.")
	}
	if !ownerHostnamePattern.MatchString(request.Hostname) {
		return errors.New("Owner hostname is invalid.")
	}
	if !ownerTimezonePattern.MatchString(request.Timezone) {
		return errors.New("Owner timezone is invalid.")
	}
	zonePath := filepath.Join(zoneinfoRoot, filepath.FromSlash(request.Timezone))
	relative, err := filepath.Rel(zoneinfoRoot, zonePath)
	if err != nil || relative == "." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return errors.New("Owner timezone is invalid.")
	}
	info, err := os.Stat(zonePath)
	if err != nil || !info.Mode().IsRegular() {
		return errors.New("Owner timezone is unavailable.")
	}
	resolvedRoot, err := filepath.EvalSymlinks(zoneinfoRoot)
	if err != nil {
		return errors.New("Owner timezone is unavailable.")
	}
	resolvedZone, err := filepath.EvalSymlinks(zonePath)
	if err != nil || !pathWithin(resolvedRoot, resolvedZone) {
		return errors.New("Owner timezone is invalid.")
	}
	return nil
}

func containsControl(value string) bool {
	for _, character := range value {
		if unicode.IsControl(character) {
			return true
		}
	}
	return false
}

func pathWithin(root, candidate string) bool {
	relative, err := filepath.Rel(root, candidate)
	return err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

func writeOncePrivate(destination string, data []byte) error {
	directory := filepath.Dir(destination)
	file, err := os.CreateTemp(directory, "."+filepath.Base(destination)+".*")
	if err != nil {
		return err
	}
	temporary := file.Name()
	defer os.Remove(temporary)
	if _, err = file.Write(data); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	// link is atomic and refuses to replace an existing request.
	return os.Link(temporary, destination)
}
