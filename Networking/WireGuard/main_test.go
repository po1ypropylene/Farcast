package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/curve25519"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

func keys(t *testing.T) (string, string) {
	t.Helper()
	private := make([]byte, 32)
	if _, err := rand.Read(private); err != nil {
		t.Fatal("key generation")
	}
	public, err := curve25519.X25519(private, curve25519.Basepoint)
	if err != nil {
		t.Fatal("key derivation")
	}
	return base64.StdEncoding.EncodeToString(private), base64.StdEncoding.EncodeToString(public)
}
func fixture(t *testing.T) (request, *netstack.Net) {
	t.Helper()
	clientPrivate, clientPublic := keys(t)
	serverPrivate, serverPublic := keys(t)
	tun, stack, err := netstack.CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.111.0.1")}, nil, 1420)
	if err != nil {
		t.Fatal("fixture stack")
	}
	dev := device.NewDevice(tun, conn.NewDefaultBind(), device.NewLogger(device.LogLevelSilent, ""))
	t.Cleanup(dev.Close)
	priv, _ := key(serverPrivate)
	pub, _ := key(clientPublic)
	if err := dev.IpcSet("private_key=" + priv + "\nlisten_port=0\npublic_key=" + pub + "\nallowed_ip=10.111.0.2/32\n"); err != nil {
		t.Fatal("fixture setup")
	}
	if err := dev.Up(); err != nil {
		t.Fatal("fixture up")
	}
	ipc, err := dev.IpcGet()
	if err != nil {
		t.Fatal("fixture port")
	}
	var port string
	for _, line := range strings.Split(ipc, "\n") {
		if strings.HasPrefix(line, "listen_port=") {
			port = strings.TrimPrefix(line, "listen_port=")
		}
	}
	token := make([]byte, 32)
	rand.Read(token)
	r := request{Configuration: configuration{Addresses: "10.111.0.2/32", PublicKey: serverPublic, Endpoint: "127.0.0.1:" + port, AllowedIPs: "10.111.0.1/32", MTU: 1420}, PrivateKey: clientPrivate, Host: "10.111.0.1", Port: 3389, Token: hex.EncodeToString(token)}
	return r, stack
}
func helper(t *testing.T, r request) (int, *exec.Cmd, io.WriteCloser, *bufio.Reader) {
	t.Helper()
	path := os.Getenv("FARCAST_WG_HELPER")
	if path == "" {
		t.Fatal("helper path missing")
	}
	cmd := exec.Command(path)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal("stdin")
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal("stdout")
	}
	if err := cmd.Start(); err != nil {
		t.Fatal("start")
	}
	t.Cleanup(func() {
		stdin.Close()
		if cmd.Process != nil {
			cmd.Process.Kill()
		}
		cmd.Wait()
	})
	data, _ := json.Marshal(r)
	if _, err := stdin.Write(append(data, '\n')); err != nil {
		t.Fatal("request")
	}
	ready := make(chan int, 1)
	reader := bufio.NewReader(stdout)
	go func() {
		if line, err := reader.ReadBytes('\n'); err == nil {
			var message struct {
				Port int `json:"port"`
			}
			json.Unmarshal(line, &message)
			ready <- message.Port
		} else {
			ready <- 0
		}
	}()
	select {
	case port := <-ready:
		if port == 0 {
			t.Fatal("helper startup")
		}
		return port, cmd, stdin, reader
	case <-time.After(15 * time.Second):
		t.Fatal("helper startup timeout")
	}
	return 0, nil, nil, nil
}
func TestEncryptedTCPAndHalfClose(t *testing.T) {
	r, server := fixture(t)
	// A normal split-tunnel export may list DNS outside its private routes.
	// Literal RDP addresses must work without using or rejecting those servers.
	r.Configuration.DNS = "203.0.113.53, 203.0.113.54"
	listener, err := server.ListenTCPAddrPort(netip.MustParseAddrPort("10.111.0.1:3389"))
	if err != nil {
		t.Fatal("listen")
	}
	defer listener.Close()
	go func() {
		c, err := listener.Accept()
		if err != nil {
			return
		}
		defer c.Close()
		b, _ := io.ReadAll(c)
		c.Write(append([]byte("reply:"), b...))
	}()
	port, _, stdin, _ := helper(t, r)
	wrong, err := net.Dial("tcp4", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatal("invalid-token dial")
	}
	wrong.SetDeadline(time.Now().Add(time.Second))
	wrong.Write(make([]byte, 32))
	one := make([]byte, 1)
	if n, err := wrong.Read(one); n != 0 || err == nil {
		t.Fatal("unauthenticated proxy")
	}
	wrong.Close()
	local, err := net.DialTimeout("tcp4", fmt.Sprintf("127.0.0.1:%d", port), time.Second)
	if err != nil {
		t.Fatal("local dial")
	}
	defer local.Close()
	local.SetDeadline(time.Now().Add(10 * time.Second))
	token, _ := hex.DecodeString(r.Token)
	local.Write(token)
	ack := make([]byte, 1)
	if _, err := io.ReadFull(local, ack); err != nil || ack[0] != 1 {
		t.Fatal("encrypted dial")
	}
	local.Write([]byte("synthetic"))
	local.(*net.TCPConn).CloseWrite()
	got, err := io.ReadAll(local)
	if err != nil || !bytes.Equal(got, []byte("reply:synthetic")) {
		t.Fatal("encrypted relay/half close")
	}
	stdin.Close()
}
func TestAllowedIPsAndCancellation(t *testing.T) {
	r, _ := fixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	dev, stack, allowed, err := start(ctx, r)
	if err != nil {
		t.Fatal("start")
	}
	defer dev.Close()
	if _, err := dial(ctx, stack, allowed, "10.112.0.1", 3389); err == nil {
		t.Fatal("allowed IP escape")
	}
	cancelled, stop := context.WithCancel(context.Background())
	stop()
	if _, err := dial(cancelled, stack, allowed, r.Host, r.Port); err == nil {
		t.Fatal("cancelled dial succeeded")
	}
	r.Configuration.DNS = "10.112.0.1"
	if dev, _, _, err := start(ctx, r); err != nil {
		t.Fatal("split-tunnel DNS rejected at startup")
	} else {
		dev.Close()
	}
	if _, err := lookup(ctx, stack, allowed, nil, "synthetic.example"); err != missingDNS {
		t.Fatal("missing DNS diagnostic")
	}
	if _, err := dial(ctx, stack, allowed, "203.0.113.1", 3389); err != outsideAllowed {
		t.Fatal("destination bound diagnostic")
	}
}
func TestParentEOFCleanup(t *testing.T) {
	r, _ := fixture(t)
	port, cmd, stdin, _ := helper(t, r)
	stdin.Close()
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("orphan helper")
	}
	c, err := net.DialTimeout("tcp4", fmt.Sprintf("127.0.0.1:%d", port), time.Second)
	if err == nil {
		c.Close()
		t.Fatal("orphan listener")
	}
}
func TestRDPThroughWireGuard(t *testing.T) {
	client := os.Getenv("FARCAST_WG_RDP_CLIENT")
	target := os.Getenv("FARCAST_WG_RDP_FIXTURE_PORT")
	if client == "" || target == "" {
		t.Skip("RDP fixture not requested")
	}
	for _, mode := range []string{"accept", "reject", "cancel", "clipboard"} {
		t.Run(mode, func(t *testing.T) {
			r, server := fixture(t)
			listener, err := server.ListenTCPAddrPort(netip.MustParseAddrPort("10.111.0.1:3389"))
			if err != nil {
				t.Fatal("listen")
			}
			defer listener.Close()
			go func() {
				a, err := listener.Accept()
				if err != nil {
					return
				}
				defer a.Close()
				b, err := net.Dial("tcp4", "127.0.0.1:"+target)
				if err != nil {
					return
				}
				defer b.Close()
				relay(a, b)
			}()
			port, _, _, _ := helper(t, r)
			cmd := exec.Command(client, mode, strconv.Itoa(r.Port))
			cmd.Env = append(os.Environ(), "FARCAST_FIXTURE_TUNNEL_PORT="+strconv.Itoa(port), "FARCAST_FIXTURE_TUNNEL_TOKEN="+r.Token)
			if result, err := cmd.CombinedOutput(); err != nil {
				t.Fatalf("RDP fixture failed: %s", result)
			}
		})
	}
}

func TestSharedDeviceSessions(t *testing.T) {
	r, server := fixture(t)
	listener, err := server.ListenTCPAddrPort(netip.MustParseAddrPort("10.111.0.1:3389"))
	if err != nil {
		t.Fatal("listen")
	}
	defer listener.Close()
	go func() {
		for {
			c, err := listener.Accept()
			if err != nil {
				return
			}
			go func() { defer c.Close(); io.Copy(c, c) }()
		}
	}()
	firstPort, _, stdin, reader := helper(t, r)
	connect := func(port int, token string) net.Conn {
		c, err := net.Dial("tcp4", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			t.Fatal("local dial")
		}
		c.SetDeadline(time.Now().Add(5 * time.Second))
		b, _ := hex.DecodeString(token)
		c.Write(b)
		ack := make([]byte, 1)
		if _, err := io.ReadFull(c, ack); err != nil || ack[0] != 1 {
			c.Close()
			t.Fatal("shared encrypted dial")
		}
		return c
	}
	first := connect(firstPort, r.Token)
	defer first.Close()
	next := r
	next.Command = "open"
	next.Token = strings.Repeat("ab", 32)
	data, _ := json.Marshal(next)
	stdin.Write(append(data, '\n'))
	ready := make(chan int, 1)
	go func() {
		line, _ := reader.ReadBytes('\n')
		var v struct{ Port int }
		json.Unmarshal(line, &v)
		ready <- v.Port
	}()
	var secondPort int
	select {
	case secondPort = <-ready:
	case <-time.After(5 * time.Second):
		t.Fatal("second listener timeout")
	}
	second := connect(secondPort, next.Token)
	defer second.Close()
	closeRequest := r
	closeRequest.Command = "close"
	data, _ = json.Marshal(closeRequest)
	stdin.Write(append(data, '\n'))
	if n, err := first.Read(make([]byte, 1)); n != 0 || err == nil {
		t.Fatal("first lease not cancelled")
	}
	second.Write([]byte("independent"))
	response := make([]byte, 11)
	if _, err := io.ReadFull(second, response); err != nil || string(response) != "independent" {
		t.Fatal("second lease disrupted")
	}
}
func TestCancellationDuringHandshake(t *testing.T) {
	r, _ := fixture(t)
	_, r.Configuration.PublicKey = keys(t)
	port, cmd, stdin, _ := helper(t, r)
	local, err := net.Dial("tcp4", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatal("dial")
	}
	defer local.Close()
	token, _ := hex.DecodeString(r.Token)
	local.Write(token)
	local.SetReadDeadline(time.Now().Add(150 * time.Millisecond))
	if n, _ := local.Read(make([]byte, 1)); n != 0 {
		t.Fatal("unexpected unauthenticated peer")
	}
	stdin.Close()
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("handshake cancellation orphan")
	}
}

// Drive production Swift session startup and its shared helper registry, rather
// than constructing separate helpers for the two protocol adapters.
func TestMixedProtocolSessions(t *testing.T) {
	client := os.Getenv("FARCAST_WG_SESSION_CLIENT")
	if client == "" {
		t.Skip("mixed session fixture not requested")
	}
	r, server := fixture(t)
	for _, target := range []struct{ port, local string }{
		{"22", os.Getenv("FARCAST_WG_SESSION_SSH_PORT")},
		{"3389", os.Getenv("FARCAST_WG_SESSION_RDP_PORT")},
	} {
		listener, err := server.ListenTCPAddrPort(netip.MustParseAddrPort("10.111.0.1:" + target.port))
		if err != nil {
			t.Fatal("protocol listener")
		}
		t.Cleanup(func() { listener.Close() })
		go func(local string) {
			for {
				a, err := listener.Accept()
				if err != nil {
					return
				}
				go func() {
					defer a.Close()
					b, err := net.Dial("tcp4", "127.0.0.1:"+local)
					if err != nil {
						return
					}
					defer b.Close()
					relay(a, b)
				}()
			}
		}(target.local)
	}
	root := os.Getenv("FARCAST_WG_SESSION_ROOT")
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, client, root+"/ssh/fingerprint", root+"/cert.pem", root+"/ssh")
	data, _ := json.Marshal(r)
	cmd.Stdin = bytes.NewReader(data)
	if result, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("mixed protocol fixture failed: %s", result)
	} else {
		t.Log(string(result))
	}
}
