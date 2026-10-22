package main

import (
	"context"
	"golang.org/x/net/dns/dnsmessage"
	"net"
	"net/netip"
	"testing"
	"time"
)

// Disposable resolver: answers A only; no real hostnames or external DNS access.
func syntheticDNS(t *testing.T, server net.PacketConn) {
	t.Helper()
	t.Cleanup(func() { server.Close() })
	go func() {
		buffer := make([]byte, 4096)
		for {
			n, source, err := server.ReadFrom(buffer)
			if err != nil {
				return
			}
			var parser dnsmessage.Parser
			header, err := parser.Start(buffer[:n])
			if err != nil {
				continue
			}
			question, err := parser.Question()
			if err != nil {
				continue
			}
			response := dnsmessage.Message{Header: dnsmessage.Header{ID: header.ID, Response: true, RecursionDesired: true, RecursionAvailable: true}, Questions: []dnsmessage.Question{question}}
			if question.Type == dnsmessage.TypeA {
				response.Answers = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: question.Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 60}, Body: &dnsmessage.AResource{A: [4]byte{10, 111, 0, 1}}}}
			}
			data, err := response.Pack()
			if err == nil {
				server.WriteTo(data, source)
			}
		}
	}()
}
func TestSplitDNSUsesConfiguredResolverOutsideTunnel(t *testing.T) {
	r, _ := fixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	dev, stack, allowed, err := startWireGuard(ctx, r)
	if err != nil {
		t.Fatal("start")
	}
	defer dev.Close()
	dns, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal("DNS listener")
	}
	syntheticDNS(t, dns)
	addr := dns.LocalAddr().(*net.UDPAddr).AddrPort()
	if permitted(addr.Addr(), allowed) {
		t.Fatal("fixture DNS unexpectedly in tunnel")
	}
	ips, err := lookup(ctx, stack, allowed, []netip.AddrPort{addr}, "synthetic.example")
	if err != nil || len(ips) != 1 || ips[0] != netip.MustParseAddr("10.111.0.1") {
		t.Fatal("split DNS resolution")
	}
}
func TestPrivateDNSUsesEncryptedTunnel(t *testing.T) {
	r, server := fixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	dev, stack, allowed, err := startWireGuard(ctx, r)
	if err != nil {
		t.Fatal("start")
	}
	defer dev.Close()
	dns, err := server.ListenUDPAddrPort(netip.MustParseAddrPort("10.111.0.1:0"))
	if err != nil {
		t.Fatal("DNS listener")
	}
	syntheticDNS(t, dns)
	addr, err := netip.ParseAddrPort(dns.LocalAddr().String())
	if err != nil {
		t.Fatal("DNS address")
	}
	if !permitted(addr.Addr(), allowed) {
		t.Fatal("fixture DNS outside tunnel")
	}
	ips, err := lookup(ctx, stack, allowed, []netip.AddrPort{addr}, "synthetic.example")
	if err != nil || len(ips) != 1 || ips[0] != netip.MustParseAddr("10.111.0.1") {
		t.Fatal("encrypted DNS resolution")
	}
}
