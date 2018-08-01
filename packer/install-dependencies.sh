#!/bin/bash

source /opt/azure/containers/provision.sh
source /opt/azure/containers/provision_installs.sh

# TODO: deal with etcd versions
ETCD_VERSION="3.2.23"
ETCD_DOWNLOAD_URL="https://acs-mirror.azureedge.net/github-coreos"
installEtcd

installDeps

DOCKER_REPO="https://apt.dockerproject.org/repo"
DOCKER_ENGINE_VERSION="1.13.*"
installDocker

installClearContainersRuntime
installKataContainersRuntime

VNET_CNI_PLUGINS_URL="https://acs-mirror.azureedge.net/cni/azure-vnet-cni-linux-amd64-latest.tgz"
CNI_PLUGINS_URL="https://acs-mirror.azureedge.net/cni/cni-plugins-amd64-latest.tgz"

CNI_CONFIG_DIR="/etc/cni/net.d"
CNI_BIN_DIR="/opt/cni/bin"
AZURE_CNI_TGZ_TMP="/tmp/azure_cni.tgz"
CONTAINERNETWORKING_CNI_TGZ_TMP="/tmp/containernetworking_cni.tgz"

installAzureCNI
installContainerd

# TODO: install multiple versions
HYPERKUBE_VERSION="v1.10.5"
HYPERKUBE_URL="k8s.gcr.io/hyperkube-amd64:${HYPERKUBE_VERSION}"
extractHyperkube

installFlexVolDrivers

echo "Install complete successfully" > /var/log/azure/golden-image-install.complete