#!/bin/sh -efu

. shell-error
. shell-quote
. shell-args
. shell-ini-config

PROG="${0##*/}"
PROG_VERSION='0.3'

# VSphere insecure by default ((
vs_insecure=1
vs_json=
vs_dc=
vs_srv=
vs_snap=
vs_mem=
vs_dsize=
vs_dmode=
vs_config="$HOME/.terraformware.conf"
vs_dc_config="$HOME/.vs-dc.ini"
govc="$HOME/bin/govc"
cmd=

[ -x "$govc" ] || fatal "govc binary not found on $govc location"
# we rely on terraformware settings
[ -s "$vs_config" ] || fatal "No VSphere credentials found in $vs_config, exiting"
vs_username="$(grep -F vsphere_username $HOME/.terraformware.conf)"
vs_username="${vs_username##*= }"
vs_password="$(grep -F vsphere_password $HOME/.terraformware.conf)"
vs_password="${vs_password##*= }"
vs_password=$(echo "$vs_password"|base64 -d)
[ -n "$vs_username" ] && [ -n "$vs_password" ] || fatal 'no vsphere credentials found'

show_help() {
	cat <<EOF
Usage: Usage: $PROG -l <DC> [options] <cmd> <vm>

Options:
  
  -l, --location=<DC>           VSphere DC location (for example BRQ or AMS);
  -V, --version                 print program version and exit;
  -h, --help                    show this text and exit;
  -j, --json                    use json output.

Command shortcuts (takes VM as last argument):

  poweron
  poweroff
  suspend
  pstate                        Shows current VM power state
  info
  disk_info
  disk_shrink
  disk_extend <size>
  disk_change <mode>
  memory_extend <size>Mb
  memory_hotadd_check
  memory_hotadd_enable
  cpu_add <nr>
  cpu_remove <nr>
  cpu_hotadd_check
  cpu_hotadd_enable
  cpu_hotremove_check
  cpu_hotremove_enable
  ls_snapshot
  create_snapshot
  delete_snapshot <name>        Delete defined snapshot
  revert_snapshot <name>        Revert to defined snapshot

Advanced usage:

$PROG [options] -- <govc direct cmd>

EOF
	exit
}

print_version() {
	cat <<EOF
$PROG version $PROG_VERSION
Written by Konstantin Lepikhov <konstantin.lepikhov@geant.org>

This is free software; see the source for copying conditions.  There is NO
warranty; not even for MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
EOF
	exit
}

get_vm_path() {
	local vm="$1"; shift
	vm=$($govc find vm -name "$vm"*)
	[ -n "$vm" ] && printf '%s\n' "$vm" \
		|| return 1
}

get_vm_pstate() {
	local vm=$1; shift
	local pstate=
	[ -n "$vm" ] || fatal 'VM name is missing'
	local pstate=$($govc object.collect -s $(get_vm_path "$vm") runtime.powerState)
	[ -n "$pstate" ] && printf '%s\n' "$pstate" || return 1
}

vm_on() {
	local vm=$1; shift
	local state=$(get_vm_pstate "$vm")
	case "$state" in
		poweredOn)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

vm_off() {
	local vm=$1; shift
	local state=$(get_vm_pstate "$vm")
	case "$state" in
		poweredOff)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

get_vm_disk_path() {
	local vm=$1; shift
	local path=
	local ds=
	[ -n "$vm" ] || fatal 'VM name is missing'
	vm_off "$vm" || fatal 'VM should be OFF to perform!'
	path=$($govc device.info -vm "$vm" -json disk-*|jq -r .Devices[].Backing.FileName)
	ds=${path%% *}
	path="${path##* }"
	[ -n "$ds" ] && path="-ds $ds $path"
	[ -n "$path" ] && printf '%s\n' "$path" || return 1
}

get_vm_option_bul() {
	local vm=$1; shift
	local opt=$1; shift
	output=
	[ -n "$vm" ] && [ -n "$opt" ] || fatal 'Not enought args to operate!'
	vm=$(get_vm_path "$vm")
	output=$($govc object.collect -s "$vm" "$opt")
	[ -n "$output" -a "$output" = true ] && return 0 \
		|| return 1
}

get_vm_option_val() {
	local vm=$1; shift
	local opt=$1; shift
	output=
	[ -n "$vm" ] && [ -n "$opt" ] || fatal 'Not enought args to operate!'
	vm=$(get_vm_path "$vm")
	output=$($govc object.collect -s "$vm" "$opt")
	[ -n "$output" ] && printf '%s\n' "$output" || return 1
}

vm_extend_disk() {
	local disk_size="$1"; shift
	local vm="$1"; shift
	local disk_name=
	local cur_size=
	local output=
	shell_var_is_number "$disk_size" || fatal 'Disk size should be a number'
	# Does it works for multiple disks?
	cur_size=$($govc device.info -vm "$vm" -json disk-*|jq -r .Devices[].CapacityInBytes)
	cur_size=$(($cur_size/(1024*1024)))
	[ "$disk_size" -gt "$cur_size" ] || fatal "New disk size $disk_size < $cur_size"
	disk_name=$($govc device.info -vm "$vm" -json disk-*|jq -r .Devices[].Name)
	[ -n "$disk_name" ] || return 1
	output="vm.disk.change -vm $vm -disk.name=$disk_name -size ${disk_size}M"
	[ -n "$output" ] && printf '%s\n' "$output" || return 1
}

vm_change_disk() {
	local disk_mode="$1"; shift
	local vm="$1"; shift
	local disk_path=
	local cur_mode=
	local output=
	cur_mode=$($govc device.info -vm "$vm" -json disk-*|jq -r .Devices[].Backing.DiskMode)
	[ -n "$cur_mode" ] || fatal 'Unable to get current disk mode'
	case "$disk_mode" in
		show)
		disk_mode="$cur_mode"
		;;
		persistent|nonpersistent|undoable|independent_persistent|independent_nonpersistent|append)
		;;
		*) fatal "Mode $disk_mode unsupported"
		;;
	esac
	if [ "$cur_mode" = "$disk_mode" ]; then
		printf '%s\n' "$disk_mode"
		return $?
	fi
	# Does it works for multiple disks?
	disk_path=$($govc device.info -vm "$vm" -json disk-*|jq -r .Devices[].Backing.FileName)
	[ -n "$disk_path" ] || return 1
	printf 'vm.disk.change -vm %s -disk.filePath \"%s\" -mode %s' "$vm" "$disk_path" "$disk_mode" || return 1
}

vm_change_mem() {
	local mem_size="$1"; shift
	local vm="$1"; shift
	local cur_size=
	local mem_limit=
	shell_var_is_number "$mem_size" || fatal 'Memory size should be a number!'
	cur_size=$(get_vm_option_val "$vm" config.hardware.memoryMB)
	# Handle the case where hotplug memory limit is missing
	mem_limit=$(get_vm_option_val "$vm" config.hotPlugMemoryLimit) ||:
	[ "$mem_size" -gt "$cur_size" ] &&
		message "Changing memory size $cur_size->$mem_size MB.." || \
		fatal "Memory requested size is lower than current $cur_size, exiting.."
	if [ -n "$mem_limit" ]; then
		[ "$mem_size" -gt "$mem_limit" ] && \
		fatal "Cannot add more memory than hotadd limit $mem_limit"
	fi
	printf '%s\n' "vm.change -m $mem_size"
}

vm_change_cpu() {
	local nr_cpu="$1"; shift
	local action="$1"; shift
	local vm="$1"; shift
	local nr_cur=
	shell_var_is_number "$nr_cpu" || fatal 'CPU count should be a number!'
	nr_cur=$(get_vm_option_val "$vm" config.hardware.numCPU)
	case "$action" in
		cpu_add) nr_cpu=$(($nr_cur+$nr_cpu))
			;;
		cpu_remove)
			nr_cpu=$(($nr_cur-$nr_cpu))
			[ -n "$nr_cpu" -a "$nr_cpu" -gt 0 ] || \
				fatal 'resulting CPU amount should be >= 0'
			# see https://bugzilla.redhat.com/show_bug.cgi?id=1417938
			vm_off "$vm" || fatal 'Cannot remove CPUs from a running VM'
			;;
	esac
	[ -n "$nr_cpu" -a -n "$nr_cur" ] && message "Changing CPU count $nr_cur->$nr_cpu .."
	printf '%s\n' "vm.change -c $nr_cpu"
}

TEMP=`getopt -n $PROG -o 'l:,H:,h,V,j' -l 'location:,fqdn:,help,version,json' -- "$@"` ||
	show_usage
eval set -- "$TEMP"

while :; do
	case "$1" in
		-l|--location) shift; vs_dc="$1"
			;;
		-h|--help) show_help
			;;
		-V|--version) print_version
			;;
		-j|--json) vs_json=1
			;;
		--) shift; break
			;;
	esac
	shift
done

[ -n "$vs_dc" ] || vs_dc="$(ini_config_get "$vs_dc_config" global location)"
[ -n "$vs_dc" ] || show_usage
vs_dc=$(printf '%s\n' "$vs_dc" | tr '[:upper:]' '[:lower:]')
vs_srv=$(ini_config_get "$vs_dc_config" "$vs_dc" url)
vs_dc=$(ini_config_get "$vs_dc_config" "$vs_dc" dc)

[ -n "$vs_insecure" ] && export GOVC_INSECURE='true'

export GOVC_URL="https://${vs_username}:${vs_password}@$vs_srv"
export GOVC_DATACENTER="$vs_dc"


cmd="$1"; shift

case "$cmd" in
	poweroff) cmd="vm.power -s $1"
		;;
	poweron) cmd="vm.power -on $1"
		;;
	suspend) cmd="vm.power -suspend $1"
		;;
	pstate) get_vm_pstate "$1"
		exit $?
		;;
	info) cmd="vm.info -e $1"
		;;
	disk_info) cmd='device.info disk-*'
		;;
	disk_shrink)
		vs_json=
		cmd="datastore.disk.shrink $(get_vm_disk_path $1)"
		;;
	disk_extend)
		vs_dsize="$1"; shift
		cmd=$(vm_extend_disk "$vs_dsize" "$1")
		;;
	disk_change)
		vs_dmode="$1"; shift
		cmd=$(vm_change_disk "$vs_dmode" "$1")
		if [ "$vs_dmode" = "show" ]; then
			printf '%s\n' "$cmd"
			exit $?
		else
			vm_off "$1" || fatal "VM $1 should be OFF to operate!"
		fi
		;;
	memory_extend)
		vs_mem="$1"; shift
		cmd=$(vm_change_mem "$vs_mem" "$1")
		;;
	memory_hotadd_check)
		get_vm_option_bul "$@" config.memoryHotAddEnabled && \
			message 'Enabled' || \
			message 'Disabled'
		exit $?
		;;
	memory_hotadd_enable)
		vm_off "$1" || fatal "VM $1 should be OFF to operate!"
		cmd='vm.change -e mem.hotadd=true'
		;;
	cpu_add|cpu_remove)
		vs_cpu="$1"; shift
		cmd=$(vm_change_cpu "$vs_cpu" "$cmd" "$1")
		;;
	cpu_hotadd_check)
		get_vm_option_bul "$1" config.cpuHotAddEnabled && \
			message 'Enabled' || \
			message 'Disabled'
		exit $?
		;;
	cpu_hotadd_enable)
		vm_off "$1" || fatal "VM $1 should be OFF to operate!"
		cmd='vm.change -e vcpu.hotadd=true'
		;;
        cpu_hotremove_check)
		get_vm_option_bul "$1" config.cpuHotRemoveEnabled && \
			message 'Enabled' || \
			message 'Disabled'
		exit $?
		;;
        cpu_hotremove_enable)
		vm_off "$1" || fatal "VM $1 should be OFF to operate!"
		cmd='vm.change -e vcpu.hotremove=true'
		;;
	ls_snapshot)
		vs_json=
		cmd='snapshot.tree'
		;;
	create_snapshot)
		cmd="snapshot.create $(LC_ALL=POSIX date +'%Y_%b_%d_%H.%M')"
		;;
	delete_snapshot|revert_snapshot)
		         vs_snap="$1"; shift
			 [ -n "$vs_snap" ] || fatal 'Cmd requires snapshot name to operate, exiting'
			 case "$cmd" in
				 delete_*) cmd='snapshot.remove'
					 ;;
				 revert_*) cmd='snapshot.revert'
					 ;;
			 esac
		         cmd="$cmd $vs_snap"
		;;
	*) fatal "$cmd: Unsupported!"
		;;
esac

[ -n "$vs_json" ] && cmd=$(printf '%s\n' "$cmd" |sed -ne 's,\(^[a-z]\+\?\.[a-z]\+\?\)\ ,\1 -json\ ,gp')

if [ "$#" -eq 1 ]; then
	export GOVC_VM="$*"
	eval "$govc" "$cmd"
else
	$govc "$cmd" "$*"
fi

