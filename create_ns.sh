#!/bin/bash

set -eux

# n suffix = north
# s suffix = south

NS_COUNT=3

# northern SNAT namespace
ip netns add vmux_nat
ip link add vmux_nat_veth_n type veth peer name vmux_nat_veth_s
ip link set vmux_nat_veth_s netns vmux_nat
ip link set vmux_nat_veth_n master br_main
ip link set vmux_nat_veth_n up
ip netns exec vmux_nat ip addr add 192.168.1.85/24 dev vmux_nat_veth_s
ip netns exec vmux_nat ip link set vmux_nat_veth_s up
ip netns exec vmux_nat ip route add default via 192.168.1.254 dev vmux_nat_veth_s
ip netns exec vmux_nat iptables -w -t nat -I POSTROUTING -o vmux_nat_veth_s -j MASQUERADE
ip netns exec vmux_nat ip link set lo up

# southern namespace for applications under vpn
ip netns add vmux_app
ip netns exec vmux_app ip link add name br_app type bridge
ip netns exec vmux_app ip addr add 192.168.201.1/24 dev br_app
ip netns exec vmux_app ip link set br_app up
ip netns exec vmux_app ip link set lo up

# VPN routing namespaces

function create_vpn_ns() {
    ip netns add vmux_vpn${1}
    ip link add vmux_vpn${1}_n type veth peer name vmux_vpn${1}_s
    ip link set vmux_vpn${1}_n netns vmux_nat
    ip link set vmux_vpn${1}_s netns vmux_vpn${1}
    ip netns exec vmux_nat ip addr add 192.168.10${1}.254/24 dev vmux_vpn${1}_n
    ip netns exec vmux_vpn${1} ip addr add 192.168.10${1}.1/24 dev vmux_vpn${1}_s
    ip netns exec vmux_nat ip link set vmux_vpn${1}_n up
    ip netns exec vmux_vpn${1} ip link set vmux_vpn${1}_s up
    ip netns exec vmux_vpn${1} ip route add default via 192.168.10${1}.254 dev vmux_vpn${1}_s
    ip netns exec vmux_vpn${1} ip link set lo up
    ip netns exec vmux_vpn${1} iptables -w -t nat -I POSTROUTING -o tun0 -j MASQUERADE # vmux_vpn${1}_s -> tun0

    # bind it with app ns via veth pair
    ip netns exec vmux_app ip link add app_vpn${1}_s type veth peer name app_vpn${1}_n
    ip netns exec vmux_app ip link set app_vpn${1}_n netns vmux_vpn${1}
    ip netns exec vmux_app ip link set app_vpn${1}_s master br_app
    ip netns exec vmux_vpn${1} ip addr add 192.168.201.10${1}/24 dev app_vpn${1}_n
    ip netns exec vmux_vpn${1} ip link set app_vpn${1}_n up
    ip netns exec vmux_app ip link set app_vpn${1}_s up
}

# southern namespace routing shenanigans
ip netns exec vmux_app ip route add default via 192.168.201.254 dev br_app    # this gateway does not exist
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
    ip netns exec vmux_app ip route add default via 192.168.201.10${i} table $i
    ip netns exec vmux_app iptables -w -A OUTPUT -t mangle -m statistic --mode nth --every $NS_COUNT --packet $((i - 1)) -j MARK --set-mark $i
    ((i = i + 1))
done

# fallback mark
# ip netns exec vmux_app iptables -w -A OUTPUT -t mangle -m mark --mark 0/0x0000FFFF -j MARK --set-mark 1
ip netns exec vmux_app iptables -w -A OUTPUT -t mangle -j CONNMARK --save-mark
