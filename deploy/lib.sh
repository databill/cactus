#!/bin/bash -e
# shellcheck disable=SC2155,SC1001
##############################################################################
# Copyright (c) 2017 Mirantis Inc., Enea AB and others.
# All rights reserved. This program and the accompanying materials
# are made available under the terms of the Apache License, Version 2.0
# which accompanies this distribution, and is available at
# http://www.apache.org/licenses/LICENSE-2.0
##############################################################################
#
# Library of shell functions
#

function generate_ssh_key {
  local cactus_ssh_key=$(basename "${SSH_KEY}")
  local user=${USER}
  if [ -n "${SUDO_USER}" ] && [ "${SUDO_USER}" != 'root' ]; then
    user=${SUDO_USER}
  fi

  if [ -f "${SSH_KEY}" ]; then
    cp "${SSH_KEY}" .
    ssh-keygen -f "${cactus_ssh_key}" -y > "${cactus_ssh_key}.pub"
  fi

  [ -f "${cactus_ssh_key}" ] || ssh-keygen -f "${cactus_ssh_key}" -N ''
  sudo install -D -o "${user}" -m 0600 "${cactus_ssh_key}" "${SSH_KEY}"
  sudo install -D -o "${user}" -m 0600 "${cactus_ssh_key}.pub" "${SSH_KEY}.pub"
}

function build_images {
  local builder_image=cactus/dib:latest
  local dib_name=cactus_image_builder
  local sshpub="${SSH_KEY}.pub"
  build_builder_image ${builder_image}

  [[ "$(docker images -q ${builder_image} 2>/dev/null)" != "" ]] || {
    echo "build diskimage_builder image... "
    pushd ${REPO_ROOT_PATH}/images/docker/dib
    docker build -t ${builder_image} .
    popd
  }

  echo "Start DIB console named ${dib_name} service ... "
  docker run -it \
           --name ${dib_name} \
           -v ${STORAGE_DIR}:/imagedata \
           -v ${sshpub}:/id_rsa.pub \
           --privileged \
           --rm \
           ${builder_image} \
           bash /create_image.sh
}

function parse_vnodes {
  eval $(python deploy/parse_pdf.py -y ${REPO_ROOT_PATH}/config/lab/basic/lab.yaml 2>&1)
}

function get_vnodes {
  local pdf="{REPO_ROOT_PATH}/config/lab/basic/lab.yaml"
  local s
  local w
  local fs
  s='[[:space:]]*'
  w='[a-zA-Z0-9_]*'
  fs="$(echo @|tr @ '\034')"

  sed -e 's|---||g' -ne "s|^\($s\)\($w\)$s:$s\"\(.*\)\"$s\$|\1$fs\2$fs\3|p" \
      -e "s|^\($s\)\($w\)$s[:-]$s\(.*\)$s\$|\1$fs\2$fs\3|p" "${pdf}" |
  awk -F"$fs" '{
    ret = index($0, "name:")
    if (ret == 5) {
      gsub("name:", "", $0)
      print $0
    }
  }'
}

function cleanup_vms {
  # clean up existing nodes
  for node in $(virsh list --name | grep -P 'cactus'); do
    virsh destroy "${node}"
  done
  for node in $(virsh list --name --all | grep -P 'cactus'); do
    virsh domblklist "${node}" | awk '/^.da/ {print $2}' | \
      xargs --no-run-if-empty -I{} sudo rm -f {}
    # TODO command 'undefine' doesn't support option --nvram
    virsh undefine "${node}" --remove-all-storage
  done
}

function prepare_vms {
  local image_dir=${STORAGE_DIR}
  local vnodes=("$@")

  cleanup_vms

  # Create vnode images and resize OS disk image for each foundation node VM
  for node in "${vnodes[@]}"; do
    enabled="nodes_${node}_enabled"
    if [ ${enabled} ]; then
      is_master="nodes_${node}_cloud_native_master"
      if [ ${is_master} ]; then
        image=k8sm.qcow2
      else
        image=node.qcow2
      fi
      cp "${image_dir}/${image}" "${image_dir}/cactus_${node}.qcow2"
      disk_capacity="nodes_${node}_disks_disk1_disk_capacity"
      qemu-img resize "${image_dir}/cactus_${node}.qcow2" ${disk_capacity}
    fi
  done
}

function create_networks {
  local vnode_networks=("$@")
  # create required networks, including constant "cactus_control"
  # FIXME(alav): since we renamed "pxe" to "cactus_control", we need to make sure
  # we delete the old "pxe" virtual network, or it would cause IP conflicts.
  for net in "pxe" "cactus_control" "${vnode_networks[@]}"; do
    if virsh net-info "${net}" >/dev/null 2>&1; then
      virsh net-destroy "${net}" || true
      virsh net-undefine "${net}"
    fi
    # in case of custom network, host should already have the bridge in place
    if [ -f "net_${net}.xml" ] && [ ! -d "/sys/class/net/${net}/bridge" ]; then
      virsh net-define "net_${net}.xml"
      virsh net-autostart "${net}"
      virsh net-start "${net}"
    fi
  done
}

function create_vms {
  local image_dir=$1; shift
  # vnode data should be serialized with the following format:
  # '<name0>,<ram0>,<vcpu0>|<name1>,<ram1>,<vcpu1>[...]'
  IFS='|' read -r -a vnodes <<< "$1"; shift
  cpu_pass_through=$1; shift
  local vnode_networks=("$@")

  # AArch64: prepare arch specific arguments
  local virt_extra_args=""
  if [ "$(uname -i)" = "aarch64" ]; then
    # No Cirrus VGA on AArch64, use virtio instead
    virt_extra_args="$virt_extra_args --video=virtio"
  fi

  # create vms with specified options
  for serialized_vnode_data in "${vnodes[@]}"; do
    IFS=',' read -r -a vnode_data <<< "${serialized_vnode_data}"

    # prepare network args
    net_args=" --network network=cactus_control,model=virtio"
    if [ "${DEPLOY_TYPE:-}" = 'baremetal' ]; then
      # 3rd interface gets connected to PXE/Admin Bridge (cfg01, mas01)
      vnode_networks[2]="${vnode_networks[0]}"
    fi
    for net in "${vnode_networks[@]:1}"; do
      net_args="${net_args} --network bridge=${net},model=virtio"
    done

    [ ${cpu_pass_through} -eq 1 ] && \
    cpu_para="--cpu host-passthrough" || \
    cpu_para=""

    # shellcheck disable=SC2086
    virt-install --name "${vnode_data[0]}" \
    --ram "${vnode_data[1]}" --vcpus "${vnode_data[2]}" \
    ${cpu_para} --accelerate ${net_args} \
    --disk path="${image_dir}/cactus_${vnode_data[0]}.qcow2",format=qcow2,bus=virtio,cache=none,io=native \
    --os-type linux --os-variant none \
    --boot hd --vnc --console pty --autostart --noreboot \
    --disk path="${image_dir}/cactus_${vnode_data[0]}.iso",device=cdrom \
    --noautoconsole \
    ${virt_extra_args}
  done
}

function update_cactus_control_network {
  # set static ip address for salt master node, MaaS node
  local cmac=$(virsh domiflist cfg01 2>&1| awk '/cactus_control/ {print $5; exit}')
  local amac=$(virsh domiflist mas01 2>&1| awk '/cactus_control/ {print $5; exit}')
  virsh net-update "cactus_control" add ip-dhcp-host \
    "<host mac='${cmac}' name='cfg01' ip='${SALT_MASTER}'/>" --live --config
  [ -z "${amac}" ] || virsh net-update "cactus_control" add ip-dhcp-host \
    "<host mac='${amac}' name='mas01' ip='${MAAS_IP}'/>" --live --config
}

function start_vms {
  local vnodes=("$@")

  # start vms
  for node in "${vnodes[@]}"; do
    virsh start "${node}"
    sleep $((RANDOM%5+1))
  done
}

function check_connection {
  local total_attempts=60
  local sleep_time=5

  set +e
  echo '[INFO] Attempting to get into Salt master ...'

  # wait until ssh on Salt master is available
  # shellcheck disable=SC2034
  for attempt in $(seq "${total_attempts}"); do
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "ubuntu@${SALT_MASTER}" uptime
    case $? in
      0) echo "${attempt}> Success"; break ;;
      *) echo "${attempt}/${total_attempts}> ssh server ain't ready yet, waiting for ${sleep_time} seconds ..." ;;
    esac
    sleep $sleep_time
  done
  set -e
}

function parse_yaml {
  local prefix=$2
  local s
  local w
  local fs
  s='[[:space:]]*'
  w='[a-zA-Z0-9_]*'
  fs="$(echo @|tr @ '\034')"
  sed -e 's|---||g' -ne "s|^\($s\)\($w\)$s:$s\"\(.*\)\"$s\$|\1$fs\2$fs\3|p" \
      -e "s|^\($s\)\($w\)$s[:-]$s\(.*\)$s\$|\1$fs\2$fs\3|p" "$1" |
  awk -F"$fs" '{
  indent = length($1)/2;
  vname[indent] = $2;
  for (i in vname) {if (i > indent) {delete vname[i]}}
      if (length($3) > 0) {
          vn=""; for (i=0; i<indent; i++) {vn=(vn)(vname[i])("_")}
          printf("%s%s%s=(\"%s\")\n", "'"$prefix"'",vn, $2, $3);
      }
  }' | sed 's/_=/+=/g'
}

function wait_for {
  # Execute in a subshell to prevent local variable override during recursion
  (
    local total_attempts=$1; shift
    local cmdstr=$1; shift
    local fail_func=$1
    local sleep_time=10
    echo -e "\n[wait_for] Waiting for cmd to return success: ${cmdstr}"
    # shellcheck disable=SC2034
    for attempt in $(seq "${total_attempts}"); do
      echo "[wait_for] Attempt ${attempt}/${total_attempts%.*} for: ${cmdstr}"
      if [ "${total_attempts%.*}" = "${total_attempts}" ]; then
        # shellcheck disable=SC2015
        eval "${cmdstr}" && echo "[wait_for] OK: ${cmdstr}" && return 0 || true
      else
        ! (eval "${cmdstr}" || echo 'No response') |& tee /dev/stderr | \
          grep -Eq '(Not connected|No response|No return received)' && \
          echo "[wait_for] OK: ${cmdstr}" && return 0 || true
      fi

      sleep "${sleep_time}"

      if [ -n "$fail_func" ];then
        echo "!!! Fail process is: $fail_func"
        eval "$fail_func"
      fi
    done

    echo "[wait_for] ERROR: Failed after max attempts: ${cmdstr}"

    return 1

  )
}

export CACHE_ALL_FILE_IN_MASTER=/tmp/all_nodes
export CACHE_SAME_FILE_IN_MASTER=$(dirname ${CACHE_ALL_FILE_IN_MASTER})/same_nodes
export ALL_NODES_IN_MASTER=""
export SAME_NODES_IN_MASTER=""
function generate_all_and_same_nodes_in_master {

  set +x

  CACHE_DIR=$(dirname ${CACHE_ALL_FILE_IN_MASTER})/
  rm -fr ${CACHE_ALL_FILE_IN_MASTER}
  rm -fr ${CACHE_SAME_FILE_IN_MASTER} && touch ${CACHE_SAME_FILE_IN_MASTER}

  node_file_list=$(find ${CACHE_DIR} -name "*.reclass.nodeinfo")
  for node_file in ${node_file_list}; do
    node_name=$(basename $node_file .reclass.nodeinfo)

    if [ ! -f ${CACHE_ALL_FILE_IN_MASTER} ]; then
      echo "${node_name}" > ${CACHE_ALL_FILE_IN_MASTER}
    else
      echo " or ${node_name}" >> ${CACHE_ALL_FILE_IN_MASTER}
    fi

    node_file_bak=${node_file}.bak
    if [ ! -f ${node_file_bak} ]; then
      continue
    fi
    node_diff=$(echo "$(diff ${node_file} ${node_file_bak} -I timestamp)" | xargs)
    if [ -z "${node_diff}" ]; then
      echo " and not $node_name" >> ${CACHE_SAME_FILE_IN_MASTER}
    else
      diff ${node_file} ${node_file_bak} -I timestamp -y || true
    fi
  done

  echo "=== Generate all and same configuration nodes list:"
  export ALL_NODES_IN_MASTER="$(cat ${CACHE_ALL_FILE_IN_MASTER} | xargs )"
  export SAME_NODES_IN_MASTER="$(cat ${CACHE_SAME_FILE_IN_MASTER} | xargs )"
  echo "All nodes in master: [${ALL_NODES_IN_MASTER}]"
  echo "Same node in master: [${SAME_NODES_IN_MASTER}]"
  echo "=== Generate all and same nodes end ==="

}

function restore_model_files_in_master {

  set +x

  CACHE_DIR=$(dirname ${CACHE_ALL_FILE_IN_MASTER})/

  node_file_list_bak=$(find ${CACHE_DIR} -name "*.reclass.nodeinfo.bak")
  for node_file_bak in ${node_file_list_bak}; do
    node_file=${node_file_bak%.*}
    echo " Restore old reclass file [${node_file_bak}]->[${node_file}]"
    mv -f ${node_file_bak} ${node_file} || true
  done

}

CACHE_ALL_FILE_LOCAL_DIR=$(dirname ${CACHE_ALL_FILE_IN_MASTER})/
CACHE_SAME_FILE_LOCAL_DIR=$(dirname ${CACHE_SAME_FILE_IN_MASTER})/
CACHE_ALL_FILE_LOCAL=${CACHE_ALL_FILE_IN_MASTER}
CACHE_SAME_FILE_LOCAL=${CACHE_SAME_FILE_IN_MASTER}
export ALL_NODES_LOCAL=""
export SAME_NODES_LOCAL=""
function get_all_and_same_nodes_from_master {

  set +x

  rm -fr ${CACHE_ALL_FILE_LOCAL} ${CACHE_SAME_FILE_LOCAL}
  scp ${SSH_OPTS} ${SSH_SALT}:${CACHE_ALL_FILE_IN_MASTER} ${CACHE_ALL_FILE_LOCAL_DIR}
  scp ${SSH_OPTS} ${SSH_SALT}:${CACHE_SAME_FILE_IN_MASTER} ${CACHE_SAME_FILE_LOCAL_DIR}
  if [ -f ${CACHE_ALL_FILE_LOCAL} ]; then
    export ALL_NODES_LOCAL="$(cat ${CACHE_ALL_FILE_LOCAL} | xargs )"
  fi
  if [ -f ${CACHE_SAME_FILE_LOCAL} ]; then
    export SAME_NODES_LOCAL="$(cat ${CACHE_SAME_FILE_LOCAL} | xargs )"
  fi

  echo "=== Get all and same configuration nodes list:"
  echo "All local nodes: [${ALL_NODES_LOCAL}]"
  echo "Same local nodes: [${SAME_NODES_LOCAL}]"
  echo "=== Get all and same nodes locally end ==="

}

function restart_salt_service {

  service_minion=${1:-salt-minion}
  service_master=${2:-""}

  if [ -n "$(command -v apt-get)" ]; then
    sudo service ${service_minion} stop || true
    sudo service ${service_minion} start || true
    [[ -n "${service_master}" ]] && {
      sudo service ${service_master} stop || true
      sudo service ${service_master} start || true
    }
  else
    sudo systemctl stop ${service_minion}  || true
    sudo systemctl start ${service_minion} || true
    [[ -n "${service_master}" ]] && {
      sudo systemctl stop ${service_master}  || true
      sudo systemctl start ${service_master}  || true
    }
  fi

  echo "Restart ${service_minion} ${service_master} successfully!"

}
