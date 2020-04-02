// +build windows

// Copyright 2020 Antrea Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package route

import (
	"fmt"
	"net"
	"strings"
	"sync"

	"github.com/rakelkar/gonetsh/netroute"
	"k8s.io/apimachinery/pkg/util/sets"
	"k8s.io/klog"

	"github.com/vmware-tanzu/antrea/pkg/agent/config"
	"github.com/vmware-tanzu/antrea/pkg/agent/util"
)

type Client struct {
	nr          netroute.Interface
	nodeConfig  *config.NodeConfig
	serviceCIDR *net.IPNet
	hostRoutes  *sync.Map
}

// NewClient returns a route client.
func NewClient(hostGateway string, serviceCIDR *net.IPNet, encapMode config.TrafficEncapModeType) (*Client, error) {
	nr := netroute.New()
	return &Client{
		nr:          nr,
		serviceCIDR: serviceCIDR,
		hostRoutes:  &sync.Map{},
	}, nil
}

// Initialize sets nodeConfig on Window.
// Service LoadBalancing is provided by OpenFlow.
func (c *Client) Initialize(nodeConfig *config.NodeConfig) error {
	c.nodeConfig = nodeConfig
	// Enable IP-Forwarding on the interface of OVS bridge, and the host networking stack can be used to forward the
	// SNAT packet from local Pods. The SNAT packet is output to the OVS bridge interface with the Node's IP as the
	// the src IP, the external address as the dst IP, and the gw0's MAC as the dst MAC. After the bridge interface gets
	// the packet, it forwards the packet on the host networking, and the packet's dst MAC could be reset with a correct
	// one. Then the packet is sent back to OVS from the bridge Interface, and the OpenFlow entries will output the packet
	// to the uplink interface directly.
	if err := util.EnableIPForwarding(nodeConfig.BridgeName); err != nil {
		return err
	}
	if err := c.initFwRules(nodeConfig); err != nil {
		return err
	}
	return nil
}

// Reconcile removes the orphaned routes and related configuration based on the desired podCIDRs. Only the route
// entries on the host gateway interface are stored in the cache.
func (c *Client) Reconcile(podCIDRs []string) error {
	desiredPodCIDRs := sets.NewString(podCIDRs...)
	routes, err := c.listRoutes()
	if err != nil {
		return err
	}
	for dst, rt := range routes {
		if desiredPodCIDRs.Has(dst) {
			c.hostRoutes.Store(dst, rt)
			continue
		}
		err := c.nr.RemoveNetRoute(rt.LinkIndex, rt.DestinationSubnet, rt.GatewayAddress)
		if err != nil {
			return err
		}
	}
	return nil
}

// AddRoutes adds routes to the provided podCIDR.
// It overrides the routes if they already exist, without error.
func (c *Client) AddRoutes(podCIDR *net.IPNet, peerNodeIP, peerGwIP net.IP) error {
	obj, found := c.hostRoutes.Load(podCIDR.String())
	if found {
		rt := obj.(*netroute.Route)
		if rt.GatewayAddress.Equal(peerGwIP) {
			klog.V(4).Infof("Route with destination %s already exists", podCIDR.String())
			return nil
		}
		// Remove the existing route entry if the gateway address is not as expected.
		if err := c.nr.RemoveNetRoute(rt.LinkIndex, rt.DestinationSubnet, rt.GatewayAddress); err != nil {
			klog.Errorf("Failed to delete existing route entry with destination %s gateway %s", podCIDR.String(), peerGwIP.String())
			return err
		}
	}
	if err := c.nr.NewNetRoute(c.nodeConfig.GatewayConfig.LinkIndex, podCIDR, peerGwIP); err != nil {
		return err
	}
	c.hostRoutes.Store(podCIDR.String(), &netroute.Route{
		LinkIndex:         c.nodeConfig.GatewayConfig.LinkIndex,
		DestinationSubnet: podCIDR,
		GatewayAddress:    peerGwIP,
	})
	klog.V(2).Infof("Added route with destination %s via %s on host gateway", podCIDR.String(), peerGwIP.String())
	return nil
}

// DeleteRoutes deletes routes to the provided podCIDR.
// It does nothing if the routes don't exist, without error.
func (c *Client) DeleteRoutes(podCIDR *net.IPNet) error {
	obj, found := c.hostRoutes.Load(podCIDR.String())
	if !found {
		klog.V(2).Infof("Route with destination %s not exists", podCIDR.String())
		return nil
	}

	rt := obj.(*netroute.Route)
	if err := c.nr.RemoveNetRoute(rt.LinkIndex, rt.DestinationSubnet, rt.GatewayAddress); err != nil {
		return err
	}
	c.hostRoutes.Delete(podCIDR.String())
	klog.V(2).Infof("Deleted route with destination %s from host gateway", podCIDR.String())
	return nil
}

// MigrateRoutesToGw is not supported on Windows, return immediately.
func (c *Client) MigrateRoutesToGw(linkName string) error {
	return nil
}

// UnMigrateRoutesFromGw is not supported on Windows, return immedidately.
func (c *Client) UnMigrateRoutesFromGw(route *net.IPNet, linkName string) error {
	return nil
}

func (c *Client) listRoutes() (map[string]*netroute.Route, error) {
	routes, err := c.nr.GetNetRoutesAll()
	if err != nil {
		return nil, err
	}
	rtMap := make(map[string]*netroute.Route)
	for idx := range routes {
		rt := routes[idx]
		if rt.LinkIndex != c.nodeConfig.GatewayConfig.LinkIndex {
			continue
		}
		// Only process IPv4 route entries in the loop.
		if rt.DestinationSubnet.IP.To4() == nil {
			continue
		}
		// Retrieve the route entries with destination using global unicast only. This is because the function
		// "GetNetRoutesAll" also returns the entries of loopback, broadcast, and multicast, which are
		// added by the system when adding a new IP on the interface. Since removing those route entries might
		// introduce the host networking issues, ignore them from the list.
		if !rt.DestinationSubnet.IP.IsGlobalUnicast() {
			continue
		}
		// Windows adds an active route for the local broadcast address automatically when a new IP address
		// is configured on the interface. This route entry should be ignored in the result.
		if rt.DestinationSubnet.IP.Equal(util.GetLocalBroadcastIP(rt.DestinationSubnet)) {
			continue
		}
		rtMap[rt.DestinationSubnet.String()] = &rt
	}
	return rtMap, nil
}

const (
	inboundFirewallRuleName  = "Antrea: accept packets from local pods"
	outboundFirewallRuleName = "Antrea: accept packets to local pods"
)

type fwRuleAction string

const (
	fwRuleAllow fwRuleAction = "Allow"
	fwRuleDeny  fwRuleAction = "Block"
)

type fwRuleDirection string

const (
	fwRuleIn  fwRuleDirection = "Inbound"
	fwRuleOut fwRuleDirection = "Outbound"
)

type fwRuleProtocol string

const (
	fwRuleIPProtocol  fwRuleProtocol = "Any"
	fwRuleTCPProtocol fwRuleProtocol = "TCP"
	fwRuleUDPProtocol fwRuleProtocol = "UDP"
)

type winFirewallRule struct {
	name          string
	action        fwRuleAction
	direction     fwRuleDirection
	protocol      fwRuleProtocol
	localAddress  *net.IPNet
	remoteAddress *net.IPNet
	localPorts    []uint16
	remotePorts   []uint16
}

func (r *winFirewallRule) Add() error {
	cmd := r.getCommandString()
	return util.AddFirewallRule(cmd)
}

func (r *winFirewallRule) Delete() error {
	return util.DelFirewallRuleByName(r.name)
}

func (r *winFirewallRule) getCommandString() string {
	cmd := fmt.Sprintf("-Name '%s' -DisplayName '%s' -Direction %s -Action %s -Protocol %s", r.name, r.name, r.direction, r.action, r.protocol)
	if r.localAddress != nil {
		cmd = fmt.Sprintf("%s -LocalAddress %s", cmd, r.localAddress.String())
	}
	if r.remoteAddress != nil {
		cmd = fmt.Sprintf("%s -RemoteAddress %s", cmd, r.remoteAddress.String())
	}
	if len(r.localPorts) > 0 {
		cmd = fmt.Sprintf("%s -LocalPort %s", cmd, getPortsString(r.localPorts))
	}
	if len(r.remotePorts) > 0 {
		cmd = fmt.Sprintf("%s -RemotePort %s", cmd, getPortsString(r.remotePorts))
	}
	return cmd
}

func getPortsString(ports []uint16) string {
	portStr := []string{}
	for _, port := range ports {
		portStr = append(portStr, fmt.Sprintf("%d", port))
	}
	return strings.Join(portStr, ",")
}

// initFwRules adds Windows Firewall rules to accept the traffic that is sent to or from local Pods.
func (c *Client) initFwRules(nodeConfig *config.NodeConfig) error {
	exist, err := util.FirewallRuleExists(inboundFirewallRuleName)
	if err != nil {
		return err
	}
	if !exist {
		inRule := &winFirewallRule{
			name:          inboundFirewallRuleName,
			action:        fwRuleAllow,
			direction:     fwRuleIn,
			protocol:      fwRuleIPProtocol,
			remoteAddress: nodeConfig.PodCIDR,
		}
		if err := inRule.Add(); err != nil {
			klog.Errorf("Failed to add inbound firewall rule %s", inRule.getCommandString())
			return err
		}
		klog.V(2).Infof("Added inbound firewall rule %s", inRule.getCommandString())
	}
	exist, err = util.FirewallRuleExists(outboundFirewallRuleName)
	if err != nil {
		return err
	}
	if !exist {
		outRule := &winFirewallRule{
			name:         outboundFirewallRuleName,
			action:       fwRuleAllow,
			direction:    fwRuleOut,
			protocol:     fwRuleIPProtocol,
			localAddress: nodeConfig.PodCIDR,
		}
		if err := outRule.Add(); err != nil {
			klog.Errorf("Failed to add outbound firewall rule %s", outRule.getCommandString())
			return err
		}
		klog.V(2).Infof("Added outbound firewall rule %s", outRule.getCommandString())
	}
	return nil
}
