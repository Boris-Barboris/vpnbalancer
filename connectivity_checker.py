#!/usr/bin/env python3

# This script is periodically checking vpn namespaces
# and disables or enables their south-bound veth-pairs
# in order to signal kernel's ECMP to stop routing
# flows to this namespace

import logging
import os
import re
import subprocess
import sys
import time


CHECK_INTERVAL_ALIVE = 30
CHECK_INTERVAL_DEAD = 10

logging.basicConfig(stream=sys.stdout, level=logging.INFO)
log = logging.getLogger(__name__)


def is_tun_present(namespace_name: str) -> bool:
    cmd = "ip netns exec " + namespace_name + " ip l | grep tun"
    result = subprocess.run(cmd, shell=True, stdout=subprocess.DEVNULL)
    return result.returncode == 0


def is_namespace_alive(namespace_name: str) -> bool:
    if not is_tun_present(namespace_name):
        log.debug("tun device is absent")
        return False
    cmd = "ip netns exec " + namespace_name + " nc -z -w3 8.8.8.8 443"
    result = subprocess.run(cmd, shell=True)
    return result.returncode == 0


def get_ns_number(namespace_name: str) -> str:
    return re.findall(r'\d+', namespace_name)[-1]


def set_veth_state(namespace_name: str, namespace_number: str, isUp: bool):
    veth_name = f"app_vpn{namespace_number}_n"
    state = "up" if isUp else "down"
    cmd = f"ip netns exec {namespace_name} ip l set {veth_name} {state}"
    log.debug(cmd)
    subprocess.run(cmd, shell=True)


def main():
    namespace_name = sys.argv[1]
    namespace_number = get_ns_number(namespace_name)
    vpn_alive = True
    while True:
        vpn_alive = is_namespace_alive(namespace_name)
        if vpn_alive:
            log.debug("%s is alive", namespace_name)
            set_veth_state(namespace_name, namespace_number, True)
            time.sleep(CHECK_INTERVAL_ALIVE)
        else:
            log.info("%s is dead", namespace_name)
            set_veth_state(namespace_name, namespace_number, False)
            time.sleep(CHECK_INTERVAL_DEAD)


if __name__ == '__main__':
    main()