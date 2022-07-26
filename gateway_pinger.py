#!/usr/bin/env python3

# This script is periodically pinging every default gateway

import json
import logging
import subprocess
import sys
import time


PING_INTERVAL = 30

logging.basicConfig(stream=sys.stdout, level=logging.INFO)
log = logging.getLogger(__name__)


def get_nexthops() -> [str]:
    cmd = 'ip -j r'
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    routes = json.loads(result.stdout)
    dr_nexthops = next((route['nexthops'] for route in routes if route['dst'] == 'default'))
    return [hop['gateway'] for hop in dr_nexthops]


def ping_address(addr: str):
    cmd = "ping -q -n -c 1 -W 1 " + addr
    result = subprocess.run(cmd, shell=True, stdout=subprocess.DEVNULL)
    return result.returncode == 0



def main():
    nexthops = get_nexthops()
    if not nexthops:
        raise Exception("No nexthops detected")
    log.info("Detected gateways: %s", nexthops)
    while True:
        for hop in nexthops:
            ping_address(hop)
            time.sleep(PING_INTERVAL)


if __name__ == '__main__':
    main()