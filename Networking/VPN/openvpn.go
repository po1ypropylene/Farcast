package main

/*
#cgo CFLAGS: -I${SRCDIR}/../OpenVPN
#cgo LDFLAGS: ${SRCDIR}/../../Vendor/Native/lib/libfarcast-openvpn.a ${SRCDIR}/../../Vendor/Native/lib/libssl.a ${SRCDIR}/../../Vendor/Native/lib/libcrypto.a -lc++ -framework CoreFoundation -framework IOKit -framework SystemConfiguration
#include "bridge.h"
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/binary"
	"errors"
	"net"
	"net/netip"
	"os"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"golang.zx2c4.com/wireguard/tun/netstack"
)

// Set at link time so a rebuilt native archive invalidates Go's link cache.
var openVPNRevision string

type openVPNCredentials struct {
	Profile    string `json:"profile"`
	Username   string `json:"username"`
	Password   string `json:"password"`
	Passphrase string `json:"passphrase"`
}

// A datagram socketpair substitutes for the OS TUN. Only this helper's gVisor
// stack sees decrypted packets; macOS routes, DNS and interfaces are untouched.
func startOpenVPN(ctx context.Context, r *request, failed context.CancelFunc) (func(), *netstack.Net, []netip.Prefix, error) {
	if r.OpenVPN == nil || len(r.OpenVPN.Profile) > 262144 || !strings.Contains(r.OpenVPN.Profile, "remote-cert-tls server") {
		return nil, nil, nil, errors.New("invalid request")
	}
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_DGRAM, 0)
	if err != nil {
		return nil, nil, nil, err
	}
	syscall.CloseOnExec(fds[0])
	syscall.CloseOnExec(fds[1])
	file := os.NewFile(uintptr(fds[0]), "openvpn-packets")
	socket, err := net.FileConn(file)
	file.Close()
	if err != nil {
		syscall.Close(fds[1])
		return nil, nil, nil, err
	}
	cstrings := []*C.char{C.CString(r.OpenVPN.Profile), C.CString(r.OpenVPN.Username), C.CString(r.OpenVPN.Password), C.CString(r.OpenVPN.Passphrase)}
	client := C.farcast_ovpn_create(cstrings[0], cstrings[1], cstrings[2], cstrings[3], C.int(fds[1]))
	for _, value := range cstrings {
		C.free(unsafe.Pointer(value))
	}
	if client == nil {
		socket.Close()
		return nil, nil, nil, errors.New("invalid request")
	}
	done := make(chan struct{})
	go func() { C.farcast_ovpn_run(client); close(done); failed() }()
	var once sync.Once
	cleanup := func() {
		once.Do(func() { C.farcast_ovpn_stop(client); socket.Close(); <-done; C.farcast_ovpn_free(client) })
	}
	success := false
	defer func() {
		if !success {
			cleanup()
		}
	}()
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	for C.farcast_ovpn_state(client) != 1 {
		select {
		case <-done:
			return nil, nil, nil, errors.New("openvpn connection failed")
		case <-ctx.Done():
			return nil, nil, nil, ctx.Err()
		case <-ticker.C:
		}
	}
	local, err := addresses(C.GoString(C.farcast_ovpn_addresses(client)), true)
	if err != nil || len(local) == 0 {
		return nil, nil, nil, errors.New("invalid local addresses")
	}
	dns, err := addresses(C.GoString(C.farcast_ovpn_dns(client)), false)
	if err != nil {
		return nil, nil, nil, err
	}
	var allowed []netip.Prefix
	for _, value := range strings.Split(C.GoString(C.farcast_ovpn_routes(client)), ",") {
		if value == "" {
			continue
		}
		prefix, err := netip.ParsePrefix(value)
		if err != nil {
			return nil, nil, nil, err
		}
		allowed = append(allowed, prefix.Masked())
	}
	// Interface subnets and explicitly pushed DNS hosts also remain inside VPN.
	for _, value := range strings.Split(C.GoString(C.farcast_ovpn_addresses(client)), ",") {
		prefix, err := netip.ParsePrefix(value)
		if err != nil {
			return nil, nil, nil, err
		}
		allowed = append(allowed, prefix.Masked())
	}
	for _, address := range dns {
		allowed = append(allowed, netip.PrefixFrom(address, address.BitLen()))
	}
	r.Configuration.DNS = C.GoString(C.farcast_ovpn_dns(client))
	tun, stack, err := netstack.CreateNetTUN(local, dns, int(C.farcast_ovpn_mtu(client)))
	if err != nil {
		return nil, nil, nil, err
	}
	var pumps sync.WaitGroup
	pumps.Add(2)
	go func() {
		defer pumps.Done()
		defer failed()
		packet := make([]byte, 65540)
		for {
			n, err := socket.Read(packet)
			if err != nil {
				return
			}
			if n <= 4 {
				continue
			}
			if _, err = tun.Write([][]byte{packet[4:n]}, 0); err != nil {
				return
			}
		}
	}()
	go func() {
		defer pumps.Done()
		defer failed()
		packet := make([]byte, 65540)
		sizes := make([]int, 1)
		for {
			count, err := tun.Read([][]byte{packet}, sizes, 4)
			if err != nil {
				return
			}
			if count != 1 || sizes[0] == 0 {
				continue
			}
			family := uint32(syscall.AF_INET)
			if packet[4]>>4 == 6 {
				family = syscall.AF_INET6
			}
			binary.BigEndian.PutUint32(packet[:4], family)
			if _, err = socket.Write(packet[:sizes[0]+4]); err != nil {
				return
			}
		}
	}()
	success = true
	return func() { tun.Close(); cleanup(); pumps.Wait() }, stack, allowed, nil
}
