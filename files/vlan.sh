#!/bin/sh

# This script will set up VLAN interfaces if `vlan_id=` in `/proc/cmdline` has a value
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

add_vlan_interface() {
	vlan_id=$(get_vlan_id)
	if [ -n "$vlan_id" ]; then
		for ifname in $(ip -4 -o link show | awk -F': ' '{print $2}'); do
			[ "$ifname" = "lo" ] && continue
			[ "$ifname" = "docker0" ] && continue
			ip link add link "$ifname" name "$ifname.$vlan_id" type vlan id "$vlan_id"
			ip link set "$ifname.$vlan_id" up
		done
	fi
}

# we always return true so that a failure here doesn't block the next container service from starting. Ideally, we always
# want the getty service to start so we can debug failures.
add_vlan_interface || true
