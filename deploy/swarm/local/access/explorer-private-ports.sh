#!/bin/sh
set -eu
# Docker publishing bypasses UFW. Limit these backend ports to local proxies/SSH.
for port in 18110 18112; do
    iptables -C INPUT ! -i lo -p tcp --dport "$port" -j DROP 2>/dev/null || iptables -I INPUT ! -i lo -p tcp --dport "$port" -j DROP
    iptables -C DOCKER-USER -p tcp -m conntrack --ctorigdstport "$port" -j DROP 2>/dev/null || iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport "$port" -j DROP
    ip6tables -C INPUT ! -i lo -p tcp --dport "$port" -j DROP 2>/dev/null || ip6tables -I INPUT ! -i lo -p tcp --dport "$port" -j DROP
    ip6tables -C FORWARD -p tcp -m conntrack --ctorigdstport "$port" -j DROP 2>/dev/null || ip6tables -I FORWARD -p tcp -m conntrack --ctorigdstport "$port" -j DROP
done
