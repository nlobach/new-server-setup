#!/bin/bash

PORT_LIST=32000
SOURCE_TO_ALLOW=192.168.2.0/24

if [ -n "$(iptables-save | grep KUBE-NODEPORTS)" ]; then
    IPTABLES=iptables
else
    IPTABLES=iptables-legacy
fi

wait-for-it.sh localhost:32000 -t 0 -- $IPTABLES -t nat -I KUBE-NODEPORTS 1 ! --source $SOURCE_TO_ALLOW -p tcp -m multiport --destination-port $PORT_LIST -j RETURN
