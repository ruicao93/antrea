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

package agent

import (
	"net"
	"strings"

	"github.com/Microsoft/hcsshim"
	"k8s.io/klog"

	"github.com/vmware-tanzu/antrea/pkg/agent/config"
	"github.com/vmware-tanzu/antrea/pkg/agent/interfacestore"
	"github.com/vmware-tanzu/antrea/pkg/agent/util"
)

// setupExternalConnectivity installs OpenFlow entries to SNAT Pod traffic using Node IP, and then Pod could communicate
// to external IP addresses.
func (i *Initializer) setupExternalConnectivity() error {
	subnetCIDR := i.nodeConfig.PodCIDR
	nodeIP := i.nodeConfig.NodeIPAddr.IP
	// Install OpenFlow entries on the OVS to enable Pod traffic to communicate to external IP addresses.
	if err := i.ofClient.InstallExternalFlows(nodeIP, *subnetCIDR); err != nil {
		klog.Errorf("Failed to setup SNAT openflow entries: %v", err)
		return err
	}
	return nil
}

// prepareOVSBridge adds uplink interface on OVS bridge and configs IP, MAC for the bridge.
func (i *Initializer) prepareOVSBridge() error {
	hnsNetwork, err := hcsshim.GetHNSNetworkByName(util.LocalHNSNetwork)
	if err != nil {
		return err
	}
	uplink := hnsNetwork.NetworkAdapterName

	// Set datapathID of OVS bridge.
	// If no datapathID configured explicitly, the reconfiguration operation will change OVS bridge datapathID
	// and break the OpenFlow channel.
	datapathID := strings.Replace(hnsNetwork.SourceMac, ":", "", -1)
	datapathID = "0000" + datapathID
	if err = i.ovsBridgeClient.SetDatapathID(datapathID); err != nil {
		klog.Errorf("Failed to set datapath_id %s: %v", datapathID, err)
		return err
	}

	// If uplink is already exists, return.
	if _, err := i.ovsBridgeClient.GetOFPort(uplink); err == nil {
		klog.Errorf("Uplink %s already exists, skip the configuration", uplink)
		return err
	}

	// Create uplink port.
	uplinkPortUUId, err := i.ovsBridgeClient.CreateUplinkPort(uplink, uplink, config.UplinkOFPort, nil)
	if err != nil {
		klog.Errorf("Failed to add uplink port %s: %v", uplink, err)
		return err
	}
	uplinkInterface := interfacestore.NewUplinkInterface(uplink)
	uplinkInterface.OVSPortConfig = &interfacestore.OVSPortConfig{uplinkPortUUId, config.UplinkOFPort}
	i.ifaceStore.AddInterface(uplinkInterface)

	// Get IP, MAC of uplink interface/
	ipAddr, ipNet, err := net.ParseCIDR(hnsNetwork.ManagementIP)
	if err != nil {
		klog.Errorf("Failed to parse IP Address %s for HNSNetwork %s: %v",
			hnsNetwork.ManagementIP, util.LocalHNSNetwork, err)
		return err
	}
	ifIpAddr := net.IPNet{IP: ipAddr, Mask: ipNet.Mask}
	klog.Infof("Found hns network management ipAddr: %s", ifIpAddr.String())
	// Move IP, MAC of from uplink interface to OVS bridge.
	brName := i.ovsBridgeClient.GetBridgeName()
	err = util.EnableHostInterface(brName)
	if err != nil {
		return err
	}
	macAddr, err := net.ParseMAC(hnsNetwork.SourceMac)
	if err != nil {
		return err
	}
	err = util.ConfigureMacAddress(brName, macAddr)
	if err != nil {
		klog.Errorf("Failed to set Mac Address %s for interface %v: ", macAddr, uplink, err)
		return err
	}
	existingIpAddr, err := util.GetAdapterIPv4Addr(brName)
	if err == nil && existingIpAddr.String() == ifIpAddr.String() {
		return nil
	}
	if err := util.RemoveIPv4Addrs(brName); err != nil {
		klog.Errorf("Failed to remove existing IP Addresses for interface %v: ", brName, err)
		return err
	}
	err = util.ConfigureInterfaceAddress(brName, &ifIpAddr)
	if err != nil {
		klog.Errorf("Failed to set IP Address %s for interface %v: ", ifIpAddr, brName, err)
		return err
	}
	return nil
}

// initHostNetworkFlow installs Openflow entries for uplink/bridge to support host networking.
func (i *Initializer) initHostNetworkFlow() error {
	if err := i.ofClient.InstallHostNetworkFlows(config.UplinkOFPort, config.BridgeOFPort); err != nil {
		return err
	}
	return nil
}
