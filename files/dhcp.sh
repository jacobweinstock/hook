#!/bin/sh

# This script will run the dhcp client. If `vlan_id=` in `/proc/cmdline` has a value, it will run the dhcp client only on the
# VLAN interface.
# This script accepts an input parameter of true or false.
# true: run the dhcp client with the one shot option
# false: run the dhcp client as a background process
set -x

get_vlan_id() {
	cmdline=$(cat /proc/cmdline)
	substring="vlan_id="
	if ! grep -q "${substring}" "/proc/cmdline"; then
		return
	fi
	# this gets the index in $cmdline of the "v" in "vlan_id="
	idx=${cmdline%%"$substring"*}
	# this gets the substring starting from $idx + 12 characters. example: "vlan_id=4094"
	begin="${#idx}"
	end=$((begin+12))
	x=$(echo "${cmdline}" | cut -c "${begin}"-"${end}")
	# this gets just the numbers from $x (vlan_id=4094) empty string if no numbers
	vlan=$(echo "${x}" | grep -o '[0-9]\+')
	echo "${vlan}"
}

run_dhcp_client() {
	one_shot="$1"
	al="eth*" # all interfaces

	vlan_id=$(get_vlan_id)
	if [ -n "$vlan_id" ]; then
		al="eth*.*" # all vlan interfaces
	fi


	# Boots send kernel command line parameter "ip=dhcp", this causes the system to configure the network interface(s) with DHCP.
	# When an environment's network configuration has this machine connected a trunked interface with a default/native VLAN, the
	# interface will be configured on the default/native VLAN because we haven't yet configured the VLAN interface. Boots will respond
	# to this DHCP request because in this scenario it is not VLAN aware. Also in this scenario, the machine will end up being configured
	# with 2 default routes. To resolve this, we remove the default route and IP that kernel added and let the dhcpcd handle setting the route.
	ip route del default || true
	ipa=$(ip -4 -o addr show dev eth0 | awk '{print $4}')
	ip addr del dev eth0 "$ipa" || true

	args=""
	if [ "$one_shot" = "true" ]; then
		args="-1"
	fi
	/sbin/dhcpcd --nobackground -f /dhcpcd.conf --allowinterfaces "$al" "$args"

}

# we always return true so that a failure here doesn't block the next container service from starting. Ideally, we always
# want the getty service to start so we can debug failures.
run_dhcp_client "$1" || true
