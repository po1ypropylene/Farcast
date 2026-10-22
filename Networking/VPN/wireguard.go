package main

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strconv"
	"strings"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

func key(value string) (string, error) {
	b, err := base64.StdEncoding.DecodeString(value)
	if err != nil || len(b) != 32 {
		return "", errors.New("invalid key")
	}
	return hex.EncodeToString(b), nil
}
func startWireGuard(ctx context.Context, r request) (*device.Device, *netstack.Net, []netip.Prefix, error) {
	c := r.Configuration
	local, err := addresses(c.Addresses, true)
	if err != nil || len(local) == 0 {
		return nil, nil, nil, errors.New("invalid local addresses")
	}
	dns, err := addresses(c.DNS, false)
	if err != nil {
		return nil, nil, nil, err
	}
	private, err := key(r.PrivateKey)
	if err != nil {
		return nil, nil, nil, err
	}
	public, err := key(c.PublicKey)
	if err != nil {
		return nil, nil, nil, err
	}
	if c.MTU < 1280 || c.MTU > 1500 || c.Keepalive < 0 || c.Keepalive > 65535 {
		return nil, nil, nil, errors.New("invalid options")
	}
	endpointHost, endpointPort, err := net.SplitHostPort(c.Endpoint)
	if err != nil {
		return nil, nil, nil, errors.New("invalid endpoint")
	}
	p, err := strconv.Atoi(endpointPort)
	if err != nil || p < 1 || p > 65535 {
		return nil, nil, nil, errors.New("invalid endpoint port")
	}
	ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip", endpointHost)
	if err != nil || len(ips) == 0 {
		return nil, nil, nil, endpointLookup
	}
	ipc := fmt.Sprintf("private_key=%s\npublic_key=%s\nendpoint=%s\npersistent_keepalive_interval=%d\n", private, public, net.JoinHostPort(ips[0].String(), endpointPort), c.Keepalive)
	if r.PresharedKey != "" {
		v, e := key(r.PresharedKey)
		if e != nil {
			return nil, nil, nil, e
		}
		ipc += "preshared_key=" + v + "\n"
	}
	var allowed []netip.Prefix
	for _, entry := range strings.Split(c.AllowedIPs, ",") {
		p, err := netip.ParsePrefix(strings.TrimSpace(entry))
		if err != nil {
			return nil, nil, nil, errors.New("invalid allowed IPs")
		}
		allowed = append(allowed, p.Masked())
		ipc += "allowed_ip=" + p.Masked().String() + "\n"
	}

	tun, stack, err := netstack.CreateNetTUN(local, dns, c.MTU)
	if err != nil {
		return nil, nil, nil, err
	}
	dev := device.NewDevice(tun, conn.NewDefaultBind(), device.NewLogger(device.LogLevelSilent, ""))
	if err = dev.IpcSet(ipc); err == nil {
		err = dev.Up()
	}
	if err != nil {
		dev.Close()
		return nil, nil, nil, err
	}
	return dev, stack, allowed, nil
}
