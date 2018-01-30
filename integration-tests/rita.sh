#!/usr/bin/env bash
set -euo pipefail

build_babel () {
  if [ ! -d "deps/babeld" ] ; then
      git clone -b althea "https://github.com/althea-mesh/babeld" "deps/babeld"
  fi

  pushd deps/babeld
  make
  popd
}

fetch_netlab () {
  if [ ! -d "deps/network-lab" ] ; then
    git clone "https://github.com/sudomesh/network-lab" "deps/network-lab"
  fi
}

build_rita () {
  pushd ../rita
  cargo build
  popd
}

build_bounty () {
  pushd ../bounty_hunter
  cargo build
  rm -rf test.db
  diesel migration run
  popd
}

network_lab=deps/network-lab/network-lab.sh
babeld=deps/babeld/babeld
rita=../target/debug/rita
bounty=../target/debug/bounty_hunter

fail_string()
{
 if grep -q "$1" "$2"; then
   echo "FAILED: $1 in $2"
   exit 1
 fi
}

pass_string()
{
 if ! grep -q "$1" "$2"; then
   echo "FAILED: $1 not in $2"
   exit 1
 fi
}

stop_processes()
{
  set +eux
    for f in *.pid
    do
      sudo kill -9 "$(cat $f)"
    done
    sudo killall ping6
  set -eux
}

cleanup()
{
  rm -f ./*.pid
  rm -f ./*.log
  rm -f ./test.db
}

fetch_netlab
build_babel
build_rita
build_bounty

stop_processes
cleanup

sudo bash $network_lab << EOF
{
  "nodes": {
    "1": { "ip": "2001::1" },
    "2": { "ip": "2001::2" },
    "3": { "ip": "2001::3" }  

},
  "edges": [
     {
      "nodes": ["1", "2"],
      "->": "loss random 0%",
      "<-": "loss random 0%"
     },
     {
      "nodes": ["2", "3"],
      "->": "loss random 0%",
      "<-": "loss random 0%"
     }
  ]
}
EOF

prep_netns () {
  sudo ip netns exec "$1" sysctl -w net.ipv4.ip_forward=1
  sudo ip netns exec "$1" sysctl -w net.ipv6.conf.all.forwarding=1
  sudo ip netns exec "$1" ip link set up lo
}

create_bridge () {
  sudo ip netns exec "$1" brctl addbr "br-$2"
  sudo ip netns exec "$1" brctl addif "br-$2" "veth-$2"
  sudo ip netns exec "$1" ip link set up "br-$2"
  sudo ip netns exec "$1" ip addr add $3 dev "br-$2"
}

prep_netns netlab-1
create_bridge netlab-1 1-2 2001::1
sudo ip netns exec netlab-1 $babeld -I babeld-n1.pid -d 1 -L babeld-n1.log -h 1 -P 5 -w br-1-2 -G 8080 &
sudo ip netns exec netlab-1 bash -c 'failed=1
                            while [ $failed -ne 0 ]
                            do
                              ping6 -n -s 1400 2001::3 &> ping.log
                              failed=$?
                              sleep 1
                            done' &
sudo ip netns exec netlab-1 echo $! > ping_retry.pid
(RUST_BACKTRACE=full sudo ip netns exec netlab-1 $rita --ip 2001::1 2>&1 & echo $! > rita-n1.pid) | grep -Ev "<unknown>|mio" &> rita-n1.log &
echo $! > rita-n1.pid

prep_netns netlab-2
create_bridge netlab-2 2-1 2001::2
create_bridge netlab-2 2-3 2001::2
sudo ip netns exec netlab-2 $babeld -I babeld-n2.pid -d 1 -L babeld-n2.log -h 1 -P 10 -w br-2-1 br-2-3 -G 8080 &
(RUST_BACKTRACE=full sudo ip netns exec netlab-2 $rita --ip 2001::2 2>&1 & echo $! > rita-n2.pid) | grep -Ev "<unknown>|mio" &> rita-n2.log &
echo $! > rita-n2.pid
sudo ip netns exec netlab-2 brctl show

prep_netns netlab-3
create_bridge netlab-3 3-2 2001::3
sudo ip netns exec netlab-3 $babeld -I babeld-n3.pid -d 1 -L babeld-n3.log -h 1 -P 1 -w br-3-2 -G 8080 &
(RUST_BACKTRACE=full sudo ip netns exec netlab-3 $rita --ip 2001::3 2>&1 & echo $! > rita-n3.pid) | grep -Ev "<unknown>|mio" &> rita-n3.log &
cp ./../bounty_hunter/test.db ./test.db
(RUST_BACKTRACE=full sudo ip netns exec netlab-3 $bounty -- 2>&1 & echo $! > bounty-n3.pid) | grep -Ev "<unknown>|mio" &> bounty-n3.log &


sleep 20

# Use some bandwidth from 1 -> 3

# Start iperf test for 10 seconds @ 1mbps
sudo ip netns exec netlab-3 iperf3 -s -V &

sleep 1

sudo ip netns exec netlab-1 iperf3 -c 2001::3 -V -b -u 1000000

stop_processes

sleep 1

fail_string "malformed" "babeld-n1.log"
fail_string "malformed" "babeld-n2.log"
fail_string "malformed" "babeld-n3.log"
fail_string "unknown version" "babeld-n1.log"
fail_string "unknown version" "babeld-n2.log"
fail_string "unknown version" "babeld-n3.log"
pass_string "dev veth-1-2 reach" "babeld-n1.log"
pass_string "dev br-2-1 reach" "babeld-n2.log"
pass_string "dev br-2-3 reach" "babeld-n2.log"
pass_string "dev veth-3-2 reach" "babeld-n3.log"
pass_string "2001::3\/128.*via veth-1-2" "babeld-n1.log"
pass_string "2001::1\/128.*via br-2-1" "babeld-n2.log"
pass_string "2001::3\/128.*via br-2-3" "babeld-n2.log"
pass_string "2001::2\/128.*via veth-3-2" "babeld-n3.log"

pass_string "destination: V6(2001::3), bytes: 7240" "rita-n2.log"
pass_string "destination: V6(2001::1), bytes: 7240" "rita-n2.log"
pass_string "Calculated neighbor debt. price: 11, debt: 79640" "rita-n2.log"
pass_string "Calculated neighbor debt. price: 15, debt: 108600" "rita-n2.log"
pass_string "prefix: V6(Ipv6Network { network_address: 2001::1, netmask: 128 })" "rita-n2.log"
pass_string "prefix: V6(Ipv6Network { network_address: 2001::3, netmask: 128 })" "rita-n2.log"

pass_string '[rita] got neighbors: [Identity { ip_address: V6(2001::3), eth_address: EthAddress 0xb794f5ea0ba39494ce839613fffba74279579268, mac_address: MacAddress("16:b9:b4:72:71:73") }, Identity { ip_address: V6(2001::1), eth_address: EthAddress 0xb794f5ea0ba39494ce839613fffba74279579268, mac_address: MacAddress("82:33:94:f8:8a:d3") }]' "rita-n2.log"

echo "$0 PASS"
