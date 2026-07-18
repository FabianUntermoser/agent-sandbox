#!/bin/bash
set -e
sudo /usr/local/bin/init-firewall.sh
exec "$@"
