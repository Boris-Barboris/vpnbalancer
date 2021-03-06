#!/bin/bash

set -eux

# n suffix = north
# s suffix = south

# number of vpn namespaces, should be equal to number of openvpn clients you are going to run.
NS_COUNT=3
# name of main bridge in default namespace tapped into your LAN.
DEFAULT_NS_BRIDGE="br_main"
# in order to access processes in app namespace from LAN, firewall must know LAN subnet CIDR.
LAN_SUBNET="192.168.1.0/24"
# default gateway in your LAN that should route traffic to the internet. Effectively, your router IP.
LAN_DEFAULT_GW="192.168.1.254"
# IP to assign to NAT egress interface. Must be statically allocated from your LAN subnet.
NAT_EGRESS_IP="192.168.1.85/24"
# IP to assign to app namespace bridge. Must be statically allocated from your LAN subnet.
# Through this IP you can access servers that use vmux_app namespace and
# route internet traffic through VPNs but can still respond to LAN requests.
# This is useful for things like squid proxy or torrent clients with web UI.
APP_LAN_IP="192.168.1.80/24"

# these may be unneeded in your configuration
echo 1 > /proc/sys/net/ipv4/conf/all/rp_filter
echo 1 > /proc/sys/net/ipv4/conf/default/rp_filter

# northern SNAT namespace
ip netns add vmux_nat
ip netns exec vmux_nat bash -c "echo 1 > /proc/sys/net/ipv4/conf/default/forwarding"
ip link add vmux_nat_veth_n type veth peer name vmux_nat_veth_s
ip link set vmux_nat_veth_s netns vmux_nat
ip link set vmux_nat_veth_n master $DEFAULT_NS_BRIDGE
ip link set vmux_nat_veth_n up
ip netns exec vmux_nat ip addr add $NAT_EGRESS_IP dev vmux_nat_veth_s
ip netns exec vmux_nat ip link set vmux_nat_veth_s up
ip netns exec vmux_nat ip route add default via $LAN_DEFAULT_GW dev vmux_nat_veth_s
ip netns exec vmux_nat iptables -w -t nat -I POSTROUTING -o vmux_nat_veth_s -j MASQUERADE
ip netns exec vmux_nat ip link set lo up

# southern namespace for applications under vpn
ip netns add vmux_app
ip netns exec vmux_app ip link add name br_app type bridge
ip netns exec vmux_app ip addr add 192.168.201.1/24 dev br_app
ip netns exec vmux_app ip link set br_app up
ip netns exec vmux_app ip link set lo up

# connect br_main to br_app via tap, making namespaced apps accesible in native LAN
ip link add vmux_app_tap type veth peer name def_tap
ip netns exec vmux_app ip addr add $APP_LAN_IP dev br_app
ip link set def_tap netns vmux_app
ip netns exec vmux_app ip link set def_tap master br_app
ip netns exec vmux_app ip link set def_tap up
ip link set vmux_app_tap master $DEFAULT_NS_BRIDGE
ip netns exec vmux_app ip -6 addr flush br_app
ip link set vmux_app_tap up

# VPN routing namespaces

function create_vpn_ns() {
    ip netns add vmux_vpn${1}
    ip netns exec vmux_vpn${1} bash -c "echo 1 > /proc/sys/net/ipv4/conf/default/forwarding"
    ip link add vmux_vpn${1}_n type veth peer name vmux_vpn${1}_s
    ip link set vmux_vpn${1}_n netns vmux_nat
    ip link set vmux_vpn${1}_s netns vmux_vpn${1}
    ip netns exec vmux_nat ip addr add 192.168.$((100 + $1)).254/24 dev vmux_vpn${1}_n
    ip netns exec vmux_vpn${1} ip addr add 192.168.$((100 + $1)).1/24 dev vmux_vpn${1}_s
    ip netns exec vmux_nat ip link set vmux_vpn${1}_n up
    ip netns exec vmux_vpn${1} ip link set vmux_vpn${1}_s up
    ip netns exec vmux_vpn${1} ip route add default via 192.168.$((100 + ${1})).254 dev vmux_vpn${1}_s
    ip netns exec vmux_vpn${1} ip link set lo up
    ip netns exec vmux_vpn${1} iptables -w -t nat -I POSTROUTING -o tun0 -j MASQUERADE # vmux_vpn${1}_s -> tun0

    # bind it with app ns via veth pair
    ip netns exec vmux_app ip link add app_vpn${1}_s type veth peer name app_vpn${1}_n
    ip netns exec vmux_app ip link set app_vpn${1}_n netns vmux_vpn${1}
    ip netns exec vmux_app ip link set app_vpn${1}_s master br_app
    ip netns exec vmux_vpn${1} ip addr add 192.168.201.$((100 + ${1}))/24 dev app_vpn${1}_n
    ip netns exec vmux_vpn${1} ip link set app_vpn${1}_n up
    ip netns exec vmux_app ip link set app_vpn${1}_s up
}

# southern namespace routing shenanigans
ip netns exec vmux_app ip route add default via 192.168.201.254 dev br_app    # this gateway does not exist
ip netns exec vmux_app iptables -w -I OUTPUT -t mangle -d $LAN_SUBNET -j ACCEPT
ip netns exec vmux_app iptables -w -A OUTPUT -t mangle -j CONNMARK --restore-mark
# rule to increase counter to 3 for connection in NEW conntrack state
ip netns exec vmux_app iptables -w -A OUTPUT -t mangle -m conntrack --ctstate NEW -m mark --mark 0x10000000/0xFFFF0000 -j MARK --set-mark 0x20000000/0xFFFF0000
ip netns exec vmux_app iptables -w -A OUTPUT -t mangle -m conntrack --ctstate NEW -m mark --mark 0x20000000/0xFFFF0000 -j MARK --set-mark 0
ip netns exec vmux_app iptables -w -A OUTPUT -t mangle -m conntrack --ctstate NEW -m mark --mark 0x0/0xFFFF0000 -j MARK --set-mark 0x10000000/0xFFFF0000
# ip netns exec vmux_app iptables -w -A OUTPUT -t mangle -m conntrack --ctstate NEW -m mark --mark 0x20000000/0xFFFF0000 -j MARK --set-mark 0x30000000/0x0
# and finally we drop the mark routing mark if we hit three retries
# just for new connections we spam save-mark
ip netns exec vmux_app iptables -w -A OUTPUT -t mangle -m conntrack --ctstate NEW -j CONNMARK --save-mark
# for packets with a routing mark we do nothing
ip netns exec vmux_app iptables -w -A OUTPUT -t mangle -m mark ! --mark 0/0x0000FFFF -j ACCEPT

# for packets without it we round-robin to vpn namespaces
i=1
while [[ $i -le $NS_COUNT ]]
do
    create_vpn_ns $i
    ip netns exec vmux_app ip rule add fwmark ${i}/0x0000ffff table $i
    ip netns exec vmux_app ip route add default via 192.168.201.$((100 + i)) table $i
    ip netns exec vmux_app iptables -w -A OUTPUT -t mangle -m statistic --mode nth --every $NS_COUNT --packet $((i - 1)) -j MARK --set-mark $i
    ((i = i + 1))
done

# fallback mark
# ip netns exec vmux_app iptables -w -A OUTPUT -t mangle -m mark --mark 0/0x0000FFFF -j MARK --set-mark 1
ip netns exec vmux_app iptables -w -A OUTPUT -t mangle -j CONNMARK --save-mark
