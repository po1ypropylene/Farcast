// App-private TCP transport. No OS TUN, route, DNS or VPN configuration.
package main

import (
	"bufio"
	"context"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

type configuration struct {
	Addresses  string `json:"addresses"`
	DNS        string `json:"dns"`
	PublicKey  string `json:"publicKey"`
	Endpoint   string `json:"endpoint"`
	AllowedIPs string `json:"allowedIPs"`
	Keepalive  int    `json:"keepalive"`
	MTU        int    `json:"mtu"`
}
type request struct {
	OpenVPN       *openVPNCredentials `json:"openVPN,omitempty"`
	Command       string              `json:"command"`
	Configuration configuration       `json:"configuration"`
	PrivateKey    string              `json:"privateKey"`
	PresharedKey  string              `json:"presharedKey"`
	Host          string              `json:"host"`
	Port          int                 `json:"port"`
	Token         string              `json:"token"`
}

func addresses(value string, prefixes bool) ([]netip.Addr, error) {
	var out []netip.Addr
	for _, entry := range strings.Split(value, ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		var a netip.Addr
		var err error
		if prefixes {
			var p netip.Prefix
			p, err = netip.ParsePrefix(entry)
			a = p.Addr()
		} else {
			a, err = netip.ParseAddr(entry)
		}
		if err != nil || !a.IsValid() || a.IsUnspecified() || a.IsMulticast() {
			return nil, errors.New("invalid address")
		}
		out = append(out, a)
	}
	return out, nil
}
func permitted(a netip.Addr, allowed []netip.Prefix) bool {
	for _, p := range allowed {
		if p.Contains(a) {
			return true
		}
	}
	return false
}
func dial(ctx context.Context, stack *netstack.Net, allowed []netip.Prefix, host string, port int, dns ...netip.Addr) (net.Conn, error) {
	if port < 1 || port > 65535 {
		return nil, errors.New("invalid port")
	}
	servers := make([]netip.AddrPort, 0, len(dns))
	for _, address := range dns {
		servers = append(servers, netip.AddrPortFrom(address, 53))
	}
	ips, err := lookup(ctx, stack, allowed, servers, host)
	if err != nil {
		return nil, err
	}
	attempted := false
	for _, a := range ips {
		if !permitted(a, allowed) {
			continue
		}
		attempted = true
		c, err := stack.DialContextTCPAddrPort(ctx, netip.AddrPortFrom(a, uint16(port)))
		if err == nil {
			return c, nil
		}
		if ctx.Err() != nil {
			break
		}
	}
	if !attempted {
		return nil, outsideAllowed
	}
	return nil, unreachable
}

// The listener accepts one token-authenticated session only. Unauthenticated local
// processes cannot consume the reserved remote connection or use a general proxy.
func serve(ctx context.Context, r request, stack *netstack.Net, allowed []netip.Prefix, ready func(int)) error {
	token, err := hex.DecodeString(r.Token)
	if err != nil || len(token) != 32 {
		return errors.New("invalid token")
	}
	listener, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		return err
	}
	defer listener.Close()
	ready(listener.Addr().(*net.TCPAddr).Port)
	go func() { <-ctx.Done(); listener.Close() }()
	for {
		local, err := listener.AcceptTCP()
		if err != nil {
			return err
		}
		local.SetDeadline(time.Now().Add(3 * time.Second))
		supplied := make([]byte, 32)
		_, err = io.ReadFull(local, supplied)
		if err != nil || subtle.ConstantTimeCompare(token, supplied) != 1 {
			local.Close()
			continue
		}
		listener.Close()
		local.SetDeadline(time.Time{})
		defer local.Close()
		timeout, cancel := context.WithTimeout(ctx, 25*time.Second)
		dns, _ := addresses(r.Configuration.DNS, false)
		remote, err := dial(timeout, stack, allowed, r.Host, r.Port, dns...)
		cancel()
		if err != nil {
			local.Write([]byte{failureStatus(err)})
			return err
		}
		defer remote.Close()
		go func() { <-ctx.Done(); local.Close(); remote.Close() }()
		if _, err = local.Write([]byte{1}); err != nil {
			return err
		}
		relay(local, remote)
		return nil
	}
}
func relay(a, b net.Conn) {
	done := make(chan error, 2)
	copyHalf := func(dst, src net.Conn) {
		_, err := io.Copy(dst, src)
		if half, ok := dst.(interface{ CloseWrite() error }); ok {
			half.CloseWrite()
		}
		done <- err
	}
	go copyHalf(a, b)
	go copyHalf(b, a)
	if err := <-done; err != nil {
		a.Close()
		b.Close()
	}
	<-done
}
func run() error {
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer cancel()
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), 1048576)
	lines := make(chan []byte)
	go func() {
		defer close(lines)
		for scanner.Scan() {
			line := append([]byte(nil), scanner.Bytes()...)
			select {
			case lines <- line:
			case <-ctx.Done():
				return
			}
		}
	}()
	var first []byte
	select {
	case line, ok := <-lines:
		if !ok {
			return errors.New("invalid request")
		}
		first = line
	case <-ctx.Done():
		return ctx.Err()
	}
	var r request
	if err := json.Unmarshal(first, &r); err != nil {
		return errors.New("invalid request")
	}
	var stack *netstack.Net
	var allowed []netip.Prefix
	var closeTransport func()
	var err error
	if r.OpenVPN != nil {
		timeout, stop := context.WithTimeout(ctx, 35*time.Second)
		closeTransport, stack, allowed, err = startOpenVPN(timeout, &r, cancel)
		stop()
	} else {
		timeout, stop := context.WithTimeout(ctx, 10*time.Second)
		var dev *device.Device
		dev, stack, allowed, err = startWireGuard(timeout, r)
		stop()
		if err == nil {
			closeTransport = dev.Close
		}
	}
	if err != nil {
		return err
	}
	defer closeTransport()
	tunnelDNS := r.Configuration.DNS
	sessions := make(map[string]context.CancelFunc)
	open := func(r request) error {
		r.Configuration.DNS = tunnelDNS
		token, err := hex.DecodeString(r.Token)
		if err != nil || len(token) != 32 || r.Port < 1 || r.Port > 65535 || r.Host == "" {
			return errors.New("invalid session")
		}
		if _, exists := sessions[r.Token]; exists {
			return errors.New("duplicate session")
		}
		session, stop := context.WithCancel(ctx)
		sessions[r.Token] = stop
		ready := make(chan int, 1)
		go func() {
			defer stop()
			err := serve(session, r, stack, allowed, func(port int) { ready <- port })
			if err != nil {
				select {
				case ready <- 0:
				default:
				}
			}
		}()
		select {
		case port := <-ready:
			if port == 0 {
				return errors.New("listener")
			}
			fmt.Printf("{\"port\":%d}\n", port)
		case <-ctx.Done():
			return ctx.Err()
		}
		return nil
	}
	if err := open(r); err != nil {
		return err
	}
	// A profile has one cryptographic device shared by its active sessions.
	// This avoids competing WireGuard endpoints when a key is used in several tabs.
	for {
		var line []byte
		select {
		case next, ok := <-lines:
			if !ok {
				return nil
			}
			line = next
		case <-ctx.Done():
			return ctx.Err()
		}
		var next request
		if err := json.Unmarshal(line, &next); err != nil {
			return errors.New("invalid request")
		}
		if next.Command == "close" {
			if stop, exists := sessions[next.Token]; exists {
				stop()
				delete(sessions, next.Token)
			}
		} else if next.Command == "open" {
			if err := open(next); err != nil {
				return err
			}
		} else {
			return errors.New("invalid command")
		}
	}
}
func main() {
	if err := run(); err != nil {
		code := "initialization"
		if err == endpointLookup {
			code = "endpoint_resolution"
		} else {
			switch err.Error() {
			case "invalid local addresses", "invalid address", "invalid key", "invalid options", "invalid endpoint", "invalid endpoint port", "invalid allowed IPs", "invalid request", "invalid session":
				code = "configuration"
			case "listener":
				code = "listener"
			}
		}
		json.NewEncoder(os.Stdout).Encode(struct {
			Error string `json:"error"`
		}{code})
		os.Exit(1)
	}
}
