package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"runtime"
	"sort"
	"strings"
	"syscall"
)

const protocolVersion = 1
const maxFrameBytes = 1024 * 1024
const guestAgentPort = 10240
const vmaddrCIDAny = 0xffffffff

var version = "dev"

type enrollment struct {
	SchemaVersion int    `json:"schemaVersion"`
	MachineID     string `json:"machineID"`
	Token         []byte `json:"token"`
	Port          uint32 `json:"port"`
}

type hello struct {
	Version    int    `json:"version"`
	MachineID  string `json:"machineID"`
	GuestNonce string `json:"guestNonce"`
	Proof      string `json:"proof"`
}

type welcome struct {
	Version   int    `json:"version"`
	HostNonce string `json:"hostNonce"`
	Proof     string `json:"proof"`
}

type envelope struct {
	Version   int    `json:"version"`
	SessionID string `json:"sessionID"`
	Sequence  uint64 `json:"sequence"`
	RequestID string `json:"requestID"`
	Operation string `json:"operation"`
	Payload   []byte `json:"payload"`
	Proof     string `json:"proof"`
}

type status struct {
	AgentVersion    string   `json:"agentVersion"`
	OperatingSystem string   `json:"operatingSystem"`
	KernelVersion   string   `json:"kernelVersion"`
	HostName        string   `json:"hostName"`
	Addresses       []string `json:"addresses"`
	BootID          string   `json:"bootID"`
	UptimeSeconds   uint64   `json:"uptimeSeconds"`
	Capabilities    []string `json:"capabilities,omitempty"`
	KVMAvailable    bool     `json:"kvmAvailable"`
	KVMAPIVersion   int      `json:"kvmAPIVersion,omitempty"`
	KVMError        string   `json:"kvmError,omitempty"`
}

func main() {
	configPath := flag.String("config", "/etc/ezvm-agent/config.json", "enrollment configuration")
	flag.Parse()
	configuration, err := loadEnrollment(*configPath)
	if err != nil {
		log.Fatal(err)
	}
	fd, err := listenVSock(configuration.Port)
	if err != nil {
		log.Fatalf("listen on AF_VSOCK port %d: %v", configuration.Port, err)
	}
	defer closeSocket(fd)
	log.Printf("EZVM guest agent %s listening on AF_VSOCK port %d", version, configuration.Port)
	for {
		connection, err := acceptSocket(fd)
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		go func() {
			defer closeSocket(connection)
			if err := serve(fdStream{connection}, configuration); err != nil {
				log.Printf("session closed: %v", err)
			}
		}()
	}
}

func loadEnrollment(path string) (enrollment, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return enrollment{}, fmt.Errorf("read enrollment: %w", err)
	}
	var value enrollment
	if err := json.Unmarshal(data, &value); err != nil {
		return enrollment{}, fmt.Errorf("decode enrollment: %w", err)
	}
	if value.SchemaVersion != 1 || len(value.Token) != 32 || value.MachineID == "" || value.Port != guestAgentPort {
		return enrollment{}, errors.New("invalid enrollment configuration")
	}
	return value, nil
}

func serve(stream io.ReadWriter, config enrollment) error {
	input := newGuestInput()
	defer input.Close()
	return serveWithInput(stream, config, input)
}

func serveWithInput(stream io.ReadWriter, config enrollment, input guestInput) error {
	transfers := newTransferSession()
	defer transfers.close()
	guestNonceBytes := make([]byte, 32)
	if _, err := rand.Read(guestNonceBytes); err != nil {
		return err
	}
	guestNonce := base64.StdEncoding.EncodeToString(guestNonceBytes)
	helloValue := hello{Version: protocolVersion, MachineID: config.MachineID, GuestNonce: guestNonce}
	helloValue.Proof = sign(config.Token, fmt.Sprintf("guest|%d|%s|%s", protocolVersion, config.MachineID, guestNonce))
	if err := writeFrame(stream, helloValue); err != nil {
		return err
	}

	var welcomeValue welcome
	if err := readFrame(stream, &welcomeValue); err != nil {
		return err
	}
	if welcomeValue.Version != protocolVersion {
		return errors.New("unsupported host protocol version")
	}
	expectedWelcome := sign(config.Token, fmt.Sprintf("host|%d|%s|%s|%s", protocolVersion, config.MachineID, guestNonce, welcomeValue.HostNonce))
	if !secureEqual(expectedWelcome, welcomeValue.Proof) {
		return errors.New("host authentication failed")
	}
	sessionDigest := sha256.Sum256([]byte(fmt.Sprintf("session|%s|%s|%s", config.MachineID, guestNonce, welcomeValue.HostNonce)))
	sessionID := base64.StdEncoding.EncodeToString(sessionDigest[:])
	var receivedSequence, sentSequence uint64
	for {
		var request envelope
		if err := readFrame(stream, &request); err != nil {
			return err
		}
		if err := verifyEnvelope(config.Token, sessionID, request, receivedSequence); err != nil {
			return err
		}
		receivedSequence = request.Sequence
		switch request.Operation {
		case "heartbeat", "status":
			payload, err := json.Marshal(currentStatus(input.Available(), input.AbsolutePointerAvailable()))
			if err != nil {
				return err
			}
			sentSequence++
			response := makeEnvelope(config.Token, sessionID, sentSequence, request.RequestID, request.Operation, payload)
			if err := writeFrame(stream, response); err != nil {
				return err
			}
		case "shutdown", "restart":
			sentSequence++
			response := makeEnvelope(config.Token, sessionID, sentSequence, request.RequestID, request.Operation, []byte{})
			if err := writeFrame(stream, response); err != nil {
				return err
			}
			go power(request.Operation)
		case "uploadStart", "uploadChunk", "uploadCommit", "transferCancel", "downloadInfo", "downloadChunk":
			result := transfers.handle(request.Operation, request.Payload)
			payload, err := json.Marshal(result)
			if err != nil {
				return err
			}
			sentSequence++
			response := makeEnvelope(config.Token, sessionID, sentSequence, request.RequestID, request.Operation, payload)
			if err := writeFrame(stream, response); err != nil {
				return err
			}
		case "input":
			result := handleInput(input, request.Payload)
			payload, err := json.Marshal(result)
			if err != nil {
				return err
			}
			sentSequence++
			response := makeEnvelope(config.Token, sessionID, sentSequence, request.RequestID, request.Operation, payload)
			if err := writeFrame(stream, response); err != nil {
				return err
			}
		default:
			return errors.New("unsupported operation")
		}
	}
}

func makeEnvelope(token []byte, sessionID string, sequence uint64, requestID, operation string, payload []byte) envelope {
	value := envelope{Version: protocolVersion, SessionID: sessionID, Sequence: sequence, RequestID: requestID, Operation: operation, Payload: payload}
	value.Proof = sign(token, envelopeText(value))
	return value
}

func verifyEnvelope(token []byte, sessionID string, value envelope, lastSequence uint64) error {
	if value.Version != protocolVersion || value.SessionID != sessionID {
		return errors.New("invalid session")
	}
	if value.Sequence <= lastSequence {
		return errors.New("replayed sequence")
	}
	if len(value.Payload) > maxFrameBytes {
		return errors.New("oversized payload")
	}
	if !secureEqual(sign(token, envelopeText(value)), value.Proof) {
		return errors.New("invalid message proof")
	}
	return nil
}

func envelopeText(value envelope) string {
	return fmt.Sprintf("message|%d|%s|%d|%s|%s|%s", value.Version, value.SessionID, value.Sequence, value.RequestID, value.Operation, base64.StdEncoding.EncodeToString(value.Payload))
}

func sign(token []byte, text string) string {
	mac := hmac.New(sha256.New, token)
	mac.Write([]byte(text))
	return base64.StdEncoding.EncodeToString(mac.Sum(nil))
}

func secureEqual(first, second string) bool {
	a, errA := base64.StdEncoding.DecodeString(first)
	b, errB := base64.StdEncoding.DecodeString(second)
	return errA == nil && errB == nil && len(a) == len(b) && subtle.ConstantTimeCompare(a, b) == 1
}

func writeFrame(writer io.Writer, value any) error {
	payload, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if len(payload) > maxFrameBytes {
		return errors.New("frame too large")
	}
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], uint32(len(payload)))
	if _, err := writer.Write(header[:]); err != nil {
		return err
	}
	_, err = writer.Write(payload)
	return err
}

func readFrame(reader io.Reader, value any) error {
	var header [4]byte
	if _, err := io.ReadFull(reader, header[:]); err != nil {
		return err
	}
	length := binary.BigEndian.Uint32(header[:])
	if length > maxFrameBytes {
		return errors.New("frame too large")
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(reader, payload); err != nil {
		return err
	}
	return json.Unmarshal(payload, value)
}

func currentStatus(inputAvailable, absolutePointerAvailable bool) status {
	hostName, _ := os.Hostname()
	addresses := []string{}
	interfaces, _ := net.Interfaces()
	for _, iface := range interfaces {
		items, _ := iface.Addrs()
		for _, item := range items {
			address := strings.Split(item.String(), "/")[0]
			ip := net.ParseIP(address)
			if ip != nil && !ip.IsLoopback() && !ip.IsLinkLocalUnicast() {
				addresses = append(addresses, address)
			}
		}
	}
	sort.Strings(addresses)
	kvmAvailable, kvmVersion, kvmError := kvmStatus()
	capabilities := []string{"file-transfer-v1", "ssh-addresses-v1", "kvm-diagnostics-v1"}
	if inputAvailable {
		capabilities = append(capabilities, "input-uinput-v1")
	}
	if absolutePointerAvailable {
		capabilities = append(capabilities, "input-uinput-absolute-v1")
	}
	return status{AgentVersion: version, OperatingSystem: osName(), KernelVersion: kernelVersion(), HostName: hostName, Addresses: addresses, BootID: readTrimmed("/proc/sys/kernel/random/boot_id"), UptimeSeconds: uptime(), Capabilities: capabilities, KVMAvailable: kvmAvailable, KVMAPIVersion: kvmVersion, KVMError: kvmError}
}

func kvmStatus() (bool, int, string) {
	file, err := os.OpenFile("/dev/kvm", os.O_RDWR, 0)
	if err != nil {
		return false, 0, err.Error()
	}
	defer file.Close()
	// KVM_GET_API_VERSION is _IO(KVMIO, 0x00), or 0xAE00 on Linux.
	version, _, errno := syscall.Syscall(syscall.SYS_IOCTL, file.Fd(), uintptr(0xAE00), 0)
	if errno != 0 {
		return false, 0, errno.Error()
	}
	if version != 12 {
		return false, int(version), fmt.Sprintf("unexpected KVM API version %d", version)
	}
	return true, int(version), ""
}

func osName() string {
	data, _ := os.ReadFile("/etc/os-release")
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "PRETTY_NAME=") {
			return strings.Trim(strings.TrimPrefix(line, "PRETTY_NAME="), "\"")
		}
	}
	return runtime.GOOS
}

func kernelVersion() string {
	data, err := os.ReadFile("/proc/sys/kernel/osrelease")
	if err == nil {
		return strings.TrimSpace(string(data))
	}
	return "unknown"
}

func uptime() uint64 {
	data, _ := os.ReadFile("/proc/uptime")
	var seconds float64
	fmt.Sscanf(string(data), "%f", &seconds)
	return uint64(seconds)
}

func readTrimmed(path string) string {
	data, _ := os.ReadFile(path)
	return strings.TrimSpace(string(data))
}
