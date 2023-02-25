#!/bin/bash

virsh destroy pfsense_vmux

ip netns | grep vmux | awk '{print $1}' | xargs -L 1 ip netns del
ip l del vmux_app_tap
ip l del pf_app_tap
ip l del br_pf_vmux