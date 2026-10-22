package main

import (
	"context"
	"net"
	"net/netip"
	"strings"
	"time"

	"golang.zx2c4.com/wireguard/tun/netstack"
)

type failure string

func (f failure) Error() string { return string(f) }

const (
	missingDNS     failure = "dns_missing"
	failedDNS      failure = "dns_lookup"
	outsideAllowed failure = "destination_not_allowed"
	unreachable    failure = "destination_unreachable"
	endpointLookup failure = "endpoint_resolution"
)

// DNS follows the exported split routes: only DNS addresses covered by AllowedIPs
// use WireGuard. Other explicitly configured DNS servers use an ordinary socket.
// This never changes the Mac's resolver or permits a direct RDP connection.
func dnsConnection(ctx context.Context, stack *netstack.Net, allowed []netip.Prefix, server netip.AddrPort, network string) (net.Conn, error) {
	if permitted(server.Addr(), allowed) {
		if strings.HasPrefix(network, "udp") {
			return stack.DialUDPAddrPort(netip.AddrPort{}, server)
		}
		return stack.DialContextTCPAddrPort(ctx, server)
	}
	return (&net.Dialer{}).DialContext(ctx, network, server.String())
}
func lookup(ctx context.Context, stack *netstack.Net, allowed []netip.Prefix, servers []netip.AddrPort, host string) ([]netip.Addr, error) {
	if address, err := netip.ParseAddr(host); err == nil {
		return []netip.Addr{address}, nil
	}
	if len(servers) == 0 {
		return nil, missingDNS
	}
	// Absolute names avoid applying the Mac's unrelated DNS search suffixes.
	host = strings.TrimSuffix(host, ".") + "."
	for _, server := range servers {
		resolver := net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			return dnsConnection(ctx, stack, allowed, server, network)
		}}
		timeout, cancel := context.WithTimeout(ctx, 5*time.Second)
		addresses, err := resolver.LookupNetIP(timeout, "ip", host)
		cancel()
		if err == nil && len(addresses) > 0 {
			return addresses, nil
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
	}
	return nil, failedDNS
}
func failureStatus(err error) byte {
	switch err {
	case missingDNS:
		return 2
	case failedDNS:
		return 3
	case outsideAllowed:
		return 4
	default:
		return 5
	}
}
