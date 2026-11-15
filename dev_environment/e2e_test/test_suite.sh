#!/usr/bin/env bash
set -eux
export GOCOVERDIR="/root/coverdata/int"
# this script needs to run as root account, check it
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit 1
fi
RED='\033[0;31m'
NC='\033[0m' # No Color
GREEN='\033[0;32m'

close() {
    files=("err" "progids.txt" "tmp" "output.json" "names.txt" "map_names.txt" "l3afd.log")
    for d in ${files[@]}; do
        if test -f $d; then
            rm $d
        fi
    done
}

logerr() {
    str=$1
    close
    printf "${RED} error: ${str} ${NC}\n"
    exit 1
}

logsuc() {
    str=$1
    printf "${GREEN}${str}${NC}\n"
}

# log_has - greps a running l3afd's stdout for a pattern without ever
# blocking the suite. l3afd's fd/1 is normally a redirected regular file
# (safe to grep even after close() unlinks it, since the process still
# holds the inode open), but when l3afd is started without redirection
# (e.g. the plain, non --ci-build dev flow) fd/1 can be a tty/pipe that
# would hang `grep -q` forever; `timeout` bounds that.
log_has() {
    pattern=$1
    pid=$2
    timeout 5 grep -qE -- "$pattern" /proc/${pid}/fd/1 2>/dev/null
}

# log_readable - true if the target l3afd's stdout is something grep-able
# (a redirected regular file, even one later unlinked by close() - the
# process still holds the inode open). False for a tty/pipe, e.g. when
# l3afd was started without redirection (the plain, non --ci-build dev
# flow), where log_has would otherwise hang/timeout.
log_readable() {
    [ -r "/proc/$1/fd/1" ]
}

IP=192.168.15.80
# traffic_gen provide traffic for give direction testing. Optional $2 is a
# target IP for the ingress case, defaulting to ibpfbr's address - used by
# the stale-interface tests to aim traffic at stale0/stale1 instead.
traffic_gen() {
    local target_ip=${2:-192.168.15.80}
    if [ $1 == "ingress" ]; then
        ip netns exec bpf bash -c "hey -n 2000 -c 200 http://${target_ip}:8080" >/dev/null
    elif [ $1 == "egress" ]; then
        hey -n 2000 -c 200 http://192.168.15.1:8080 >/dev/null
    else
        echo "Provide valid direction"
        exit 1
    fi
}

validate() {
    exp_output=$1
    api_name=$2
    touch progids.txt tmp output.json names.txt err
    curl -sS http://${IP}:7080/l3af/configs/v1/ibpfbr >output.json 2>&1
    echo >>output.json
    if cmp -s output.json /root/l3af-arch/dev_environment/e2e_test/$exp_output; then
        curl -sS http://${IP}:8899/bpfs/ibpfbr | jq ".[].ProgID" >progids.txt 2>err
        if [ -s err ]; then
            cat err
            logerr "curl request to debug api failed"
        fi
        curl -sS http://$IP:8899/bpfs/ibpfbr | jq ".[].Program.name" >names.txt 2>err
        if [ -s err ]; then
            cat err
            logerr "curl request to debug api failed"
        fi
        curl -sS http://$IP:8899/bpfs/ibpfbr | jq ".[].Program.map_name" >map_names.txt 2>err
        if [ -s err ]; then
            cat err
            log err "curl request to debug api failed"
        fi
        idarray=()
        while IFS= read -r line; do
            idarray+=("$line")
        done <"progids.txt"
        for str in "${idarray[@]}"; do
            bpftool prog show id $str >tmp
            if [ ! -s tmp ]; then
                logerr "Program with ProgID ${str} is not running"
            fi
            cat /dev/null >tmp
        done
        cl_datapath_verification "ingress"
        rl_datapath_verification "ingress"
        tm_datapath_verification "ingress"
        tm_datapath_verification "egress"
        ipfix_datapath_verification "ingress"
        ipfix_datapath_verification "egress"
        logsuc "$api_name API SUCCESS"
        printf "\n"
    else
        diff /root/l3af-arch/dev_environment/e2e_test/$exp_output output.json
        logerr "$api_name API FAILED"
        printf "\n"
    fi
}

# rl_datapath_verification - $1 direction, optional $2 target IP. When $2 is
# given (stale-interface tests, pointed at stale0/stale1), the names.txt gate
# is skipped (that file only ever describes ibpfbr) and, since a stale-reload
# recovery starts from a brand-new, freshly-zeroed map, the check requires a
# strict increase rather than just "changed" - otherwise a new map's lower
# absolute value relative to the old program's leftover baseline would read
# as a negative, non-zero delta and falsely pass with no traffic processed.
rl_datapath_verification() {
    local direction=$1
    local target_ip=${2:-}
    if [ -n "$target_ip" ] || grep -q "ratelimiting" names.txt; then
        if [ -n "$target_ip" ]; then
            # Give bpfmetrics.go's 1s publish ticker a couple of cycles to
            # catch up to the just-reloaded program's new map before sampling.
            sleep 2
        fi
        before_rl_drop_count=$(curl -sS $IP:8898/metrics | grep rl_drop_count_map_0_scalar | tail -1 | awk '{print $NF}')
        before_rl_drop_count=${before_rl_drop_count:-0}
        for i in {1..100}; do
            traffic_gen "$direction" "$target_ip"
            after_rl_drop_count=$(curl -sS $IP:8898/metrics | grep rl_drop_count_map_0_scalar | tail -1 | awk '{print $NF}')
            after_rl_drop_count=${after_rl_drop_count:-0}
            if [ -n "$target_ip" ]; then
                if [[ $((after_rl_drop_count - before_rl_drop_count)) -gt 0 ]]; then
                    logsuc "ratelimiting updated the metrics maps"
                    return
                fi
            else
                if [[ $((after_rl_drop_count - before_rl_drop_count)) -ne 0 ]]; then
                    logsuc "ratelimiting updated the metrics maps"
                    return
                fi
            fi
            sleep 1
        done
        logerr "ratelimiting not updating maps"
    fi
}

# cl_datapath_verification - see rl_datapath_verification for the optional
# $2 target-IP / strict-increase rationale (used by the stale ROOT interface
# test, where connection-limit is chained behind xdp-root).
cl_datapath_verification() {
    local direction=$1
    local target_ip=${2:-}
    if [ -n "$target_ip" ] || grep -q "connection-limit" names.txt; then
        if [ -n "$target_ip" ]; then
            sleep 2
        fi
        before_cl_recv_count=$(curl -sS $IP:8898/metrics | grep cl_recv_count_map_0_scalar | tail -1 | awk '{print $NF}')
        before_cl_recv_count=${before_cl_recv_count:-0}
        for i in {1..100}; do
            traffic_gen "$direction" "$target_ip"
            after_cl_recv_count=$(curl -sS $IP:8898/metrics | grep cl_recv_count_map_0_scalar | tail -1 | awk '{print $NF}')
            after_cl_recv_count=${after_cl_recv_count:-0}
            if [ -n "$target_ip" ]; then
                if [[ $((after_cl_recv_count - before_cl_recv_count)) -gt 0 ]]; then
                    logsuc "connection-limit updated the metrics maps"
                    return
                fi
            else
                if [ $((after_cl_recv_count - before_cl_recv_count)) -ne 0 ]; then
                    logsuc "connection-limit updated the metrics maps"
                    return
                fi
            fi
            sleep 1
        done
        logerr "connection-limit not updating the metrics maps"
    fi
}

ipfix_datapath_verification() {
    mapname="ipfix_$1_jmp_table"
    if grep -q "ipfix-flow-exporter" names.txt && grep -q $mapname map_names.txt; then
        touch first first_err second second_err
        tcpdump -i ibpfbr port 8080 -c 2 >first 2>first_err &
        tcpdump -i lo port 49280 -c 2 >second 2>second_err &
        sleep 4
        traffic_gen $1
        for i in {1..100}; do
            if [[ $(cat first | wc -l) -gt 0 ]] && [[ $(cat second | wc -l) -gt 0 ]]; then
                logsuc "ipfix-flow-exporter ($1) collector is receiving packets"
                rm first second first_err second_err
                return
            fi
            sleep 1
        done
        rm first second first_err second_err
        logerr "ipfix-flow-exporter ($1) collector not receiving packets"
    fi
}

tm_datapath_verification() {
    mapname="mirroring_$1_jmp_table"
    if grep -q "traffic-mirroring" names.txt && grep -q $mapname map_names.txt; then
        touch tm_first tm_first_err
        touch tm_second tm_second_err
        tcpdump -i gue1 -c 2 >tm_first 2>tm_first_err &
        tcpdump -i lo udp and port 6081 -c 2 >tm_second 2>tm_second_err &
        sleep 4
        traffic_gen $1
        for i in {1..100}; do
            if [[ $(cat tm_first | wc -l) -gt 0 ]] && [[ $(cat tm_second | wc -l) -gt 0 ]]; then
                logsuc "traffic-mirroring ($1) mirroring the packets"
                rm tm_first tm_first_err
                rm tm_second tm_second_err
                return
            fi
            sleep 1
        done
        cat tm_first_err
        cat tm_second_err
        rm tm_first tm_first_err
        rm tm_second tm_second_err
        logerr "traffic-mirroring ($1) not mirroring the packets"
    fi
}

stale_interface_detection_test() {
    local iface="stale0"
    local payload_dir="/root/l3af-arch/dev_environment/e2e_test"

    touch stale_err stale_tmp

    curl --max-time 120 -v -X POST http://${IP}:7080/l3af/configs/v1/add \
        -H "Content-Type: application/json" \
        -d "@${payload_dir}/add_stale_payload.json"
    if [ $? -ne 0 ]; then
        rm -f stale_err stale_tmp
        logerr "stale interface test: curl request to the add API failed"
        return
    fi
    sleep 5

    initial_progid=$(curl -sS http://${IP}:8899/bpfs/${iface} | jq ".[0].ProgID" || true)
    if [ -z "$initial_progid" ] || [ "$initial_progid" == "null" ]; then
        rm -f stale_err stale_tmp
        logerr "stale interface test: program failed to attach to ${iface}"
        return
    fi
    bpftool prog show id $initial_progid >stale_tmp 2>stale_err
    if [ ! -s stale_tmp ]; then
        cat stale_err
        rm -f stale_err stale_tmp
        logerr "stale interface test: initial ProgID ${initial_progid} is not running"
        return
    fi
    logsuc "stale interface test: ${iface} attached with ProgID ${initial_progid}"

    # Baseline: prove traffic is actually flowing through the program before
    # staleness is induced, so a later failure of the post-recovery check is
    # unambiguous (not just a pre-existing datapath problem).
    rl_datapath_verification "ingress" "192.168.20.80"

    # Simulate a stale interface attachment WITHOUT tearing down the
    # program's link: rename the live interface out of the way (its
    # ifindex, and the already-attached XDP link, stay intact) and create a
    # brand-new device under the original name "stale0" with a fresh
    # ifindex. l3afd still believes its program is attached to "stale0",
    # but net.InterfaceByName("stale0") now resolves to a different
    # ifindex than the link actually reports - exactly the mismatch
    # BPF.isAttachedToInterface()/ifindexMatches() is meant to catch. The
    # next health-check tick (web.ebpf-poll-interval in l3afd.cfg) must
    # detect this via IsLoaded() and re-attach the program to the new
    # "stale0" device.
    #
    # The IP (192.168.20.80) and the netns-bpf peer (192.168.20.1) both
    # follow the rename to the old device, so they're explicitly moved onto
    # the new pair too - otherwise there would be no way to drive traffic at
    # the new "stale0" afterwards to prove the recovered program works.
    ip addr flush dev ${iface}
    ip link set dev ${iface} down
    ip link set dev ${iface} name ${iface}-old
    ip link set dev ${iface}-old up
    ip netns exec bpf ip addr flush dev ${iface}-peer || true
    ip netns exec bpf ip link set ${iface}-peer down || true

    ip link add ${iface} type veth peer name ${iface}-new-peer
    ip addr add 192.168.20.80/24 dev ${iface}
    ip link set ${iface} up
    ip link set ${iface}-new-peer netns bpf
    ip netns exec bpf ip addr add 192.168.20.1/24 dev ${iface}-new-peer
    ip netns exec bpf ip link set ${iface}-new-peer up

    new_progid=""
    for i in {1..100}; do
        candidate=$(curl -sS http://${IP}:8899/bpfs/${iface} | jq ".[0].ProgID" 2>/dev/null || true)
        if [ -n "$candidate" ] && [ "$candidate" != "null" ] && [ "$candidate" != "$initial_progid" ]; then
            bpftool prog show id $candidate >stale_tmp 2>stale_err
            if [ -s stale_tmp ]; then
                new_progid=$candidate
                break
            fi
        fi
        sleep 1
    done

    l3afdID=$(pgrep l3afd | head -1)
    if [ -z "$new_progid" ]; then
        timeout 5 grep -E "pMonitorWorker|does not match interface|start failed" /proc/${l3afdID}/fd/1 2>/dev/null | tail -20 || true
        rm -f stale_err stale_tmp
        logerr "stale interface detection FAILED: program on ${iface} was not re-attached after ifindex change (still ProgID ${initial_progid})"
        return
    fi
    # api_runner's close() unlinks l3afd.log after every prior API call, but
    # l3afd still holds that (now-unlinked) file open as its stdout, so the
    # full log history is still readable via its /proc fd. Match the
    # ifindex-mismatch message specifically (isAttachedToInterface in
    # bpf_unix.go), not the generic "no longer attached" wrapper in
    # IsLoaded(), which also fires when a link is torn down outright - the
    # failure mode this rename-based scenario is designed to rule out.
    if log_readable "$l3afdID"; then
        if ! log_has "does not match interface ${iface}" "$l3afdID"; then
            rm -f stale_err stale_tmp
            logerr "stale interface detection FAILED: ProgID changed to ${new_progid}, but l3afd never logged the ifindex-mismatch warning for ${iface}"
            return
        fi
        logsuc "stale interface detection SUCCESS: ${iface} re-attached, new ProgID ${new_progid}, stale-attachment warning logged"
    else
        logsuc "stale interface detection SUCCESS: ${iface} re-attached, new ProgID ${new_progid} (l3afd stdout not redirected to a file, skipped log assertion)"
    fi

    # The real proof the fix works end-to-end: the recovered program must
    # actually process traffic again, not just show a new ProgID.
    rl_datapath_verification "ingress" "192.168.20.80"

    curl --max-time 120 -v -X POST http://${IP}:7080/l3af/configs/v1/delete \
        -H "Content-Type: application/json" \
        -d "@${payload_dir}/del_stale_payload.json"
    # Tear down the new pair and restore the original stale0/stale0-peer
    # pair (renaming back, re-adding the IPs that were flushed above) so the
    # fixture is left as prep_env.sh created it, in case the suite is ever
    # re-run against the same VM.
    ip link delete ${iface} || true
    ip link set dev ${iface}-old down || true
    ip link set dev ${iface}-old name ${iface} || true
    ip addr add 192.168.20.80/24 dev ${iface} || true
    ip link set dev ${iface} up || true
    ip netns exec bpf ip addr add 192.168.20.1/24 dev ${iface}-peer || true
    ip netns exec bpf ip link set ${iface}-peer up || true
    rm -f stale_err stale_tmp
}

stale_root_interface_detection_test() {
    local iface="stale1"
    local payload_dir="/root/l3af-arch/dev_environment/e2e_test"

    touch stale_err stale_tmp

    # This test must run while bpf-chaining-enabled: true. Only then does
    # l3afd create a separate "xdp-root" dispatcher program (SeqID 0) that
    # owns the real kernel XDP link - chained children (SeqID>0) are reached
    # via the root's tail-call map, not via their own link, so only the
    # root's interface attachment can ever go stale.
    curl --max-time 120 -v -X POST http://${IP}:7080/l3af/configs/v1/add \
        -H "Content-Type: application/json" \
        -d "@${payload_dir}/add_stale_root_payload.json"
    if [ $? -ne 0 ]; then
        rm -f stale_err stale_tmp
        logerr "stale root interface test: curl request to the add API failed"
        return
    fi
    sleep 5

    initial_root_progid=$(curl -sS http://${IP}:8899/bpfs/${iface} | jq '[.[] | select(.Program.name=="xdp-root")][0].ProgID' || true)
    if [ -z "$initial_root_progid" ] || [ "$initial_root_progid" == "null" ]; then
        rm -f stale_err stale_tmp
        logerr "stale root interface test: xdp-root program failed to attach to ${iface}"
        return
    fi
    bpftool prog show id $initial_root_progid >stale_tmp 2>stale_err
    if [ ! -s stale_tmp ]; then
        cat stale_err
        rm -f stale_err stale_tmp
        logerr "stale root interface test: initial root ProgID ${initial_root_progid} is not running"
        return
    fi
    logsuc "stale root interface test: xdp-root attached to ${iface} with ProgID ${initial_root_progid}"

    # Baseline: prove traffic is actually flowing through both chained
    # programs (ratelimiting seq_id 1, connection-limit seq_id 2, reached via
    # xdp-root's tail call) before staleness is induced, so a later failure
    # of the post-recovery checks is unambiguous.
    rl_datapath_verification "ingress" "192.168.21.80"
    cl_datapath_verification "ingress" "192.168.21.80"

    # Same rename trick as stale_interface_detection_test: the live
    # interface (and its still-valid XDP link) is renamed out of the way,
    # and a brand-new device takes over the original name with a fresh
    # ifindex, so "${iface}" now resolves to a different ifindex than the
    # root program's link actually reports. The IP and the netns-bpf peer
    # both follow the rename, so they're moved onto the new pair too -
    # otherwise there'd be no way to drive traffic at the recovered root
    # afterwards.
    ip addr flush dev ${iface}
    ip link set dev ${iface} down
    ip link set dev ${iface} name ${iface}-old
    ip link set dev ${iface}-old up
    ip netns exec bpf ip addr flush dev ${iface}-peer || true
    ip netns exec bpf ip link set ${iface}-peer down || true

    ip link add ${iface} type veth peer name ${iface}-new-peer
    ip addr add 192.168.21.80/24 dev ${iface}
    ip link set ${iface} up
    ip link set ${iface}-new-peer netns bpf
    ip netns exec bpf ip addr add 192.168.21.1/24 dev ${iface}-new-peer
    ip netns exec bpf ip link set ${iface}-new-peer up

    new_root_progid=""
    for i in {1..100}; do
        candidate=$(curl -sS http://${IP}:8899/bpfs/${iface} | jq '[.[] | select(.Program.name=="xdp-root")][0].ProgID' 2>/dev/null || true)
        if [ -n "$candidate" ] && [ "$candidate" != "null" ] && [ "$candidate" != "$initial_root_progid" ]; then
            bpftool prog show id $candidate >stale_tmp 2>stale_err
            if [ -s stale_tmp ]; then
                new_root_progid=$candidate
                break
            fi
        fi
        sleep 1
    done

    l3afdID=$(pgrep l3afd | head -1)
    if [ -z "$new_root_progid" ]; then
        timeout 5 grep -E "pMonitorWorker|does not match interface|reload/relink failed|reloaded and relinked" /proc/${l3afdID}/fd/1 2>/dev/null | tail -20 || true
        rm -f stale_err stale_tmp
        logerr "stale root interface detection FAILED: xdp-root on ${iface} was not reloaded after ifindex change (still ProgID ${initial_root_progid})"
        return
    fi
    if log_readable "$l3afdID"; then
        if ! log_has "does not match interface ${iface}" "$l3afdID"; then
            rm -f stale_err stale_tmp
            logerr "stale root interface detection FAILED: root ProgID changed to ${new_root_progid}, but l3afd never logged the ifindex-mismatch warning for ${iface}"
            return
        fi
        if ! log_has "on iface ${iface} .*reloaded and relinked" "$l3afdID"; then
            rm -f stale_err stale_tmp
            logerr "stale root interface detection FAILED: root ProgID changed, but l3afd never logged the root-reload-and-relink success message for ${iface}"
            return
        fi
    else
        logsuc "stale root interface detection: l3afd stdout not redirected to a file, skipped log assertions for ${iface}"
    fi

    # The chained children are never individually relinked - only the
    # reloaded root's tail-call map entries are repointed at them - so
    # confirm both are still present and running after the root reload.
    child_progid=$(curl -sS http://${IP}:8899/bpfs/${iface} | jq '[.[] | select(.Program.name=="ratelimiting")][0].ProgID' || true)
    if [ -z "$child_progid" ] || [ "$child_progid" == "null" ]; then
        rm -f stale_err stale_tmp
        logerr "stale root interface detection FAILED: ratelimiting child program missing from ${iface} after root reload"
        return
    fi
    bpftool prog show id $child_progid >stale_tmp 2>stale_err
    if [ ! -s stale_tmp ]; then
        cat stale_err
        rm -f stale_err stale_tmp
        logerr "stale root interface detection FAILED: ratelimiting child ProgID ${child_progid} is not running after root reload"
        return
    fi

    cl_child_progid=$(curl -sS http://${IP}:8899/bpfs/${iface} | jq '[.[] | select(.Program.name=="connection-limit")][0].ProgID' || true)
    if [ -z "$cl_child_progid" ] || [ "$cl_child_progid" == "null" ]; then
        rm -f stale_err stale_tmp
        logerr "stale root interface detection FAILED: connection-limit child program missing from ${iface} after root reload"
        return
    fi
    bpftool prog show id $cl_child_progid >stale_tmp 2>stale_err
    if [ ! -s stale_tmp ]; then
        cat stale_err
        rm -f stale_err stale_tmp
        logerr "stale root interface detection FAILED: connection-limit child ProgID ${cl_child_progid} is not running after root reload"
        return
    fi

    logsuc "stale root interface detection SUCCESS: xdp-root on ${iface} reloaded and relinked, new ProgID ${new_root_progid}, children ${child_progid}/${cl_child_progid} still running"

    # The real proof the root-reload fix works end-to-end: traffic must
    # actually tail-call through to both chained programs again, not just
    # show a new root ProgID.
    rl_datapath_verification "ingress" "192.168.21.80"
    cl_datapath_verification "ingress" "192.168.21.80"

    curl --max-time 120 -v -X POST http://${IP}:7080/l3af/configs/v1/delete \
        -H "Content-Type: application/json" \
        -d "@${payload_dir}/del_stale_root_payload.json"
    ip link delete ${iface} || true
    ip link set dev ${iface}-old down || true
    ip link set dev ${iface}-old name ${iface} || true
    ip addr add 192.168.21.80/24 dev ${iface} || true
    ip link set dev ${iface} up || true
    ip netns exec bpf ip addr add 192.168.21.1/24 dev ${iface}-peer || true
    ip netns exec bpf ip link set ${iface}-peer up || true
    rm -f stale_err stale_tmp
}

api_runner() {
    api_name=$1
    payload="/root/l3af-arch/dev_environment/e2e_test/$2"
    exp_output=$3
    curl --max-time 120 -v -X POST http://${IP}:7080/l3af/configs/v1/${api_name} -H "Content-Type: application/json" -d "@${payload}"
    if [ $? -ne 0 ]; then
        logerr "curl request to the ${api_name} API falied"
        return
    fi
    validate $exp_output $api_name
    close
}

do_graceful_restart() {
    payload="/root/l3af-arch/dev_environment/e2e_test/restart.json"
    old_pid=$(cat /var/run/l3afd.pid)
    curl --max-time 120 -v -X PUT http://${IP}:7080/l3af/configs/v1/restart -H "Content-Type: application/json" -d "@${payload}"
    if [ $? -ne 0 ]; then
        logerr "curl request to the restart API falied"
        return 
    fi
    sleep 5
    if [ $(cat /var/run/l3afd.pid) -eq $old_pid ]; then
        logerr "curl request to the restart API falied"
        return 
    fi
    logsuc "Restart API is successful"
}
sleep 5
echo "with chaining"
api_runner "add" "add_payload.json" "exp_output_1.json"
sleep 2
do_graceful_restart
sleep 5
api_runner "update" "upd_payload.json" "exp_output_2.json"
sleep 2
api_runner "add" "add_tm_payload.json" "exp_output_3.json"
sleep 2
do_graceful_restart
sleep 5
api_runner "delete" "del_ipfix_payload.json" "exp_output_4.json"
sleep 2
api_runner "delete" "del_payload.json" "exp_output_nil.json"

echo "stale root interface detection"
# Must run here, in the with-chaining phase: xdp-root only exists, and only
# owns a real kernel XDP link, when bpf-chaining-enabled: true.
stale_root_interface_detection_test

l3afdID=$(pgrep l3afd)
kill -2 $l3afdID
rm -f /var/l3afd/l3af-config.json
sed -i --follow-symlinks 's/bpf-chaining-enabled: true/bpf-chaining-enabled: false/' $(readlink -f /usr/local/l3afd/latest/l3afd.cfg)

/usr/local/l3afd/latest/l3afd --config /usr/local/l3afd/latest/l3afd.cfg >l3afd.log 2>&1 &
sleep 5

echo "without chaining"
api_runner "add" "add_without_chaining_payload.json" "exp_output_5.json"
sleep 2
do_graceful_restart
sleep 5
api_runner "update" "upd_without_chaining_payload.json" "exp_output_6.json"
sleep 2
api_runner "delete" "del_without_chaining_payload.json" "exp_output_nil.json"
sleep 2
api_runner "add" "add_tm_payload.json" "exp_output_7.json"
sleep 2
api_runner "delete" "del_tm_payload.json" "exp_output_nil.json"

echo "stale interface detection"
# Must run here, in the no-chaining phase: b.Link (and therefore
# isAttachedToInterface's ifindex check) is only populated by the
# non-chained LoadXDPAttachProgram path. With chaining enabled the
# program is tail-called via the root prog's map and this check
# short-circuits, making the test vacuous.
stale_interface_detection_test

l3afdID=$(pgrep l3afd)
kill -2 $l3afdID


# TEST COVERAGE
TESTCOVERAGE_THRESHOLD=50
echo "Quality Gate: checking test coverage is above threshold ..."
echo "Threshold             : $TESTCOVERAGE_THRESHOLD %"

cd /root/l3afd
EXCLUDE_DIRS="docs|mocks|models|config|pidfile|routes|stats|utils"
# Race check runs standalone (no -cover): -race forces "atomic" coverage
# counter mode, which clashes with the "set" mode counters recorded by the
# running l3afd binary in /root/coverdata/int, and covdata merge cannot mix
# the two modes.
/usr/local/go/bin/go test -race $(go list ./... | grep -Ev "${EXCLUDE_DIRS}")
/usr/local/go/bin/go test -cover $(go list ./... | grep -Ev "${EXCLUDE_DIRS}") -args -test.gocoverdir="/root/coverdata/unit"
/usr/local/go/bin/go tool covdata merge -i=/root/coverdata/int,/root/coverdata/unit -o /root/coverdata/combined
/usr/local/go/bin/go tool covdata textfmt -i=/root/coverdata/combined -o profile.txt
cov=$(go tool cover -func=profile.txt | grep total | awk '{print $3}' | tr -d %)
rm -rf profile.txt
totalCoverage=$(echo "($cov+0.5)/1" | bc)
echo "Current test coverage : $totalCoverage %"

if [[ $totalCoverage -ge $TESTCOVERAGE_THRESHOLD ]]; then
	logsuc "OK"
else
	logerr "Current test coverage is below threshold. Please add more unit tests or adjust threshold to a lower value."
	logerr "Failed"
	close
	exit 1

fi
logsuc "TEST COMPLETED"
close
