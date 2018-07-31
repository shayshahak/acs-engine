#!/bin/bash
set -x
echo `date`,`hostname`, startscript>>/opt/m
source /opt/azure/containers/provision_source.sh
source /opt/azure/containers/provision_installs.sh
source /opt/azure/containers/provision_configs.sh

ERR_SYSTEMCTL_ENABLE_FAIL=3 # Service could not be enabled by systemctl
ERR_SYSTEMCTL_START_FAIL=4 # Service could not be started by systemctl
ERR_CLOUD_INIT_TIMEOUT=5 # Timeout waiting for cloud-init runcmd to complete
ERR_FILE_WATCH_TIMEOUT=6 # Timeout waiting for a file
ERR_HOLD_WALINUXAGENT=7 # Unable to place walinuxagent apt package on hold during install
ERR_RELEASE_HOLD_WALINUXAGENT=8 # Unable to release hold on walinuxagent apt package after install
ERR_APT_INSTALL_TIMEOUT=9 # Timeout installing required apt packages
ERR_ETCD_DATA_DIR_NOT_FOUND=10 # Etcd data dir not found
ERR_ETCD_RUNNING_TIMEOUT=11 # Timeout waiting for etcd to be accessible
ERR_ETCD_DOWNLOAD_TIMEOUT=12 # Timeout waiting for etcd to download
ERR_ETCD_VOL_MOUNT_FAIL=13 # Unable to mount etcd disk volume
ERR_ETCD_START_TIMEOUT=14 # Unable to start etcd runtime
ERR_ETCD_CONFIG_FAIL=15 # Unable to configure etcd cluster
ERR_DOCKER_INSTALL_TIMEOUT=20 # Timeout waiting for docker install
ERR_DOCKER_DOWNLOAD_TIMEOUT=21 # Timout waiting for docker download(s)
ERR_DOCKER_KEY_DOWNLOAD_TIMEOUT=22 # Timeout waiting to download docker repo key
ERR_DOCKER_APT_KEY_TIMEOUT=23 # Timeout waiting for docker apt-key
ERR_K8S_RUNNING_TIMEOUT=30 # Timeout waiting for k8s cluster to be healthy
ERR_K8S_DOWNLOAD_TIMEOUT=31 # Timeout waiting for Kubernetes download(s)
ERR_KUBECTL_NOT_FOUND=32 # kubectl client binary not found on local disk
ERR_CNI_DOWNLOAD_TIMEOUT=41 # Timeout waiting for CNI download(s)
ERR_MS_PROD_DEB_DOWNLOAD_TIMEOUT=42 # Timeout waiting for https://packages.microsoft.com/config/ubuntu/16.04/packages-microsoft-prod.deb
ERR_MS_PROD_DEB_PKG_ADD_FAIL=43 # Failed to add repo pkg file
ERR_FLEXVOLUME_DOWNLOAD_TIMEOUT=44 # Failed to add repo pkg file
ERR_MODPROBE_FAIL=49 # Unable to load a kernel module using modprobe
ERR_OUTBOUND_CONN_FAIL=50 # Unable to establish outbound connection
ERR_KATA_KEY_DOWNLOAD_TIMEOUT=60 # Timeout waiting to download kata repo key
ERR_KATA_APT_KEY_TIMEOUT=61 # Timeout waiting for kata apt-key
ERR_KATA_INSTALL_TIMEOUT=62 # Timeout waiting for kata install
ERR_CUSTOM_SEARCH_DOMAINS_FAIL=80 # Unable to configure custom search domains
ERR_APT_DAILY_TIMEOUT=98 # Timeout waiting for apt daily updates
ERR_APT_UPDATE_TIMEOUT=99 # Timeout waiting for apt-get update to complete

OS=$(cat /etc/*-release | grep ^ID= | tr -d 'ID="' | awk '{print toupper($0)}')
UBUNTU_OS_NAME="UBUNTU"
RHEL_OS_NAME="RHEL"
COREOS_OS_NAME="COREOS"
KUBECTL=/usr/local/bin/kubectl
DOCKER=/usr/bin/docker
CNI_BIN_DIR=/opt/cni/bin
CUSTOM_SEARCH_DOMAIN_SCRIPT=/opt/azure/containers/setup-custom-search-domains.sh

set +x
ETCD_PEER_CERT=$(echo ${ETCD_PEER_CERTIFICATES} | cut -d'[' -f 2 | cut -d']' -f 1 | cut -d',' -f $((${MASTER_INDEX}+1)))
ETCD_PEER_KEY=$(echo ${ETCD_PEER_PRIVATE_KEYS} | cut -d'[' -f 2 | cut -d']' -f 1 | cut -d',' -f $((${MASTER_INDEX}+1)))
set -x

if [[ $OS == $COREOS_OS_NAME ]]; then
    echo "Changing default kubectl bin location"
    KUBECTL=/opt/kubectl
fi

if [ -f /var/run/reboot-required ]; then
    REBOOTREQUIRED=true
else
    REBOOTREQUIRED=false
fi

if [ -f /var/log/azure/golden-image-install.complete ]; then
    echo "detected golden image pre-install"
    FULL_INSTALL_REQUIRED=false
else
    FULL_INSTALL_REQUIRED=true
fi

function testOutboundConnection() {
    retrycmd_if_failure 20 1 3 nc -v 8.8.8.8 53 || retrycmd_if_failure 20 1 3 nc -v 8.8.4.4 53 || exit $ERR_OUTBOUND_CONN_FAIL
}

function waitForCloudInit() {
    wait_for_file 1200 1 /var/log/azure/cloud-init.complete || exit $ERR_CLOUD_INIT_TIMEOUT
}

function holdWALinuxAgent() {
    if [[ $OS == $UBUNTU_OS_NAME ]]; then
        # make sure walinuxagent doesn't get updated in the middle of running this script
        retrycmd_if_failure 20 5 30 apt-mark hold walinuxagent || exit $ERR_HOLD_WALINUXAGENT
    fi
}

testOutboundConnection
holdWALinuxAgent
waitForCloudInit

if $FULL_INSTALL_REQUIRED; then
    installEtcd
    installDeps
    installContainerRuntime
    installNetworkPlugin
    installContainerd
    extractHyperkube
    installFlexVolDrivers
else 
    echo "Golden image; skipping dependencies installation"
fi

ensureRPC

if [[ ! -z "${MASTER_NODE}" ]]; then
    configureEtcd
    configAddons
fi

if [[ "$CONTAINER_RUNTIME" == "docker" ]]; then
    ensureDocker
elif [[ "$CONTAINER_RUNTIME" == "clear-containers" ]]; then
	# Ensure we can nest virtualization
	if grep -q vmx /proc/cpuinfo; then
        ensureCCProxy
	fi
fi

ensureContainerd
configureK8s
ensureKubelet
ensureJournal
writeKubeConfig



if [[ ! -z "${MASTER_NODE}" && ! -z "${EnableEncryptionWithExternalKms}" ]]; then
    ensureKMS
fi

if [ -f $CUSTOM_SEARCH_DOMAIN_SCRIPT ]; then
    $CUSTOM_SEARCH_DOMAIN_SCRIPT > /opt/azure/containers/setup-custom-search-domain.log 2>&1 || exit $ERR_CUSTOM_SEARCH_DOMAINS_FAIL
fi

if [[ ! -z "${MASTER_NODE}" ]]; then
    ensureEtcd
    ensureK8sControlPlane
fi

if [[ $OS == $UBUNTU_OS_NAME ]]; then
    # mitigation for bug https://bugs.launchpad.net/ubuntu/+source/linux/+bug/1676635
    echo 2dd1ce17-079e-403c-b352-a1921ee207ee > /sys/bus/vmbus/drivers/hv_util/unbind
    sed -i "13i\echo 2dd1ce17-079e-403c-b352-a1921ee207ee > /sys/bus/vmbus/drivers/hv_util/unbind\n" /etc/rc.local

    retrycmd_if_failure 20 5 30 apt-mark unhold walinuxagent || exit $ERR_RELEASE_HOLD_WALINUXAGENTs
fi

echo "Custom script finished successfully"

mkdir -p /opt/azure/containers && touch /opt/azure/containers/provision.complete
ps auxfww > /opt/azure/provision-ps.log &

if $REBOOTREQUIRED; then
  # wait 1 minute to restart node, so that the custom script extension can complete
  echo 'reboot required, rebooting node in 1 minute'
  /bin/bash -c "shutdown -r 1 &"
else
  runAptDaily &
fi
