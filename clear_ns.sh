#!/bin/bash

ip netns | grep vmux | awk '{print $1}' | xargs -L 1 ip netns del
ip l del vmux_app_tap