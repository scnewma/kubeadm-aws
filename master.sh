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

# Install etcdctl for the version of etcd we're running
ETCD_VERSION=$(kubeadm config images list | grep etcd | cut -d':' -f2 | cut -d'-' -f1)
wget "https://github.com/coreos/etcd/releases/download/v$${ETCD_VERSION}/etcd-v$${ETCD_VERSION}-linux-amd64.tar.gz"
tar xvf "etcd-v$${ETCD_VERSION}-linux-amd64.tar.gz"
mv "etcd-v$${ETCD_VERSION}-linux-amd64/etcdctl" /usr/local/bin/
rm -rf etcd*

# Work around the fact spot requests can't tag their instances
REGION=$(ec2metadata --availability-zone | rev | cut -c 2- | rev)
INSTANCE_ID=$(ec2metadata --instance-id)
aws --region $REGION ec2 create-tags --resources $INSTANCE_ID --tags "Key=Name,Value=${clustername}-master" "Key=Environment,Value=${clustername}" "Key=kubernetes.io/cluster/${clustername},Value=owned"

# Point kubelet at big ephemeral drive
mkdir /mnt/kubelet
echo 'KUBELET_EXTRA_ARGS="--root-dir=/mnt/kubelet --cloud-provider=aws"' > /etc/default/kubelet

cat >init-config.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta2
kind: InitConfiguration
bootstrapTokens:
- groups:
  - system:bootstrappers:kubeadm:default-node-token
  token: "${k8stoken}"
  ttl: "0"
nodeRegistration:
  name: "$(hostname -f)"
  taints: []
---
apiVersion: kubeadm.k8s.io/v1beta2
kind: ClusterConfiguration
apiServer:
  extraArgs:
    cloud-provider: aws
controllerManager:
  extraArgs:
    cloud-provider: aws
networking:
  podSubnet: 192.168.0.0/16
EOF

# Check if there is an etcd backup on the s3 bucket and restore from it if there is
if [ $(aws s3 ls s3://${s3bucket}/etcd-backups/ | wc -l) -ne 0 ]; then
  echo "Found existing etcd backup. Restoring from it instead of starting from fresh."
  latest_backup=$(aws s3api list-objects --bucket ${s3bucket} --prefix etcd-backups --query 'reverse(sort_by(Contents,&LastModified))[0]' | jq -rc .Key)

  echo "Downloading latest etcd backup"
  aws s3 cp s3://${s3bucket}/$latest_backup etcd-snapshot.db
  old_instance_id=$(echo $latest_backup | cut -d'/' -f2)

  echo "Downloading kubernetes ca cert and key backup"
  aws s3 cp s3://${s3bucket}/pki/$old_instance_id/ca.crt /etc/kubernetes/pki/ca.crt
  chmod 644 /etc/kubernetes/pki/ca.crt
  aws s3 cp s3://${s3bucket}/pki/$old_instance_id/ca.key /etc/kubernetes/pki/ca.key
  chmod 600 /etc/kubernetes/pki/ca.key

  echo "Restoring downloaded etcd backup"
  ETCDCTL_API=3 /usr/local/bin/etcdctl snapshot restore etcd-snapshot.db
  mkdir -p /var/lib/etcd
  mv default.etcd/member /var/lib/etcd/

  echo "Running kubeadm init"
  kubeadm init --ignore-preflight-errors="DirAvailable--var-lib-etcd,NumCPU" --config=init-config.yaml
else
  echo "Running kubeadm init"
  kubeadm init --config=init-config.yaml --ignore-preflight-errors=NumCPU
  touch /tmp/fresh-cluster
fi

# Set up kubectl for the ubuntu user
mkdir -p /home/ubuntu/.kube && cp -i /etc/kubernetes/admin.conf /home/ubuntu/.kube/config && chown -R ubuntu. /home/ubuntu/.kube
echo 'source <(kubectl completion bash)' >> /home/ubuntu/.bashrc

# Install helm
wget https://storage.googleapis.com/kubernetes-helm/helm-v2.12.0-linux-amd64.tar.gz
tar xvf helm-v2.12.0-linux-amd64.tar.gz
mv linux-amd64/helm /usr/local/bin/
rm -rf linux-amd64 helm-*

if [ -f /tmp/fresh-cluster ]; then
    su -c 'kubectl apply -f https://docs.projectcalico.org/v3.8/manifests/calico.yaml' ubuntu

  # Set up helm
  su -c 'kubectl create serviceaccount tiller --namespace=kube-system' ubuntu
  su -c 'kubectl create clusterrolebinding tiller-admin --serviceaccount=kube-system:tiller --clusterrole=cluster-admin' ubuntu
  # This is a workaround since helm init fails on K8s 1.16.x because of api group change
  # See https://github.com/helm/helm/issues/6374
  su -c 'helm init --service-account tiller --output yaml | sed '"'"'s@apiVersion: extensions/v1beta1@apiVersion: apps/v1@'"'"' | sed '"'"'s@  replicas: 1@  replicas: 1\n  selector: {"matchLabels": {"app": "helm", "name": "tiller"}}@'"'"' | kubectl apply -f -' ubuntu
  su -c 'helm init --client-only' ubuntu

  # Install cert-manager
  if [[ "${certmanagerenabled}" == "1" ]]; then
    sleep 60 # Give Tiller a minute to start up

    su -c 'kubectl apply -f https://raw.githubusercontent.com/jetstack/cert-manager/release-0.10/deploy/manifests/00-crds.yaml' ubuntu
    su -c 'helm repo add jetstack https://charts.jetstack.io' ubuntu
    su -c 'helm install --name cert-manager --namespace cert-manager --version 0.10.1 jetstack/cert-manager' ubuntu
  fi

  # Install all the YAML we've put on S3
  mkdir /tmp/manifests
  aws s3 sync s3://${s3bucket}/manifests/ /tmp/manifests
  su -c 'kubectl apply -f /tmp/manifests/' ubuntu
fi

# Set up backups if they have been enabled
if [[ "${backupenabled}" == "1" ]]; then
  # One time backup of kubernetes directory
  aws s3 cp /etc/kubernetes/pki/ca.crt s3://${s3bucket}/pki/$INSTANCE_ID/
  aws s3 cp /etc/kubernetes/pki/ca.key s3://${s3bucket}/pki/$INSTANCE_ID/

  # Back up etcd to s3 every 15 minutes. The lifecycle policy in terraform will keep 7 days to save us doing that logic here.
  cat <<-EOF > /usr/local/bin/backup-etcd.sh
	#!/bin/bash
	ETCDCTL_API=3 /usr/local/bin/etcdctl --cacert='/etc/kubernetes/pki/etcd/ca.crt' --cert='/etc/kubernetes/pki/etcd/peer.crt' --key='/etc/kubernetes/pki/etcd/peer.key' snapshot save etcd-snapshot.db
	aws s3 cp etcd-snapshot.db s3://${s3bucket}/etcd-backups/$INSTANCE_ID/etcd-snapshot-\$(date -Iseconds).db
	EOF

  echo "${backupcron} root bash /usr/local/bin/backup-etcd.sh" > /etc/cron.d/backup-etcd

  # Poll the spot instance termination URL and backup immediately if it returns a 200 response.
  cat <<-'EOF' > /usr/local/bin/check-termination.sh
	#!/bin/bash
	# Mostly borrowed from https://github.com/kube-aws/kube-spot-termination-notice-handler/blob/master/entrypoint.sh
	
	POLL_INTERVAL=10
	NOTICE_URL="http://169.254.169.254/latest/meta-data/spot/termination-time"
	
	echo "Polling $${NOTICE_URL} every $${POLL_INTERVAL} second(s)"
	
	# To whom it may concern: http://superuser.com/questions/590099/can-i-make-curl-fail-with-an-exitcode-different-than-0-if-the-http-status-code-i
	while http_status=$(curl -o /dev/null -w '%%{http_code}' -sL $${NOTICE_URL}); [ $${http_status} -ne 200 ]; do
	  echo "Polled termination notice URL. HTTP Status was $${http_status}."
	  sleep $${POLL_INTERVAL}
	done
	
	echo "Polled termination notice URL. HTTP Status was $${http_status}. Triggering backup."
	/bin/bash /usr/local/bin/backup-etcd.sh
	sleep 300 # Sleep for 5 minutes, by which time the machine will have terminated.
	EOF

  cat <<-'EOF' > /etc/systemd/system/check-termination.service
	[Unit]
	Description=Spot Termination Checker
	After=network.target
	[Service]
	Type=simple
	Restart=always
	RestartSec=10
	User=root
	ExecStart=/bin/bash /usr/local/bin/check-termination.sh
	
	[Install]
	WantedBy=multi-user.target
	EOF

  systemctl start check-termination
  systemctl enable check-termination
fi
