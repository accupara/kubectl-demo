#!/bin/bash

export NAMESPACE=default
export ENABLE_AWS=0
export AWS_ACCOUNT=
export AWS_REGION=
export AWS_ACCESS_KEY_ID=
export AWS_SECRET_ACCESS_KEY=
export AWS_ECR_SECRET_PREFIX=
export K8S_PROXY_PORT=16190
export CLUSTER_MOUNTS=/tmp/src/k8s-demo:/tmp/src/combined
#(<src folder 1>:<dst folder1>,...) /opt/mongodb/data:/mongodb/data
export CLUSTER_PORT_FORWARDS="app=frontend:16191"
export KIND_WORKERS=0

export INGRESS_CONTROLLER="nginx"
export INGRESS_NAMESPACE="ingress-${INGRESS_CONTROLLER}"
export INGRESS_NAME=${INGRESS_NAMESPACE}

export GCP_CREDS_JSON_FILE=/tmp/src/k8s-demo.gcp.key.json
export GCP_CREDS_SECRET="google-cloud-key"


# my-demo-chart demo-chart/ --values demo-chart/values.yaml
export K8S_ENC_FILES=
export K8S_VAR_FILES=bichart/bichart-vars.yaml
export K8S_CHART_NAME=bichart
export K8S_CHART_REFERENCE=bichart/
export K8S_SECRET_ENV_FILES=.secrets
export K8S_SECRET_NAME=bichart-secrets


KUBECTL_EXE="kubectl"

sudo cp /root/go/bin/kind /usr/bin/kind
sudo chmod a+x /usr/bin/kind
KIND_EXE="/usr/bin/kind"
# KUBECTL_EXE="sudo ${KUBECTL_EXE}"

keep_running="yes"
CUR_USER=$USER

TMUX_SOCK=/tmp/tmux.sock.shared
rm -f ${TMUX_SOCK}
tmux -S ${TMUX_SOCK} new-session -d -s base
chmod a+rwx ${TMUX_SOCK}

trap 'keep_running="no"' 2

print_sep() {
	printf '%.s─' $(seq 1 $(tput cols))
	echo
}

print_title() {
	print_sep
	echo $* " @ `date`"
	print_sep
}

install_monit() {
        print_title "Configuring monit"
        cat <<EOF | sudo tee /etc/monit/conf.d/custom.settings
set daemon 5
set httpd port 2812 and
  allow localhost
  allow admin:monit
EOF
}

start_monit() {
	print_title "Starting monit"
	sudo monit -t
	echo Status:
	sudo monit
	sudo monit status
}

run_and_monitor_program() {
	processName=$1
	shift
	command=$1
	pidFile=/tmp/${processName}.pid
	echo "  Configuring monit for ${processName} with pidfile ${pidFile}"
	cat <<EOF | sudo tee /etc/monit/conf.d/${processName}
check process ${processName} with pidfile /tmp/${processName}.pid
  start program = "${command}"
  stop program = "/usr/bin/sleep 0.1"
EOF
}

create_tmux_session() {
	/usr/bin/tmux -S ${TMUX_SOCK} new-session -d -t $1
}

split_tmux_session() {
	/usr/bin/tmux -S ${TMUX_SOCK} split-window -t $1 -h bash
}

tmux_run_and_monitor_program() {
	tmux_session=$1
	shift
	program_name=$1
	shift
	program_exe=$1
	tmux_window="0"
	tmux -S ${TMUX_SOCK} has-session -t ${tmux_session} 2>/dev/null
	if [ "$?" == "0" ]
	then
		tmux_window=`tmux -S ${TMUX_SOCK} list-windows -t ${tmux_session} | wc -l`
		echo "  adding window to tmux_session ${tmux_session}"
		split_tmux_session ${tmux_session}
	else
		echo "  creating new tmux_session ${tmux_session}"
		create_tmux_session ${tmux_session}
	fi
	echo "  Monitoring program ${program_exe} of ${program_name} at tmux ${tmux_session} windows ${tmux_window}"
	run_and_monitor_program ${program_name} "/usr/bin/tmux -S ${TMUX_SOCK} send -t ${tmux_session}:0.${tmux_window} ${program_exe} C-m"
	# run_and_monitor_program ${program_name} "/usr/bin/tmux -S /tmp/${tmux_session}.tmux.sock -t ${tmux_session}:0.${tmux_window} ${program_exe} C-m"

}

setup_minikube_cluster_mounts() {
	if [ "${CLUSTER_MOUNTS}" == "" ]; then
		echo "No cluster mounts specified"
		return
	fi
	i=0
    for cmount in `echo ${CLUSTER_MOUNTS} | tr "," " "`; do
		print_title "Setting up minikube mount point $i."
		echo "  Creating minikube mount script"
		cat <<EOF > /tmp/minikube_mount.${i}.sh
#!/bin/bash
set -m
minikube mount ${cmount} &
pid=\$!
jobs -l
echo \$pid > /tmp/minikube_mount.${i}.pid
fg %1
EOF
		chmod a+x /tmp/minikube_mount.${i}.sh
		tmux_run_and_monitor_program minikube-mounts minikube_mount.${i} /tmp/minikube_mount.${i}.sh
		i=$((i+1))
    done
}

start_minikube() {
    #minikube delete
    minikube start --driver=docker --force
	setup_minikube_cluster_mounts
}

start_kind(){
	print_title "creating kind config"
	cat << EOF > /tmp/kind.config.mine
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
  extraMounts:
    - hostPath: /tmp/src/k8s-demo
      containerPath: /tmp/src/k8s-demo
EOF
	for i in `seq 1 ${KIND_WORKERS}`; do
		echo "- role: worker" >> /tmp/kind.config.mine
	done
	cat /tmp/kind.config.mine
	print_title "Starting kind cluster"
	${KIND_EXE} create cluster --config /tmp/kind.config.mine
	sleep 10
	${KUBECTL_EXE} get nodes
	${KUBECTL_EXE} taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule-
	${KUBECTL_EXE} taint nodes --all node.kubernetes.io/not-ready:NoSchedule-
	${KUBECTL_EXE} get nodes
}

setup_aws_credentials() {
	print_title "Setting up aws credentials file from environment"

	if [ "$AWS_ACCESS_KEY_ID" == "" -o "$AWS_SECRET_ACCESS_KEY" == "" ]; then
		echo "Could not find aws credentials in environment."
		return
	fi
	mkdir -p ~/.aws
	rm -f ~/.aws/credentials
	cat << EOF >> ~/.aws/credentials
[default]
aws_access_key_id = ${AWS_ACCESS_KEY_ID}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
EOF

	cat ~/.aws/credentials
}

create_aws_registry_secrets() {
  print_title "Creating AWS docker registry secrets."

  ${KUBECTL_EXE} delete secret ${AWS_ECR_SECRET_PREFIX}-${AWS_REGION} --ignore-not-found --namespace=${NAMESPACE}

	if [ "${AWS_REGION}" == "" -o "${AWS_ACCOUNT}" == "" -o "{AWS_ECR_SECRET_PREFIX}" == "" -o "${NAMESPACE}" == "" ]; then
		echo "Could not create AWS ECR secret, as it is missing one or more of the following fields."
		echo "AWS_REGION | AWS_ACCOUNT | AWS_ECR_SECRET_PREFIX | NAMESPACE"
		return
	fi

	${KUBECTL_EXE} create secret docker-registry ${AWS_ECR_SECRET_PREFIX}-${AWS_REGION} \
		--docker-server=${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com \
		--docker-username=AWS \
		--docker-password=$(/usr/local/bin/aws ecr get-login-password) \
		--namespace=${NAMESPACE}
}

create_gcp_sa_secrets() {

	print_title "Creating GCP CREDS Secret."
	${KUBECTL_EXE} delete secret ${GCP_CREDS_SECRET} --ignore-not-found --namespace=${NAMESPACE}
	${KUBECTL_EXE} create secret generic ${GCP_CREDS_SECRET} --from-file=key.json=${GCP_CREDS_JSON_FILE} \
	  --namespace=${NAMESPACE}

}

create_from_env_secrets() {
	print_title "Creating secrets from env files."
	for envfile in `echo ${K8S_SECRET_ENV_FILES} | tr "," " "`; do
		${KUBECTL_EXE} create secret generic ${K8S_SECRET_NAME} --from-env-file=${envfile}
	done
}

install_ingress_controller() {
	print_title "Installing nginx ingress controller."
	# helm upgrade --install ${INGRESS_NAME} ${INGRESS_NAME} --namespace ${INGRESS_NAMESPACE} \
	# 	--repo https://kubernetes.github.io/${INGRESS_NAME} \
	# 	--create-namespace \
	# 	--set controller.hostPort.enabled=true \
  #   --set controller.service.type=NodePort
	kubectl apply --filename https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/kind/deploy.yaml

	echo "  Waiting for ingress to come up"
	kubectl wait --namespace ${INGRESS_NAMESPACE} \
		--for=condition=ready pod \
		--selector=app.kubernetes.io/component=controller \
		--timeout=180s

	kubectl delete -A ValidatingWebhookConfiguration ingress-nginx-admission

	print_sep
}

install_chart() {
	print_title "Installing or upgrading helm chart."
	cd `dirname $0`
	echo "Using namespace $NAMESPACE"
	for f in `echo ${K8S_ENC_FILES} | tr "," " "`; do
		echo "Decrypting $f"
		helm secrets dec $f
		helm_file_args=${helm_file_args}" -f ${f}.dec"
	done
	for f in `echo ${K8S_VAR_FILES} | tr "," " "`; do
		echo "Adding $f"
		helm_file_args=${helm_file_args}" -f ${f}"
	done
	helm upgrade --install --namespace $NAMESPACE \
		--set global.namespace="$NAMESPACE" \
		${helm_file_args} \
		${K8S_CHART_NAME} ${K8S_CHART_REFERENCE}
	sleep 10
	${KUBECTL_EXE} get pods
}

setup_cluster_access_proxy() {
    print_title "Setting up cluster control proxy to port ${K8S_PROXY_PORT}."
	echo "  Creating port forward script"
	cat <<EOF > /tmp/setup_k8s_proxy.sh
#!/bin/bash
set -m
${KUBECTL_EXE} proxy --port ${K8S_PROXY_PORT} --address 0.0.0.0 --accept-hosts=".*" &
pid=\$!
jobs -l
echo \$pid > /tmp/k8s_proxy.pid
fg %1
EOF
	chmod a+x /tmp/setup_k8s_proxy.sh
    tmux_run_and_monitor_program k8s_proxy k8s_proxy /tmp/setup_k8s_proxy.sh
}

setup_port_frowards() {
    print_title "Setting up required port forwards."
    for cmount in ${CLUSTER_PORT_FORWARDS}; do
        appLabel=`echo ${cmount} | cut -d ":" -f 1`
	    targetPort=`echo ${cmount} | cut -d ":" -f 2`

		POD_NAME=$(${KUBECTL_EXE} get pods --namespace ${NAMESPACE} -l "${appLabel}" -o jsonpath="{.items[0].metadata.name}")
		CONTAINER_PORT=$(${KUBECTL_EXE} get pod --namespace ${NAMESPACE} $POD_NAME -o jsonpath="{.spec.containers[0].ports[0].containerPort}")

		echo "  Creating port forward script"
		cat <<EOF > /tmp/portforward.${targetPort}.sh
#!/bin/bash
set -m
POD_NAME=\$(${KUBECTL_EXE} get pods --namespace ${NAMESPACE} -l "${appLabel}" -o jsonpath="{.items[0].metadata.name}")
CONTAINER_PORT=\$(${KUBECTL_EXE} get pod --namespace ${NAMESPACE} \$POD_NAME -o jsonpath="{.spec.containers[0].ports[0].containerPort}")
sudo ${KUBECTL_EXE} --namespace ${NAMESPACE} port-forward --address 0.0.0.0  pod/\$POD_NAME $targetPort:\$CONTAINER_PORT &
pid=\$!
jobs -l
echo \$pid > /tmp/portforward.'${targetPort}'.pid
fg %1
EOF
		chmod a+x /tmp/portforward.${targetPort}.sh

		echo "Mapping: ${appLabel} pod: ${POD_NAME} container_port: ${CONTAINER_PORT} hostport: ${targetPort}"
		tmux_run_and_monitor_program portforwards portforward.${targetPort} /tmp/portforward.${targetPort}.sh
    done
}

setup_ingress_port_frowards() {
    print_title "Setting up required port forwards for ingress."
	echo "  Creating port forward script"
	cat <<EOF > /tmp/portforward.${targetPort}.sh
#!/bin/bash
set -m
sudo ${KUBECTL_EXE} port-forward -n ingress-nginx --address 0.0.0.0 svc/ingress-nginx-controller 8080:80
pid=\$!
jobs -l
echo \$pid > /tmp/portforward.'${targetPort}'.pid
fg %1
EOF
	chmod a+x /tmp/portforward.${targetPort}.sh

	echo "Mapping: ${appLabel} pod: ${POD_NAME} container_port: ${CONTAINER_PORT} hostport: ${targetPort}"
	tmux_run_and_monitor_program portforwards portforward.${targetPort} /tmp/portforward.${targetPort}.sh
}



waitfor_pod_ready() {
	echo "Waiting for pod $1 to be ready"
	${KUBECTL_EXE} wait --timeout=2400s --for=condition=ready pod -l $1
}

install_monit
# if [ "$1" == "kind" ]; then
# 	start_kind
# else
# 	start_minikube
# fi
start_kind
install_ingress_controller
create_aws_registry_secrets
create_from_env_secrets
create_gcp_sa_secrets
install_chart
setup_ingress_port_frowards
setup_cluster_access_proxy

start_monit
while [ "${keep_running}" == "yes" ]; do
	# main body of your script here
	sleep 5
	print_sep
	sudo monit status
	print_title "The k8s cluster has started. Please keep this window running."
	echo "To check on port forwarding, use 'tmux a -t portforwads'."
	echo "To check on k8s proxy, use 'tmux a -t k8s_proxy'."
	k8s_proxy_pid=`cat /tmp/k8s_proxy.pid 2> /dev/null`
	if [ "${k8s_proxy_pid}" != "" ]
	then
		while [ -e /proc/${k8s_proxy_pid} ]
		do
			sleep 2
			if [ "${keep_running}" != "yes" ]; then
				break
			fi
		done
	fi
done
sudo monit stop
kill -9 `cat /tmp/k8s_proxy.pid`
