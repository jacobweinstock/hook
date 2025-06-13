#!/usr/bin/env bash

function obtain_linuxkit_binary_cached() {
	# Grab linuxkit from official GitHub releases; account for arm64/amd64 differences

	declare linuxkit_os="linux"
	[[ "$(uname -s)" == "Darwin" ]] && linuxkit_os="darwin"

	declare linuxkit_arch=""
	# determine the arch to download from current arch
	case "$(uname -m)" in
		"x86_64") linuxkit_arch="amd64" ;;
		"aarch64" | "arm64") linuxkit_arch="arm64" ;;
		*) log error "ERROR: ARCH $(uname -m) not supported by linuxkit? check https://github.com/linuxkit/linuxkit/releases" && exit 1 ;;
	esac

	declare linuxkit_down_url="https://github.com/linuxkit/linuxkit/releases/download/v${LINUXKIT_VERSION}/linuxkit-${linuxkit_os}-${linuxkit_arch}"
	declare -g linuxkit_bin="${CACHE_DIR}/linuxkit-${linuxkit_os}-${linuxkit_arch}-${LINUXKIT_VERSION}"

	# Download using curl if not already present
	if [[ ! -f "${linuxkit_bin}" ]]; then
		log info "Downloading linuxkit from ${linuxkit_down_url} to file ${linuxkit_bin}"
		curl -sL "${linuxkit_down_url}" -o "${linuxkit_bin}"
		chmod +x "${linuxkit_bin}"
	fi

	# Show the binary's version
	log info "LinuxKit binary version: $("${linuxkit_bin}" version | xargs echo -n)"

}

function linuxkit_build() {
	# Ensure OUTPUT_ID is set
	if [[ "${OUTPUT_ID}" == "" ]]; then
		log error "\${OUTPUT_ID} is not set after ${kernel_info[VERSION_FUNC]}"
		exit 1
	fi

	# If the image is in the local docker cache, skip building
	if [[ -n "$(docker images -q "${kernel_oci_image}")" ]]; then
		log info "Kernel image ${kernel_oci_image} already in local cache; trying a pull to update, but tolerate failures..."
		docker pull "${kernel_oci_image}" || log warn "Pull failed, fallback to local image ${kernel_oci_image} - results might be inconsistent."
	else
		# Pull the kernel from the OCI registry
		log info "Pulling kernel from ${kernel_oci_image}"
		if docker pull "${kernel_oci_image}"; then
			log info "Successfully pulled kernel ${kernel_oci_image} from registry."
		else
			log error "Failed to pull kernel ${kernel_oci_image} from registry."
			log error "You might want to build the kernel locally, by running './build.sh kernel ${inventory_id}'"
			exit 7
		fi
	fi

	# A dictionary (bash associative array) with variables and their values, for templating using envsubst.
	declare -A -g hook_template_vars=(
		["HOOK_VERSION"]="${HOOK_VERSION}"
		["HOOK_KERNEL_IMAGE"]="${kernel_oci_image}"
		["HOOK_KERNEL_ID"]="${inventory_id}"
		["HOOK_KERNEL_VERSION"]="${kernel_oci_version}"
	)

	# Build the containers in this repo used in the LinuxKit YAML;
	build_all_hook_linuxkit_containers # sets HOOK_CONTAINER_BOOTKIT_IMAGE, HOOK_CONTAINER_DOCKER_IMAGE and others in the hook_template_vars dict

	# Template the linuxkit configuration file.
	# - You'd think linuxkit would take --build-args or something by now, but no.
	# - Linuxkit does have @pkg but that's only useful in its own repo (with pkgs/ dir)
	# - envsubst doesn't offer a good way to escape $ in the input, so we pass the exact list of vars to consider, so escaping is not needed
	log info "Using Linuxkit template '${kernel_info['TEMPLATE']}'..."

	# Calculate, from hook_template_vars dictionary:
	# envsubst_arg_string: a space separated list of dollar-prefixed variables name to be substituted
	# envusbst_env: the environment variables to be passed to envsubst (array of KEY=var) to be used via 'env'
	declare envsubst_arg_string=""
	declare -a envsubst_envs=()
	for key in "${!hook_template_vars[@]}"; do
		envsubst_arg_string+="\$${key} " # extra space at the end doesn't hurt
		envsubst_envs+=("${key}=${hook_template_vars["${key}"]}")
	done
	log debug "envsubst_arg_string: ${envsubst_arg_string}"
	log debug "envsubst_envs: ${envsubst_envs[*]}"

	# Run envsubst on the template file, output to a new file; pass the envs and the arg string
	env "${envsubst_envs[@]}" envsubst "${envsubst_arg_string}" < "linuxkit-templates/${kernel_info['TEMPLATE']}.template.yaml" > "hook.${inventory_id}.yaml"

	declare -g linuxkit_bin=""
	obtain_linuxkit_binary_cached # sets "${linuxkit_bin}"

	declare lk_output_dir="out/linuxkit-${inventory_id}"
	mkdir -p "${lk_output_dir}"

	declare lk_cache_dir="${CACHE_DIR}/linuxkit"
	mkdir -p "${lk_cache_dir}"

	declare -a lk_debug_args=()
	if [[ "${DEBUG}" == "yes" ]]; then
		lk_debug_args+=("--verbose" "2") # 0 = quiet, 1 = info, 2 = debug, 3 = trace.
	fi

	# if LINUXKIT_ISO is set, build an ISO with the kernel and initramfs
	if [[ -n "${LINUXKIT_ISO}" ]]; then
		declare lk_iso_output_dir="out"
		mkdir -p "${lk_iso_output_dir}"

		declare -a lk_iso_args=(
			"--docker"
			"--arch" "${kernel_info['DOCKER_ARCH']}"
			"--format" "iso-efi-initrd"
			"--name" "hook-${OUTPUT_ID}"
			"--cache" "${lk_cache_dir}"
			"--dir" "${lk_iso_output_dir}"
			"hook.${inventory_id}.yaml" # the linuxkit configuration file
		)

		log info "Building Hook ISO with kernel ${inventory_id} using linuxkit: ${lk_iso_args[*]}"
		"${linuxkit_bin}" build "${lk_debug_args[@]}" "${lk_iso_args[@]}"
		return 0
	fi

	declare -a lk_args=(
		"--docker"
		"--arch" "${kernel_info['DOCKER_ARCH']}"
		"--name" "hook"
		"--cache" "${lk_cache_dir}"
		"--dir" "${lk_output_dir}"
		"hook.${inventory_id}.yaml" # the linuxkit configuration file
	)

	if [[ "${OUTPUT_TARBALL_FILELIST:-"no"}" == "yes" ]]; then
		log info "OUTPUT_TARBALL_FILELIST=yes; Building Hook (tar/filelist) with kernel ${inventory_id} using linuxkit: ${lk_args[*]}"
		"${linuxkit_bin}" build "--format" "tar" "${lk_debug_args[@]}" "${lk_args[@]}"
	fi

	log info "Building Hook with kernel ${inventory_id} using linuxkit: ${lk_args[*]}"
	"${linuxkit_bin}" build "--format" "kernel+initrd" "${lk_debug_args[@]}" "${lk_args[@]}"

	declare initramfs_path="${lk_output_dir}/hook-initrd.img"
	# initramfs_path is a gzipped file. obtain the uncompressed byte size, without decompressing it
	declare -i initramfs_size_bytes=0
	initramfs_size_bytes=$(gzip -l "${initramfs_path}" | tail -n 1 | awk '{print $2}')
	log info "Uncompressed initramfs size in bytes: ${initramfs_size_bytes}"
	# If the size is larger than 900mb, it is unlikely to boot on a 2gb RAM machine. Warn.
	if [[ "${initramfs_size_bytes}" -gt 943718400 ]]; then
		log warn "${inventory_id}: Uncompressed initramfs size (${initramfs_size_bytes} bytes) is larger than 900mb; it may not boot on a 2gb RAM machine."
	else
		log notice "${inventory_id}: Uncompressed initramfs size (${initramfs_size_bytes} bytes) is smaller than 900mb."
	fi

	if [[ "${LK_RUN}" == "qemu" ]]; then
		linuxkit_run_qemu
		return 0
	fi

	# rename outputs
	mv "${debug_dash_v[@]}" "${lk_output_dir}/hook-kernel" "${lk_output_dir}/vmlinuz-${OUTPUT_ID}"
	mv "${debug_dash_v[@]}" "${lk_output_dir}/hook-initrd.img" "${lk_output_dir}/initramfs-${OUTPUT_ID}"
	rm "${lk_output_dir}/hook-cmdline"

	# prepare out/hook dir with the kernel/initramfs pairs; this makes it easy to deploy to /opt/hook eg for stack chart (or nibs)
	mkdir -p "out/hook"
	mv "${debug_dash_v[@]}" "${lk_output_dir}/vmlinuz-${OUTPUT_ID}" "out/hook/vmlinuz-${OUTPUT_ID}"
	mv "${debug_dash_v[@]}" "${lk_output_dir}/initramfs-${OUTPUT_ID}" "out/hook/initramfs-${OUTPUT_ID}"

	declare -a output_files=("vmlinuz-${OUTPUT_ID}" "initramfs-${OUTPUT_ID}")

	# We need to extract /dtbs.tar.gz from the kernel image; linuxkit itself knows nothing about dtbs.
	# Export a .tar of the image using docker to stdout, read a single file from stdin and output it
	log debug "Docker might emit a warning about mismatched platforms below. It's safe to ignore; the image in question only contains kernel binaries, for the correct arch, even though the image might have been built & tagged on a different arch."
	docker create --name "export-dtb-${OUTPUT_ID}" "${kernel_oci_image}" "command_is_irrelevant_here_container_is_never_started"
	(docker export "export-dtb-${OUTPUT_ID}" | tar -xO "dtbs.tar.gz" > "${lk_output_dir}/dtbs-${OUTPUT_ID}.tar.gz") || true # don't fail -- otherwise container is left behind forever
	docker rm "export-dtb-${OUTPUT_ID}"

	# Now process "${lk_output_dir}/dtbs-${OUTPUT_ID}.tar.gz so every file in it is prefixed with the path dtbs-${OUTPUT_ID}/
	# This is so that the tarball can be extracted in /boot/dtbs-${OUTPUT_ID} and not pollute /boot with a ton of dtbs
	declare dtbs_tmp_dir="${lk_output_dir}/extract-dtbs-${OUTPUT_ID}"
	mkdir -p "${dtbs_tmp_dir}"
	tar -xzf "${lk_output_dir}/dtbs-${OUTPUT_ID}.tar.gz" -C "${dtbs_tmp_dir}"
	# Get a count of .dtb files in the extracted dir
	declare -i dtb_count
	dtb_count=$(find "${dtbs_tmp_dir}" -type f -name "*.dtb" | wc -l)
	log info "Kernel includes ${dtb_count} DTB files..."
	# If more than zero, let's tar them up adding a prefix
	if [[ $dtb_count -gt 0 ]]; then
		tar -czf "out/hook/dtbs-${OUTPUT_ID}.tar.gz" -C "${dtbs_tmp_dir}" --transform "s,^,dtbs-${OUTPUT_ID}/," .
		output_files+=("dtbs-${OUTPUT_ID}.tar.gz")
	else
		log info "No DTB files found in kernel image."
	fi
	rm -rf "${dtbs_tmp_dir}"
	rm "${lk_output_dir}/dtbs-${OUTPUT_ID}.tar.gz"

	if [[ "${OUTPUT_TARBALL_FILELIST:-"no"}" == "yes" ]]; then
		log info "OUTPUT_TARBALL_FILELIST=yes; including tar and filelist in output."
		mv "${debug_dash_v[@]}" "${lk_output_dir}/hook.tar" "out/hook/hook_rootfs_${OUTPUT_ID}.tar"
		tar --list -f "${debug_dash_v[@]}" "out/hook/hook_rootfs_${OUTPUT_ID}.tar" > "out/hook/hook_rootfs_${OUTPUT_ID}.filelist"
	fi

	# finally clean up the hook-specific out dir
	rm -rf "${lk_output_dir}"

	# tar the files into out/hook.tar in such a way that vmlinuz and initramfs are at the root of the tar; pigz it
	# Those are the artifacts published to the GitHub release
	tar "${debug_dash_v[@]}" -cf- -C "out/hook" "${output_files[@]}" | pigz > "out/hook_${OUTPUT_ID}.tar.gz"
}

function linuxkit_run_qemu() {
	declare lk_output_dir="out/linuxkit-${inventory_id}"
	declare -g linuxkit_bin=""
	obtain_linuxkit_binary_cached # sets "${linuxkit_bin}"

	declare disk_path="${lk_output_dir}/run-qemu-disk.qcow2"

	declare -a lk_run_args=(
		"run" "qemu"
		"--arch" "${kernel_info['ARCH']}"                  # Not DOCKER_ARCH
		"--kernel"                                         # Boot image is kernel+initrd+cmdline 'path'-kernel/-initrd/-cmdline
		"--uefi"                                           # Use UEFI boot
		"--cpus" "2"                                       # Use 2 CPU's
		"--mem" "2048"                                     # Use 2GB of RAM
		"--disk" "file=${disk_path},size=10G,format=qcow2" # causes a /dev/sda to exist @TODO doesn't show up under /dev/disk/by-id -- why?
	)

	declare lk_run_kernel_console="console=UNKNOWN!" #

	# Those are for Debian/Ubuntu hosts
	case "${kernel_info['DOCKER_ARCH']}" in
		amd64)
			# apt install qemu-system-x86 if no /usr/bin/qemu-system-x86_64
			# apt install ovmf if no /usr/share/OVMF/OVMF_CODE.fd
			lk_run_args+=("--fw" "/usr/share/OVMF/OVMF_CODE.fd")
			lk_run_kernel_console="console=ttyS0"
			;;

		arm64)
			# apt install qemu-system-arm if no /usr/bin/qemu-system-aarch64
			# apt install qemu-efi-aarch64 if no /usr/share/AAVMF/AAVMF_CODE.fd
			lk_run_args+=("--fw" "/usr/share/AAVMF/AAVMF_CODE.fd")
			lk_run_kernel_console="console=ttyAMA0"
			;;

		*) log error "How did you get this far? bug. report." && exit 66 ;;
	esac

	if [[ ! -c /dev/kvm ]]; then
		log warn "No /dev/kvm found; using emulation, this will be slow."
		lk_run_args+=("--accel" "tcg")
		# linuxkit messes up non-kvm arm64 emulation anyway, sorry: "qemu-system-aarch64: gic-version=host requires KVM"
	fi

	declare TINK_WORKER_IMAGE="${TINK_WORKER_IMAGE:-"quay.io/tinkerbell/tink-worker:latest"}"
	declare TINK_TLS="${TINK_TLS:-"false"}"
	declare TINK_GRPC_PORT="${TINK_GRPC_PORT:-"42113"}"
	declare TINK_SERVER="${TINK_SERVER:-"unset"}" # export TINK_SERVER="192.168.66.75"
	declare MAC="${MAC:-"unset"}"                 # export MAC="11:22:33:44:55:66" # or export MAC="11:22:33:44:55:77"

	log info "TINK_WORKER_IMAGE is set to '${TINK_WORKER_IMAGE}'"
	log info "TINK_TLS is set to '${TINK_TLS}'"
	declare -a lk_run_kernel_cmdline=(
		"tink_worker_image=${TINK_WORKER_IMAGE}"
		"tinkerbell_tls=${TINK_TLS}"
	)

	# If TINK_SERVER and MAC are different from 'unset' add params
	if [[ "${TINK_SERVER}" != "unset" && "${MAC}" != "unset" ]]; then
		log info "TINK_SERVER is set to '${TINK_SERVER}'"
		log info "MAC is set to '${MAC}'"
		log info "TINK_GRPC_PORT is set to '${TINK_GRPC_PORT}'"

		lk_run_kernel_cmdline+=(
			"grpc_authority=${TINK_SERVER}:${TINK_GRPC_PORT}"
			"syslog_host=${TINK_SERVER}"
			"worker_id=${MAC}"
			"hw_addr=${MAC}"
		)
	else
		log warn "TINK_SERVER and MAC are not set, not adding tink-worker params to kernel cmdline."
		log warn "tink-worker won't really work, but this is enough to test kernel and services."
	fi

	lk_run_kernel_cmdline+=("${lk_run_kernel_console}")

	echo -n "${lk_run_kernel_cmdline[*]}" > "${lk_output_dir}/hook-cmdline"

	lk_run_args+=("${lk_output_dir}/hook") # Path to run; will add -kernel, -initrd, -cmdline

	log info "Running LinuxKit in QEMU with '${lk_run_args[*]}'"
	log info "Running LinuxKit in QEMU with kernel cmdline'${lk_run_kernel_cmdline[*]}'"

	"${linuxkit_bin}" "${lk_run_args[@]}"
}
