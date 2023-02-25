#!/bin/bash

set -eux

# number of vpn namespaces, should be equal to number of openvpn clients you are going to run.
NS_COUNT=3
# name of main bridge in default namespace tapped into your LAN.
DEFAULT_NS_BRIDGE="br_main"
# in order to access processes in app namespace from LAN, firewall must know LAN subnet CIDR.
LAN_SUBNET="192.168.42.0/24"
# default gateway in your LAN that should route traffic to the internet. Effectively, your router IP.
LAN_DEFAULT_GW="192.168.42.1"
# IP to assign to NAT egress interface. Must be statically allocated from your LAN subnet.
NAT_EGRESS_IP="192.168.42.85/24"
# IP to assign to app namespace bridge. Must be statically allocated from your LAN subnet.
# Through this IP you can access servers that use vmux_app namespace and
# route internet traffic through VPNs but can still respond to LAN requests.
# This is useful for things like squid proxy or torrent clients with web UI.
APP_LAN_IP="192.168.42.80/24"


ip link add name br_pf_vmux mtu 1420 type bridge
ip link set br_app up

# vmux_app namespace veth
ip link add pf_app_tap type veth peer name pf_tap
ip link set pf_tap netns vmux_app
ip netns exec vmux_app ip link set pf_tap up
ip netns exec vmux_app ip link set pf_tap master br_app
ip link set pf_app_tap master br_pf_vmux
ip link set pf_app_tap up
