package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const fileChunkBytes = 512 * 1024
const maximumTransferBytes uint64 = 64 * 1024 * 1024 * 1024

type uploadStart struct {
	TransferID      string `json:"transferID"`
	DestinationPath string `json:"destinationPath"`
	TotalBytes      uint64 `json:"totalBytes"`
	SHA256          string `json:"sha256"`
	Overwrite       bool   `json:"overwrite"`
}

type uploadChunk struct {
	TransferID string `json:"transferID"`
	Offset     uint64 `json:"offset"`
	Data       []byte `json:"data"`
}

type transferID struct {
	TransferID string `json:"transferID"`
}

type downloadInfoRequest struct {
	TransferID string `json:"transferID"`
	SourcePath string `json:"sourcePath"`
}

type downloadChunkRequest struct {
	TransferID string `json:"transferID"`
	Offset     uint64 `json:"offset"`
	Length     int    `json:"length"`
}

type transferResult struct {
	TransferID       string  `json:"transferID"`
	Success          bool    `json:"success"`
	TransferredBytes uint64  `json:"transferredBytes"`
	Message          string  `json:"message"`
	TotalBytes       *uint64 `json:"totalBytes,omitempty"`
	SHA256           string  `json:"sha256,omitempty"`
	Offset           *uint64 `json:"offset,omitempty"`
	Data             []byte  `json:"data,omitempty"`
	EOF              *bool   `json:"eof,omitempty"`
}

type uploadState struct {
	file        *os.File
	temporary   string
	destination string
	total       uint64
	written     uint64
	sha256      string
	overwrite   bool
	hash        hash.Hash
}

type downloadState struct {
	file   *os.File
	total  uint64
	sha256 string
}

type transferSession struct {
	uploads   map[string]*uploadState
	downloads map[string]*downloadState
}

func newTransferSession() *transferSession {
	return &transferSession{uploads: map[string]*uploadState{}, downloads: map[string]*downloadState{}}
}

func (session *transferSession) close() {
	for id, state := range session.uploads {
		state.file.Close()
		os.Remove(state.temporary)
		delete(session.uploads, id)
	}
	for id, state := range session.downloads {
		state.file.Close()
		delete(session.downloads, id)
	}
}

func (session *transferSession) handle(operation string, payload []byte) transferResult {
	var result transferResult
	var err error
	switch operation {
	case "uploadStart":
		var value uploadStart
		if err = json.Unmarshal(payload, &value); err == nil {
			result, err = session.startUpload(value)
		}
		if result.TransferID == "" {
			result.TransferID = value.TransferID
		}
	case "uploadChunk":
		var value uploadChunk
		if err = json.Unmarshal(payload, &value); err == nil {
			result, err = session.writeUpload(value)
		}
		if result.TransferID == "" {
			result.TransferID = value.TransferID
		}
	case "uploadCommit":
		var value transferID
		if err = json.Unmarshal(payload, &value); err == nil {
			result, err = session.commitUpload(value.TransferID)
		}
		if result.TransferID == "" {
			result.TransferID = value.TransferID
		}
	case "transferCancel":
		var value transferID
		if err = json.Unmarshal(payload, &value); err == nil {
			result = session.cancel(value.TransferID)
		}
		if result.TransferID == "" {
			result.TransferID = value.TransferID
		}
	case "downloadInfo":
		var value downloadInfoRequest
		if err = json.Unmarshal(payload, &value); err == nil {
			result, err = session.startDownload(value)
		}
		if result.TransferID == "" {
			result.TransferID = value.TransferID
		}
	case "downloadChunk":
		var value downloadChunkRequest
		if err = json.Unmarshal(payload, &value); err == nil {
			result, err = session.readDownload(value)
		}
		if result.TransferID == "" {
			result.TransferID = value.TransferID
		}
	default:
		err = errors.New("unsupported transfer operation")
	}
	if err != nil {
		result.Success = false
		result.Message = err.Error()
	}
	return result
}

func (session *transferSession) startUpload(value uploadStart) (transferResult, error) {
	if err := validateTransferID(value.TransferID); err != nil {
		return transferResult{}, err
	}
	if _, exists := session.uploads[value.TransferID]; exists {
		return transferResult{}, errors.New("transfer already exists")
	}
	if value.TotalBytes > maximumTransferBytes || !validSHA256(value.SHA256) {
		return transferResult{}, errors.New("invalid upload size or checksum")
	}
	if err := validateGuestPath(value.DestinationPath, false); err != nil {
		return transferResult{}, err
	}
	if existing, err := os.Lstat(value.DestinationPath); err == nil {
		if existing.Mode()&os.ModeSymlink != 0 || existing.IsDir() {
			return transferResult{}, errors.New("destination is not a regular file")
		}
		if !value.Overwrite {
			return transferResult{}, errors.New("destination already exists")
		}
	} else if !os.IsNotExist(err) {
		return transferResult{}, err
	}
	parent := filepath.Dir(value.DestinationPath)
	temporary, err := os.CreateTemp(parent, ".easyvm-upload-*")
	if err != nil {
		return transferResult{}, err
	}
	if err := temporary.Chmod(0600); err != nil {
		temporary.Close()
		os.Remove(temporary.Name())
		return transferResult{}, err
	}
	session.uploads[value.TransferID] = &uploadState{
		file: temporary, temporary: temporary.Name(), destination: value.DestinationPath,
		total: value.TotalBytes, sha256: strings.ToLower(value.SHA256), overwrite: value.Overwrite, hash: sha256.New(),
	}
	return transferResult{TransferID: value.TransferID, Success: true, Message: "ready", TotalBytes: &value.TotalBytes}, nil
}

func (session *transferSession) writeUpload(value uploadChunk) (transferResult, error) {
	state := session.uploads[value.TransferID]
	if state == nil {
		return transferResult{}, errors.New("unknown upload")
	}
	if value.Offset != state.written || len(value.Data) > fileChunkBytes || state.written+uint64(len(value.Data)) > state.total {
		return transferResult{}, errors.New("invalid upload chunk")
	}
	if _, err := state.file.Write(value.Data); err != nil {
		session.abortUpload(value.TransferID)
		return transferResult{}, err
	}
	state.hash.Write(value.Data)
	state.written += uint64(len(value.Data))
	return transferResult{TransferID: value.TransferID, Success: true, TransferredBytes: state.written, Message: "chunk accepted"}, nil
}

func (session *transferSession) commitUpload(id string) (transferResult, error) {
	state := session.uploads[id]
	if state == nil {
		return transferResult{}, errors.New("unknown upload")
	}
	if state.written != state.total || hex.EncodeToString(state.hash.Sum(nil)) != state.sha256 {
		session.abortUpload(id)
		return transferResult{}, errors.New("upload size or checksum mismatch")
	}
	if err := state.file.Sync(); err != nil {
		session.abortUpload(id)
		return transferResult{}, err
	}
	if err := state.file.Close(); err != nil {
		session.abortUpload(id)
		return transferResult{}, err
	}
	if !state.overwrite {
		if _, err := os.Lstat(state.destination); err == nil {
			os.Remove(state.temporary)
			delete(session.uploads, id)
			return transferResult{}, errors.New("destination appeared during upload")
		}
	}
	if err := os.Rename(state.temporary, state.destination); err != nil {
		os.Remove(state.temporary)
		delete(session.uploads, id)
		return transferResult{}, err
	}
	delete(session.uploads, id)
	return transferResult{TransferID: id, Success: true, TransferredBytes: state.written, Message: "committed"}, nil
}

func (session *transferSession) startDownload(value downloadInfoRequest) (transferResult, error) {
	if err := validateTransferID(value.TransferID); err != nil {
		return transferResult{}, err
	}
	if _, exists := session.downloads[value.TransferID]; exists {
		return transferResult{}, errors.New("transfer already exists")
	}
	if err := validateGuestPath(value.SourcePath, true); err != nil {
		return transferResult{}, err
	}
	file, err := os.Open(value.SourcePath)
	if err != nil {
		return transferResult{}, err
	}
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || uint64(info.Size()) > maximumTransferBytes {
		file.Close()
		return transferResult{}, errors.New("source is not a transferable regular file")
	}
	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		file.Close()
		return transferResult{}, err
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		file.Close()
		return transferResult{}, err
	}
	total := uint64(info.Size())
	checksum := hex.EncodeToString(digest.Sum(nil))
	session.downloads[value.TransferID] = &downloadState{file: file, total: total, sha256: checksum}
	return transferResult{
		TransferID: value.TransferID, Success: true, Message: "ready",
		TotalBytes: &total, SHA256: checksum,
	}, nil
}

func (session *transferSession) readDownload(value downloadChunkRequest) (transferResult, error) {
	state := session.downloads[value.TransferID]
	if state == nil {
		return transferResult{}, errors.New("unknown download")
	}
	if value.Length <= 0 || value.Length > fileChunkBytes || value.Offset > state.total {
		return transferResult{}, errors.New("invalid download chunk")
	}
	buffer := make([]byte, value.Length)
	count, err := state.file.ReadAt(buffer, int64(value.Offset))
	if err != nil && !errors.Is(err, io.EOF) {
		return transferResult{}, err
	}
	buffer = buffer[:count]
	eof := value.Offset+uint64(count) >= state.total
	offset := value.Offset
	result := transferResult{
		TransferID: value.TransferID, Success: true, TransferredBytes: value.Offset + uint64(count),
		Message: "chunk", Offset: &offset, Data: buffer, EOF: &eof,
	}
	if eof {
		state.file.Close()
		delete(session.downloads, value.TransferID)
	}
	return result, nil
}

func (session *transferSession) cancel(id string) transferResult {
	found := false
	if _, exists := session.uploads[id]; exists {
		session.abortUpload(id)
		found = true
	}
	if state := session.downloads[id]; state != nil {
		state.file.Close()
		delete(session.downloads, id)
		found = true
	}
	if !found {
		return transferResult{TransferID: id, Success: false, Message: "unknown transfer"}
	}
	return transferResult{TransferID: id, Success: true, Message: "cancelled"}
}

func (session *transferSession) abortUpload(id string) {
	if state := session.uploads[id]; state != nil {
		state.file.Close()
		os.Remove(state.temporary)
		delete(session.uploads, id)
	}
}

func validateTransferID(id string) error {
	if len(id) != 36 {
		return errors.New("invalid transfer identifier")
	}
	for index, value := range id {
		if index == 8 || index == 13 || index == 18 || index == 23 {
			if value != '-' {
				return errors.New("invalid transfer identifier")
			}
		} else if !strings.ContainsRune("0123456789abcdefABCDEF", value) {
			return errors.New("invalid transfer identifier")
		}
	}
	return nil
}

func validSHA256(value string) bool {
	if len(value) != sha256.Size*2 {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}

func validateGuestPath(path string, mustExist bool) error {
	if path == "" || strings.ContainsRune(path, 0) || !filepath.IsAbs(path) || filepath.Clean(path) != path || path == "/" {
		return errors.New("guest path must be a clean absolute file path")
	}
	current := string(filepath.Separator)
	parts := strings.Split(strings.TrimPrefix(path, current), current)
	for index, part := range parts {
		current = filepath.Join(current, part)
		info, err := os.Lstat(current)
		if os.IsNotExist(err) && index == len(parts)-1 && !mustExist {
			return nil
		}
		if err != nil {
			return fmt.Errorf("inspect guest path: %w", err)
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return errors.New("symbolic links are not allowed in guest transfer paths")
		}
	}
	return nil
}
