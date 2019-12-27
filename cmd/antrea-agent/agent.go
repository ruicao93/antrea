// Copyright 2019 Antrea Authors
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

package main

import (
	"fmt"
	"time"

	"k8s.io/client-go/informers"
	"k8s.io/klog"

	"github.com/vmware-tanzu/antrea/pkg/agent"
	"github.com/vmware-tanzu/antrea/pkg/agent/cniserver"
	_ "github.com/vmware-tanzu/antrea/pkg/agent/cniserver/ipam"
	"github.com/vmware-tanzu/antrea/pkg/agent/controller/networkpolicy"
	"github.com/vmware-tanzu/antrea/pkg/agent/controller/noderoute"
	"github.com/vmware-tanzu/antrea/pkg/agent/interfacestore"
	"github.com/vmware-tanzu/antrea/pkg/agent/openflow"
	"github.com/vmware-tanzu/antrea/pkg/agent/types"
	"github.com/vmware-tanzu/antrea/pkg/apis/networking/v1beta1"
	"github.com/vmware-tanzu/antrea/pkg/k8s"
	"github.com/vmware-tanzu/antrea/pkg/monitor"
	"github.com/vmware-tanzu/antrea/pkg/ovs/ovsconfig"
	"github.com/vmware-tanzu/antrea/pkg/signals"
	"github.com/vmware-tanzu/antrea/pkg/version"
)

// Determine how often we go through reconciliation (between current and desired state)
// Same as in https://github.com/kubernetes/sample-controller/blob/master/main.go
const informerDefaultResync time.Duration = 30 * time.Second

// run starts Antrea agent with the given options and waits for termination signal.
func run(o *Options) error {
	klog.Infof("Starting Antrea agent (version %s)", version.GetFullVersion())
	// Create K8s Clientset, CRD Clientset and SharedInformerFactory for the given config.
	k8sClient, crdClient, err := k8s.CreateClients(o.config.ClientConnection)
	if err != nil {
		return fmt.Errorf("error creating K8s clients: %v", err)
	}
	informerFactory := informers.NewSharedInformerFactory(k8sClient, informerDefaultResync)

	// Create Antrea Clientset for the given config.
	antreaClient, err := agent.CreateAntreaClient(o.config.AntreaClientConnection)
	if err != nil {
		return fmt.Errorf("error creating Antrea client: %v", err)
	}

	// Create ovsdb and openflow clients.
	ovsdbConnection, err := ovsconfig.NewOVSDBConnectionUDS("")
	if err != nil {
		// TODO: ovsconfig.NewOVSDBConnectionUDS might return timeout in the future, need to add retry
		return fmt.Errorf("error connecting OVSDB: %v", err)
	}
	defer ovsdbConnection.Close()

	ovsBridgeClient := ovsconfig.NewOVSBridge(o.config.OVSBridge, o.config.OVSDatapathType, ovsdbConnection)

	ofClient := openflow.NewClient(o.config.OVSBridge)

	// Create an ifaceStore that caches network interfaces managed by this node.
	ifaceStore := interfacestore.NewInterfaceStore()

	// Initialize agent and node network.
	var networkMode types.NetworkMode
	switch {
	case o.config.NetworkMode == encapNormal:
		networkMode = types.EncapNormal
	case o.config.NetworkMode == ipsecEncap:
		networkMode = types.IPSecEncap
	}
	agentInitializer := agent.NewInitializer(
		ovsBridgeClient,
		ofClient,
		k8sClient,
		ifaceStore,
		o.config.OVSBridge,
		o.config.ServiceCIDR,
		o.config.HostGateway,
		o.config.DefaultMTU,
		networkMode,
		ovsconfig.TunnelType(o.config.TunnelType))
	nodeConfig := agentInitializer.GetNodeConfig()

	nodeRouteController := noderoute.NewNodeRouteController(
		k8sClient,
		informerFactory,
		ofClient,
		ovsBridgeClient,
		ifaceStore,
		nodeConfig,
		networkMode,
		ovsconfig.TunnelType(o.config.TunnelType),
		agentInitializer.GetIPSecPSK())

	// podUpdates is a channel for receiving Pod updates from CNIServer and
	// notifying NetworkPolicyController to reconcile rules related to the
	// updated Pods.
	podUpdates := make(chan v1beta1.PodReference, 100)
	networkPolicyController := networkpolicy.NewNetworkPolicyController(antreaClient, ofClient, ifaceStore, nodeConfig.Name, podUpdates)

	cniServer := cniserver.New(
		o.config.CNISocket,
		o.config.HostProcPathPrefix,
		o.config.DefaultMTU,
		o.config.OVSDatapathType,
		nodeConfig,
		ovsBridgeClient,
		ofClient,
		ifaceStore,
		k8sClient,
		podUpdates)
	err = cniServer.Initialize()
	if err != nil {
		return fmt.Errorf("error initializing CNI server: %v", err)
	}

	// set up signal capture: the first SIGTERM / SIGINT signal is handled gracefully and will
	// cause the stopCh channel to be closed; if another signal is received before the program
	// exits, we will force exit.
	stopCh := signals.RegisterSignalHandlers()

	go cniServer.Run(stopCh)

	informerFactory.Start(stopCh)

	go nodeRouteController.Run(stopCh)

	go networkPolicyController.Run(stopCh)

	agentMonitor := monitor.NewAgentMonitor(crdClient, o.config.OVSBridge, nodeConfig.Name, nodeConfig.PodCIDR.String(), ifaceStore, ofClient, ovsBridgeClient, networkPolicyController)

	go agentMonitor.Run(stopCh)

	<-stopCh
	klog.Info("Stopping Antrea agent")
	return nil
}
