package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestOwnerProvisioningStagesPrivateOneShotRequest(t *testing.T) {
	pending, destination, zoneinfo := ownerProvisioningFixture(t)
	request := validOwnerProvisioningRequest()
	payload, err := json.Marshal(request)
	if err != nil {
		t.Fatal(err)
	}
	result := handleOwnerProvisioningAt(payload, pending, destination, zoneinfo)
	if !result.Success {
		t.Fatal(result.Message)
	}
	info, err := os.Stat(destination)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("provisioning request mode = %o", info.Mode().Perm())
	}
	var staged ownerProvisioningRequest
	data, err := os.ReadFile(destination)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &staged); err != nil {
		t.Fatal(err)
	}
	if staged != request {
		t.Fatalf("staged request = %#v", staged)
	}

	request.Username = "second"
	payload, _ = json.Marshal(request)
	if second := handleOwnerProvisioningAt(payload, pending, destination, zoneinfo); second.Success {
		t.Fatal("second owner provisioning request replaced the first")
	}
	data, _ = os.ReadFile(destination)
	if err := json.Unmarshal(data, &staged); err != nil || staged.Username != "omarchy" {
		t.Fatalf("original request was not preserved: %#v, %v", staged, err)
	}
}

func TestOwnerProvisioningRequiresRegularPendingMarker(t *testing.T) {
	directory := t.TempDir()
	zoneinfo := filepath.Join(directory, "zoneinfo")
	if err := os.Mkdir(zoneinfo, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(zoneinfo, "UTC"), []byte("zone"), 0600); err != nil {
		t.Fatal(err)
	}
	payload, _ := json.Marshal(validOwnerProvisioningRequest())
	pending := filepath.Join(directory, "pending")
	destination := filepath.Join(directory, "request.json")
	if result := handleOwnerProvisioningAt(payload, pending, destination, zoneinfo); result.Success {
		t.Fatal("missing pending marker was accepted")
	}
	if err := os.Symlink(filepath.Join(zoneinfo, "UTC"), pending); err != nil {
		t.Fatal(err)
	}
	if result := handleOwnerProvisioningAt(payload, pending, destination, zoneinfo); result.Success {
		t.Fatal("symlink pending marker was accepted")
	}
}

func TestOwnerProvisioningValidationRejectsUnsafeFields(t *testing.T) {
	_, _, zoneinfo := ownerProvisioningFixture(t)
	outside := filepath.Join(filepath.Dir(zoneinfo), "outside")
	if err := os.WriteFile(outside, []byte("zone"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(zoneinfo, "Escape")); err != nil {
		t.Fatal(err)
	}
	for name, mutate := range map[string]func(*ownerProvisioningRequest){
		"schema":        func(value *ownerProvisioningRequest) { value.SchemaVersion = 2 },
		"username":      func(value *ownerProvisioningRequest) { value.Username = "Bad User" },
		"reserved user": func(value *ownerProvisioningRequest) { value.Username = "root" },
		"password":      func(value *ownerProvisioningRequest) { value.Password = "bad\nsecret" },
		"keyboard":      func(value *ownerProvisioningRequest) { value.Keyboard = "us;reboot" },
		"identity":      func(value *ownerProvisioningRequest) { value.FullName = "Name\tInjected" },
		"hostname":      func(value *ownerProvisioningRequest) { value.Hostname = "-omarchy" },
		"timezone path": func(value *ownerProvisioningRequest) { value.Timezone = "../UTC" },
		"timezone link": func(value *ownerProvisioningRequest) { value.Timezone = "Escape" },
	} {
		t.Run(name, func(t *testing.T) {
			request := validOwnerProvisioningRequest()
			mutate(&request)
			if err := validateOwnerProvisioning(request, zoneinfo); err == nil {
				t.Fatal("unsafe owner provisioning request was accepted")
			}
		})
	}
}

func ownerProvisioningFixture(t *testing.T) (string, string, string) {
	t.Helper()
	directory := t.TempDir()
	pending := filepath.Join(directory, "pending")
	destination := filepath.Join(directory, "request.json")
	zoneinfo := filepath.Join(directory, "zoneinfo")
	if err := os.Mkdir(zoneinfo, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(pending, nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(zoneinfo, "UTC"), []byte("zone"), 0600); err != nil {
		t.Fatal(err)
	}
	return pending, destination, zoneinfo
}

func validOwnerProvisioningRequest() ownerProvisioningRequest {
	return ownerProvisioningRequest{
		SchemaVersion: 1,
		Username:      "omarchy",
		Password:      "temporary-password",
		Keyboard:      "us",
		FullName:      "Omarchy Owner",
		EmailAddress:  "owner@example.com",
		Hostname:      "omarchy",
		Timezone:      "UTC",
	}
}
