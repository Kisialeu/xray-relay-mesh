#!/bin/sh
apk add --no-cache python3
python3 /opt/xray-node/stats.py &
exec xray run -confdir /etc/xray/
