#!/bin/bash -ve

# Disable pointless daemons
systemctl stop snapd snapd.socket lxcfs snap.amazon-ssm-agent.amazon-ssm-agent
systemctl disable snapd snapd.socket lxcfs snap.amazon-ssm-agent.amazon-ssm-agent

# Disable swap to make K8S happy
swapoff -a
sed -i '/swap/d' /etc/fstab

# Install docker
apt-get update && apt-get install -y apt-transport-https ca-certificates curl software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository \
  "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) \
  stable"
apt-get update && apt-get install -y docker-ce=18.06.2~ce~3-0~ubuntu
cat > /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF
mkdir -p /etc/systemd/system/docker.service.d
systemctl daemon-reload
systemctl restart docker

# Install kubelet, kubeadm, kubectl
apt-get update && apt-get install -y apt-transport-https curl awscli jq
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOF
apt-get update
apt-get install -y kubelet=${k8sversion}-00 kubeadm=${k8sversion}-00 kubectl=${k8sversion}-00
apt-mark hold kubelet kubeadm kubectl

# Point kubelet at big ephemeral drive
mkdir /mnt/kubelet
echo 'KUBELET_EXTRA_ARGS="--root-dir=/mnt/kubelet --cloud-provider=aws"' > /etc/default/kubelet

# Join the cluster
for i in {1..50}; do kubeadm join --token=${k8stoken} --discovery-token-unsafe-skip-ca-verification --node-name=$(hostname -f) ${masterIP}:6443 && break || sleep 15; done
