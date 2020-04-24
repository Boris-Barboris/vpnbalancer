#!/bin/bash

set -eux

# n suffix = north
# s suffix = south

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

# VPN routing namespace
ip netns add vmux_vpn1
ip link add vmux_vpn1_n type veth peer name vmux_vpn1_s
ip link set vmux_vpn1_n netns vmux_nat
ip link set vmux_vpn1_s netns vmux_vpn1
ip netns exec vmux_nat ip addr add 192.168.101.254/24 dev vmux_vpn1_n
ip netns exec vmux_vpn1 ip addr add 192.168.101.1/24 dev vmux_vpn1_s
ip netns exec vmux_nat ip link set vmux_vpn1_n up
ip netns exec vmux_vpn1 ip link set vmux_vpn1_s up
ip netns exec vmux_vpn1 ip route add default via 192.168.101.254 dev vmux_vpn1_s
ip netns exec vmux_vpn1 ip link set lo up
ip netns exec vmux_vpn1 iptables -w -t nat -I POSTROUTING -o vmux_vpn1_s -j MASQUERADE

# southern namespace for applications under vpn
ip netns add vmux_app
ip netns exec vmux_app ip link add name br_app type bridge
ip netns exec vmux_app ip link add app_vpn1_s type veth peer name app_vpn1_n
ip netns exec vmux_app ip link set app_vpn1_n netns vmux_vpn1
ip netns exec vmux_app ip link set app_vpn1_s master br_app
ip netns exec vmux_app ip addr add 192.168.201.1/24 dev br_app
ip netns exec vmux_vpn1 ip addr add 192.168.201.101/24 dev app_vpn1_n
ip netns exec vmux_app ip link set br_app up
ip netns exec vmux_app ip link set app_vpn1_s up
ip netns exec vmux_vpn1 ip link set app_vpn1_n up

# southern namespace routing shenanigans
ip netns exec vmux_app ip route add default via 192.168.201.254 dev br_app    # this gateway does not exist
ip netns exec vmux_app ip rule add fwmark 1 table 1
ip netns exec vmux_app ip route add default via 192.168.201.101 table 1
ip netns exec vmux_app iptables -w -A OUTPUT -t mangle -j CONNMARK --restore-mark
ip netns exec vmux_app iptables -w -A OUTPUT -t mangle -m mark ! --mark 0 -j ACCEPT
ip netns exec vmux_app iptables -w -A OUTPUT -t mangle -s 192.168.201.1 -m statistic --mode nth --every 2 --packet 0 -j MARK --set-mark 1
ip netns exec vmux_app iptables -w -A OUTPUT -t mangle -j CONNMARK --save-mark