#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

export APTGET="sudo apt-get"
export APTMARK="sudo apt-mark"
export APTKEY="sudo apt-key"
export ADDAPT="sudo add-apt-repository"

CLUSTER_CIDR=${CLUSTER_CIDR:-"10.244.0.0"}
NETWORK_PLUGIN=calico

export K8S_ROOT=$(dirname "${BASH_SOURCE}")


source ${K8S_ROOT}/deps.sh
source ${K8S_ROOT}/prepare.sh
source ${K8S_ROOT}/cni.sh

function deploy-k8s() {
    sudo kubeadm init --pod-network-cidr 10.244.0.1/16 --kubernetes-version v1.10.7
}

function config-kubectl() {
    mkdir -p $HOME/.kube
    sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
    kubectl taint nodes --all node-role.kubernetes.io/master-
}

function install-dashboard() {
    kubectl apply -f ../kube-config/dashboard.yaml
}

function main() {
#    swap-off
#    install-docker
#    install-kubetools
    deploy-k8s
    config-kubectl
    install-calico
    install-dashboard
}

main