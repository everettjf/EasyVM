package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

const transferTestID = "11111111-2222-3333-4444-555555555555"

func resolvedTempDir(t *testing.T) string {
	t.Helper()
	path, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return path
}

func checksum(data []byte) string {
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:])
}

func TestUploadCommitsAtomicallyWithChecksumAndPrivateMode(t *testing.T) {
	directory := resolvedTempDir(t)
	destination := filepath.Join(directory, "uploaded.bin")
	content := bytes.Repeat([]byte("ezvm-transfer"), 80_000)
	session := newTransferSession()
	defer session.close()

	result := session.handle("uploadStart", mustJSON(t, uploadStart{
		TransferID: transferTestID, DestinationPath: destination, TotalBytes: uint64(len(content)),
		SHA256: checksum(content), Overwrite: false,
	}))
	if !result.Success {
		t.Fatal(result.Message)
	}
	for offset := 0; offset < len(content); offset += fileChunkBytes {
		end := offset + fileChunkBytes
		if end > len(content) {
			end = len(content)
		}
		result = session.handle("uploadChunk", mustJSON(t, uploadChunk{
			TransferID: transferTestID, Offset: uint64(offset), Data: content[offset:end],
		}))
		if !result.Success {
			t.Fatal(result.Message)
		}
	}
	result = session.handle("uploadCommit", mustJSON(t, transferID{TransferID: transferTestID}))
	if !result.Success || result.TransferredBytes != uint64(len(content)) {
		t.Fatalf("commit failed: %#v", result)
	}
	written, err := os.ReadFile(destination)
	if err != nil || !bytes.Equal(written, content) {
		t.Fatal("committed content differs")
	}
	info, err := os.Stat(destination)
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("unexpected destination mode: %v", info.Mode())
	}
	if matches, _ := filepath.Glob(filepath.Join(directory, ".ezvm-upload-*")); len(matches) != 0 {
		t.Fatalf("temporary files remain: %v", matches)
	}
}

func TestUploadRejectsOverwriteOutOfOrderAndChecksumMismatch(t *testing.T) {
	directory := resolvedTempDir(t)
	destination := filepath.Join(directory, "existing.txt")
	if err := os.WriteFile(destination, []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	session := newTransferSession()
	defer session.close()
	content := []byte("replacement")

	result := session.handle("uploadStart", mustJSON(t, uploadStart{
		TransferID: transferTestID, DestinationPath: destination, TotalBytes: uint64(len(content)),
		SHA256: checksum(content), Overwrite: false,
	}))
	if result.Success {
		t.Fatal("existing destination was overwritten without permission")
	}

	result = session.handle("uploadStart", mustJSON(t, uploadStart{
		TransferID: transferTestID, DestinationPath: destination, TotalBytes: uint64(len(content)),
		SHA256: checksum([]byte("different")), Overwrite: true,
	}))
	if !result.Success {
		t.Fatal(result.Message)
	}
	if result = session.handle("uploadChunk", mustJSON(t, uploadChunk{
		TransferID: transferTestID, Offset: 1, Data: content,
	})); result.Success {
		t.Fatal("out-of-order chunk accepted")
	}
	if result = session.handle("uploadChunk", mustJSON(t, uploadChunk{
		TransferID: transferTestID, Offset: 0, Data: content,
	})); !result.Success {
		t.Fatal(result.Message)
	}
	if result = session.handle("uploadCommit", mustJSON(t, transferID{TransferID: transferTestID})); result.Success {
		t.Fatal("checksum mismatch accepted")
	}
	written, _ := os.ReadFile(destination)
	if string(written) != "original" {
		t.Fatal("failed upload changed existing destination")
	}
}

func TestDownloadReportsChecksumAndReturnsBoundedChunks(t *testing.T) {
	directory := resolvedTempDir(t)
	source := filepath.Join(directory, "source.bin")
	content := bytes.Repeat([]byte("download"), 100_000)
	if err := os.WriteFile(source, content, 0600); err != nil {
		t.Fatal(err)
	}
	session := newTransferSession()
	defer session.close()

	result := session.handle("downloadInfo", mustJSON(t, downloadInfoRequest{TransferID: transferTestID, SourcePath: source}))
	if !result.Success || result.TotalBytes == nil || *result.TotalBytes != uint64(len(content)) || result.SHA256 != checksum(content) {
		t.Fatalf("bad download info: %#v", result)
	}
	var received []byte
	for offset := 0; ; offset = len(received) {
		result = session.handle("downloadChunk", mustJSON(t, downloadChunkRequest{
			TransferID: transferTestID, Offset: uint64(offset), Length: fileChunkBytes,
		}))
		if !result.Success || result.Offset == nil || *result.Offset != uint64(offset) || result.EOF == nil {
			t.Fatalf("bad chunk: %#v", result)
		}
		received = append(received, result.Data...)
		if *result.EOF {
			break
		}
	}
	if !bytes.Equal(received, content) {
		t.Fatal("downloaded content differs")
	}
	if result = session.handle("downloadChunk", mustJSON(t, downloadChunkRequest{
		TransferID: transferTestID, Offset: uint64(len(content)), Length: 1,
	})); result.Success {
		t.Fatal("completed download remained open")
	}
}

func TestTransfersRejectSymlinksTraversalAndOversizedChunks(t *testing.T) {
	directory := resolvedTempDir(t)
	realFile := filepath.Join(directory, "real")
	link := filepath.Join(directory, "link")
	if err := os.WriteFile(realFile, []byte("secret"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(realFile, link); err != nil {
		t.Fatal(err)
	}
	session := newTransferSession()
	defer session.close()
	if result := session.handle("downloadInfo", mustJSON(t, downloadInfoRequest{TransferID: transferTestID, SourcePath: link})); result.Success {
		t.Fatal("symbolic-link download accepted")
	}
	if result := session.handle("downloadInfo", mustJSON(t, downloadInfoRequest{TransferID: transferTestID, SourcePath: directory + "/../escape"})); result.Success {
		t.Fatal("unclean path accepted")
	}
	if result := session.handle("uploadStart", mustJSON(t, uploadStart{
		TransferID: transferTestID, DestinationPath: filepath.Join(directory, "new"), TotalBytes: maximumTransferBytes + 1,
		SHA256: checksum(nil),
	})); result.Success {
		t.Fatal("oversized transfer accepted")
	}
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return data
}
