#! /bin/bash

set -eE
set -x


if ! which ocne; then
	if [ -z "$HEADLAMP_SKIP_INSTALL_DEPS" ]; then
		sudo dnf install -y ocne
	else
		echo "The ocne cli is required"
		exit 1
	fi
fi

if ! which podman; then
	if [ -z "$HEADLAMP_SKIP_INSTALL_DEPS" ]; then
		sudo dnf install -y podman
	else
		echo "podman is required"
		exit 1
	fi
fi

if ! which kubectl; then
	if [ -z "$HEADLAMP_SKIP_INSTALL_DEPS" ]; then
		sudo dnf install -y kubectl
	else
		echo "kubectl is required"
		exit 1
	fi
fi

if ! which git; then
	if [ -z "$HEADLAMP_SKIP_INSTALL_DEPS" ]; then
		sudo dnf install -y git
	else
		echo "git is required"
		exit 1
	fi
fi

git clone https://github.com/oracle-cne/tests ocne-tests

if ! which virsh; then
	if [ -z "$HEADLAMP_SKIP_INSTALL_DEPS" ]; then
		if [ -f /etc/os-release ]; then
			os_id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
			os_version_id=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
			os_major_version=${os_version_id%%.*}

			if [ "$os_id" = "ol" ] && [ "$os_major_version" = "8" ]; then
				dnf install -y oracle-ocne-release-el8 oraclelinux-developer-release-el8 oracle-epel-release-el8
				dnf config-manager --enable ol8_kvm_appstream ol8_UEKR7 ol8_ocne ol8_developer_EPEL ol8_olcne19 ol8_codeready_builder

				dnf module reset virt:ol
				dnf module install -y virt:kvm_utils3/common

				if [ -z "$(rpm -qa podman)" ]; then
					dnf install -y podman
				fi


				# Fix up an issue with libvirt and XATTR in containers
				sed -i 's/#remember_owner = 1/remember_owner = 0/g' /etc/libvirt/qemu.conf
				sed -i 's/#namespaces = .*/namespaces = []/g' /etc/libvirt/qemu.conf

				if [ ! -e /dev/kvm ] && [ -n "$KVM_MINOR" ]; then
					mknod /dev/kvm c 10 $KVM_MINOR
				fi

				systemctl enable --now libvirtd.service

			fi
		fi
	fi
fi

export HEADLAMP_CLUSTER_NAME=flannel-test
export IMG_NAME="container-registry.oracle.com/olcne/flannel"
export TAG="v0.28.1"
export NGINX_IMG_NAME="container-registry.oracle.com/olcne/nginx"
flannel_selector="app=flannel"
delete_ocne_cluster=false
test_started=false

if [ -z "${KUBECONFIG:-}" ]; then
	delete_ocne_cluster=true
	ocne cluster start --auto-start-ui=false -C "$HEADLAMP_CLUSTER_NAME" --control-plane-nodes 3 --worker-nodes 3
	export KUBECONFIG
	KUBECONFIG=$(ocne cluster show -C "$HEADLAMP_CLUSTER_NAME")
fi

cluster_nodes=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

if [ -z "$cluster_nodes" ]; then
	echo "Unable to determine the cluster nodes from the current KUBECONFIG"
	exit 1
fi

nginx_tag=""
for cluster_node in $cluster_nodes; do
	echo "Inspecting ${NGINX_IMG_NAME} on node ${cluster_node}"
	node_nginx_tags=$(
		ocne cluster console --direct --node "$cluster_node" -- podman images --format '{{.Repository}} {{.Tag}}' |
			awk -v repo="$NGINX_IMG_NAME" '$1 == repo && $2 != "<none>" { print $2 }' |
			sort -u
	)

	if [ -z "$node_nginx_tags" ]; then
		echo "Node ${cluster_node} does not have ${NGINX_IMG_NAME}"
		exit 1
	fi

	if [ "$(printf '%s\n' "$node_nginx_tags" | awk 'NF { count++ } END { print count + 0 }')" -ne 1 ]; then
		echo "Node ${cluster_node} has multiple tags for ${NGINX_IMG_NAME}: ${node_nginx_tags}"
		exit 1
	fi

	node_nginx_tag=$(printf '%s\n' "$node_nginx_tags")
	echo "Node ${cluster_node} uses nginx image tag ${node_nginx_tag}"

	if [ -z "$nginx_tag" ]; then
		nginx_tag="$node_nginx_tag"
	elif [ "$nginx_tag" != "$node_nginx_tag" ]; then
		echo "Node ${cluster_node} has nginx image tag ${node_nginx_tag}, expected ${nginx_tag}"
		exit 1
	fi

	podman save "${IMG_NAME}:${TAG}" | ocne cluster console --direct --node "$cluster_node" -- podman load
	echo -n "" | ocne cluster console --direct --node "$cluster_node" -- podman tag "${IMG_NAME}:${TAG}" "${IMG_NAME}:current"
done

if [ -z "$nginx_tag" ]; then
	echo "Unable to determine a shared nginx image tag from the cluster nodes"
	exit 1
fi

NGINX_IMAGE="${NGINX_IMG_NAME}:${nginx_tag}"
echo "Using nginx image ${NGINX_IMAGE} for ocne-tests"

ocne_basic_test_script=""
for candidate in ocne-tests/tools/basic_k8s_tests.sh ocne-tests/tools/basic_k8s_test.sh; do
	if [ -f "$candidate" ]; then
		ocne_basic_test_script="$candidate"
		break
	fi
done

if [ -z "$ocne_basic_test_script" ]; then
	echo "Unable to find ocne-tests basic Kubernetes test script"
	exit 1
fi

if grep -q '^NGINX_IMAGE=' "$ocne_basic_test_script"; then
	sed -i "s|^NGINX_IMAGE=.*|NGINX_IMAGE=\"${NGINX_IMAGE}\"|" "$ocne_basic_test_script"
else
	sed -i "1a NGINX_IMAGE=\"${NGINX_IMAGE}\"" "$ocne_basic_test_script"
fi

echo "Updated ${ocne_basic_test_script} to use ${NGINX_IMAGE}"

report_test_failure() {
	if [ "$test_started" != true ]; then
		return
	fi

	trap - ERR
	set +e

	echo "Test failed; collecting cluster diagnostics"
	kubectl get nodes -o wide || true
	kubectl get pods -n kube-flannel -l "$flannel_selector" -o wide || true
	kubectl describe pods -n kube-flannel -l "$flannel_selector" || true

	exit 1
}

trap report_test_failure ERR

test_started=true
expected_flannel_pod_count=$(kubectl get pods -n kube-flannel -l "$flannel_selector" --no-headers 2>/dev/null | wc -l)

if [ "$expected_flannel_pod_count" -eq 0 ]; then
	echo "No flannel pods found in kube-flannel"
	exit 1
fi

kubectl delete pod -n kube-flannel -l "$flannel_selector"

for _ in $(seq 1 24); do
	ready_flannel_pods=$(
		kubectl get pods -n kube-flannel -l "$flannel_selector" \
			-o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.deletionTimestamp}{"\n"}{end}' |
			awk '$2 == "" { print $1 }'
	)

	ready_flannel_pod_count=$(printf '%s\n' "$ready_flannel_pods" | awk 'NF { count++ } END { print count + 0 }')

	if [ "$ready_flannel_pod_count" -eq "$expected_flannel_pod_count" ]; then
		break
	fi

	sleep 5
done

if [ "$ready_flannel_pod_count" -ne "$expected_flannel_pod_count" ]; then
	echo "Timed out waiting for all flannel pods to be recreated in kube-flannel"
	exit 1
fi

kubectl wait --namespace kube-flannel --for=jsonpath='{.status.phase}'=Running pod -l "$flannel_selector" --timeout=120s
kubectl wait --namespace kube-flannel --for=condition=Ready pod -l "$flannel_selector" --timeout=120s

cleanup() {
	status=$?
	trap - EXIT

	if [ -n "$port_forward_pid" ] && kill -0 "$port_forward_pid" 2>/dev/null; then
		kill "$port_forward_pid"
		wait "$port_forward_pid" 2>/dev/null || true
	fi

	rm -rf "$tmpdir"

	if [ "$delete_ocne_cluster" = true ]; then
		ocne cluster delete -C "${HEADLAMP_CLUSTER_NAME}" || status=$?
	fi

	exit "$status"
}

trap cleanup EXIT

sh "$ocne_basic_test_script"

test_started=false
