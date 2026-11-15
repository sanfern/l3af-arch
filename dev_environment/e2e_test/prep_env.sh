#!/usr/bin/env bash
ip netns add bpf
ip link add ibpf type veth peer name ibpfbr
ip link set ibpf netns bpf
ip addr add 192.168.15.80/24 dev ibpfbr
ip -n bpf addr add 192.168.15.1/24 dev ibpf
ip -n bpf link set ibpf up
ip -n bpf link set lo up
ip link set ibpfbr up
modprobe fou
ip fou add port 6080 gue
ip fou add port 6081 gue
ip link add name gue1 type ipip remote 127.0.0.1 local 192.168.15.80  ttl 255 encap gue encap-sport 6080 encap-dport 6081 encap-csum encap-remcsum
ip link add name gue2 type ipip remote 192.168.15.80 local 127.0.0.1  ttl 255 encap gue encap-sport 6081 encap-dport 6080 encap-csum encap-remcsum
ip link set dev gue1 up
ip link set dev gue2 up

# Disposable veth pair used by the "stale interface detection" e2e test.
# Mid-test it gets renamed out of the way and a new device is created under
# the original name, so "stale0" ends up pointing at a different ifindex
# than the one l3afd's program is actually attached to. The peer end lives
# in netns "bpf" (like ibpf's) so the test can drive real traffic across the
# veth wire instead of taking the host's local-address shortcut, which is
# needed to prove the recovered program is actually processing packets.
ip link add stale0 type veth peer name stale0-peer
ip addr add 192.168.20.80/24 dev stale0
ip link set stale0 up
ip link set stale0-peer netns bpf
ip netns exec bpf ip addr add 192.168.20.1/24 dev stale0-peer
ip netns exec bpf ip link set stale0-peer up

# Disposable veth pair used by the "stale ROOT program interface" e2e test
# (with chaining enabled). Kept separate from stale0 so the two tests, which
# run in different phases of the suite, don't share mutable fixture state.
ip link add stale1 type veth peer name stale1-peer
ip addr add 192.168.21.80/24 dev stale1
ip link set stale1 up
ip link set stale1-peer netns bpf
ip netns exec bpf ip addr add 192.168.21.1/24 dev stale1-peer
ip netns exec bpf ip link set stale1-peer up
