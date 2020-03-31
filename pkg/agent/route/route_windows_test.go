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
	"net"
	"testing"

	"github.com/rakelkar/gonetsh/netroute"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"k8s.io/klog"

	"github.com/vmware-tanzu/antrea/pkg/agent/config"
	"github.com/vmware-tanzu/antrea/pkg/agent/util"
)

func getNetLinkIndex(dev string) int {
	link, err := net.InterfaceByName(dev)
	if err != nil {
		klog.Fatalf("cannot find dev %s: %v", dev, err)
	}
	return link.Index
}

func TestRouteOperation(t *testing.T) {
	// Leverage loopback interface for testing.
	hostGateway := "Loopback Pseudo-Interface 1"
	_, serviceCIDR, _ := net.ParseCIDR("1.1.0.0/16")
	gwLink := getNetLinkIndex("Loopback Pseudo-Interface 1")

	peerNodeIP := net.ParseIP("10.0.0.2")
	gwIP1 := net.ParseIP("192.168.2.1")
	_, destCIDR1, _ := net.ParseCIDR("192.168.2.0/24")

	dest2 := "192.168.3.0/24"
	gwIP2 := net.ParseIP("192.168.3.1")
	_, destCIDR2, _ := net.ParseCIDR(dest2)

	nr := netroute.New()
	defer nr.Exit()

	client, err := NewClient(hostGateway, serviceCIDR, 0)
	require.Nil(t, err)
	nodeConfig := &config.NodeConfig{
		GatewayConfig: &config.GatewayConfig{
			LinkIndex: gwLink,
		},
	}
	err = client.Initialize(nodeConfig)
	require.Nil(t, err)

	// Add initial routes.
	err = client.AddRoutes(destCIDR1, peerNodeIP, gwIP1)
	require.Nil(t, err)
	routes1, err := nr.GetNetRoutes(gwLink, destCIDR1)
	require.Nil(t, err)
	assert.Equal(t, 1, len(routes1))

	err = client.AddRoutes(destCIDR2, peerNodeIP, gwIP2)
	require.Nil(t, err)
	routes2, err := nr.GetNetRoutes(gwLink, destCIDR2)
	require.Nil(t, err)
	assert.Equal(t, 1, len(routes2))

	desiredDestinations := []string{
		dest2,
	}
	err = client.Reconcile(desiredDestinations)
	require.Nil(t, err)
	routes3, err := nr.GetNetRoutes(gwLink, destCIDR1)
	require.Nil(t, err)
	assert.Equal(t, 0, len(routes3))

	err = client.DeleteRoutes(destCIDR2)
	routes4, err := nr.GetNetRoutes(gwLink, destCIDR2)
	require.Nil(t, err)
	assert.Equal(t, 0, len(routes4))
}

func TestWinFirewallRules(t *testing.T) {
	hostGateway := "Loopback Pseudo-Interface 1"
	_, serviceCIDR, _ := net.ParseCIDR("1.1.0.0/16")
	_, podCIDR, _ := net.ParseCIDR("2.2.2.0/24")
	client, err := NewClient(hostGateway, serviceCIDR, 0)
	require.Nil(t, err)

	nodeConfig := &config.NodeConfig{
		Name:    "node1",
		PodCIDR: podCIDR,
	}

	checkExistence := func(rules []string, expectExists bool) {
		for _, ruleName := range rules {
			exists, err := util.FirewallRuleExists(ruleName)
			require.Nil(t, err)
			assert.Equal(t, expectExists, exists)
		}
	}

	expectedRules := []string{inboundFirewallRuleName, outboundFirewallRuleName}
	checkExistence(expectedRules, false)
	err = client.initFwRules(nodeConfig)
	require.Nil(t, err)
	checkExistence(expectedRules, true)

	err = util.DelFirewallRuleByName(inboundFirewallRuleName)
	require.Nil(t, err)
	err = util.DelFirewallRuleByName(outboundFirewallRuleName)
	require.Nil(t, err)
	checkExistence(expectedRules, false)
}
