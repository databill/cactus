#!/usr/bin/env bash

function __get_bridges {
  identity_=idf_cactus_jumphost_bridges_
  compgen -v |
  while read var; do {
    [[ ${var} =~ ${identity_} ]] && echo ${var#${identity_}}
  }
  done || true
}

function prepare_networks {
  BRIDGES=$(__get_bridges)

  [[ ! "#{BRIDGES[@]}" =~ "admin" ]] && {
    notify_n "[ERR] Bridge admin must be defined\n" 2
    exit 1
  }

  [[ ! "#{BRIDGES[@]}" =~ "mgmt" ]] && {
    notify_n "[ERR] Bridge mgmt must be defined\n" 2
    exit 1
  }

  # Expand network templates
  for tp in "${DEPLOY_DIR}/"*.template; do
    eval "cat <<-EOF
      $(<"${tp}")
EOF" 2> /dev/null > "${tp%.template}"
  done
}

function build_images {
  local builder_image=cactus/dib:latest
  local dib_name=cactus_image_builder
  local sshpub="${SSH_KEY}.pub"

  [[ "$(docker images -q ${builder_image} 2>/dev/null)" != "" ]] || {
    echo "build diskimage_builder image... "
    pushd ${REPO_ROOT_PATH}/docker/dib
    docker build -t ${builder_image} .
    popd
  }

  echo "Start DIB console named ${dib_name} service ... "
  docker run -it \
           --name ${dib_name} \
           -v ${STORAGE_DIR}:/imagedata \
           -v ${REPO_ROOT_PATH}/kube-config:/elements/master-static/static/home/cactus/kube-config \
           --privileged \
           --rm \
           ${builder_image} \
           bash /create_image.sh
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

  cleanup_vms

  # Create vnode images and resize OS disk image for each foundation node VM
  for node in "${vnodes[@]}"; do
    if [ $(eval echo "\$nodes_${node}_enabled") == "True" ]; then
      if is_master ${node}; then
        echo "preparing for master vnode [${node}]"
        image="k8s/master.qcow2"
      else
        echo "preparing for minion vnode [${node}]"
        image="k8s/minion.qcow2"
      fi
      cp "${image_dir}/${image}" "${image_dir}/cactus_${node}.qcow2"
      disk_capacity="nodes_${node}_node_disk"
      qemu-img resize "${image_dir}/cactus_${node}.qcow2" ${!disk_capacity}
    fi
  done
}

function create_networks {
  # create required networks
  for net in "${BRIDGES[@]}"; do
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
  cpu_pass_through=$1; shift

  # AArch64: prepare arch specific arguments
  local virt_extra_args=""
  if [ "$(uname -i)" = "aarch64" ]; then
    # No Cirrus VGA on AArch64, use virtio instead
    virt_extra_args="$virt_extra_args --video=virtio"
  fi

  # create vms with specified options
  for vnode in "${vnodes[@]}"; do
    # prepare network args
    net_args=""
    for net in "${BRIDGES[@]}"; do
      net_args="${net_args} --network bridge=${net},model=virtio"
    done

    [ ${cpu_pass_through} -eq 1 ] && \
    cpu_para="--cpu host-passthrough" || \
    cpu_para=""

    # shellcheck disable=SC2086
    virt-install --name "cactus_${vnode}" \
    --memory $(eval echo "\$nodes_${vnode}_node_memory") \
    --vcpus $(eval echo "\$nodes_${vnode}_node_cpus")\
    ${cpu_para} --accelerate ${net_args} \
    --disk path="${STORAGE_DIR}/cactus_${vnode}.qcow2",format=qcow2,bus=virtio,cache=none,io=native \
    --os-type linux --os-variant none \
    --boot hd --vnc --console pty --autostart --noreboot \
    --noautoconsole \
    ${virt_extra_args}
  done
}

function update_admin_network {
  for vnode in "${vnodes[@]}"; do
    local admin_br="${idf_cactus_jumphost_bridges_admin}"
    local guest="cactus_${vnode}"
    local admin_ip=$(get_admin_ip ${vnode})
    local admin_mac=$(virsh domiflist ${guest} 2>&1| awk -v br=${admin_br} '/br/ {print $5; exit}')
    virsh net-update "${admin_br}" add ip-dhcp-host \
      "<host mac='${admin_mac}' name='${guest}' ip='${admin_ip}'/>" --live --config
  done
}

function update_mgmt_network {
  for vnode in "${vnodes[@]}"; do
    local mgmt_br="${idf_cactus_jumphost_bridges_mgmt}"
    local guest="cactus_${vnode}"
    local mgmt_ip=$(get_mgmt_ip ${vnode})
    local mgmt_mac=$(virsh domiflist ${guest} 2>&1| awk -v br=${mgmt_br} '/br/ {print $5; exit}')
    virsh net-update "${mgmt_br}" add ip-dhcp-host \
      "<host mac='${mgmt_mac}' name='${guest}' ip='${mgmt_ip}'/>" --live --config
  done}

function start_vms {
  # start vms
  for node in "${vnodes[@]}"; do
    virsh start "cactus_${node}"
    sleep $((RANDOM%5+1))
  done
}

function check_connection {
  local total_attempts=60
  local sleep_time=5

  set +e
  echo '[INFO] Attempting to get into master ...'

  # wait until ssh on master is available
  # shellcheck disable=SC2034
  for vnode in "${vnodes[@]}"; do
    if is_master ${vnode}; then
      for attempt in $(seq "${total_attempts}"); do
        ssh_exc $(get_admin_ip ${vnode}) uptime
        case $? in
          0) echo "${attempt}> Success"; break ;;
          *) echo "${attempt}/${total_attempts}> master ain't ready yet, waiting for ${sleep_time} seconds ..." ;;
        esac
        sleep $sleep_time
      done
    fi
  done
  set -e
}