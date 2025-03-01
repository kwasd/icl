#!/usr/bin/env bash

# Deploys ICL cluster using kind, see https://kind.sigs.k8s.io/.
# Loads environment variables from .x1/environment file in the current directory, if exists.

set -e

if [[ -f .x1/environment ]]; then
  source .x1/environment
fi

# Default values that can be overriden by corresponding environment variables
: ${KIND_VERSION:="v0.20.0"}
: ${CLUSTER_NAME:="x1"}
: ${X1_EXTERNALDNS_ENABLED:="false"}
: ${CONTROL_NODE_IMAGE:=pbchekin/ccn:0.0.1}
: ${KUBECONFIG:="$HOME/.kube/config"}

export ICL_INGRESS_DOMAIN="localtest.me"
export ICL_RAY_ENDPOINT="localtest.me:10001"
export KUBECONFIG

# https://stackoverflow.com/questions/59895/getting-the-source-directory-of-a-bash-script-from-within
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

source "$SCRIPT_DIR/functions.sh"

# Install tools, such as kind, to ~/bin/
# TODO: also support ~/.local/bin
export PATH="$HOME/bin:$PATH"

function install_kind() {
  if ! is_installed curl; then
    exit 1
  fi
  mkdir -p "$HOME/bin"
  curl -sSL -o "$HOME/bin/kind" "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
  chmod a+x "$HOME/bin/kind"
}

if ! is_installed docker; then
  echo "See https://docs.docker.com/engine/install/"
  exit 1
fi

if ! is_installed kind; then
  echo "See https://kind.sigs.k8s.io/docs/user/quick-start#installation"
  echo "Will attempt to install kind to $HOME/bin"
  install_kind
  if ! is_installed kind; then
    exit 1
  fi
else
  kind_version="$(kind --version)"
  if [[ "$kind_version" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    actual_kind_version="${BASH_REMATCH[1]}"
    if [[ "$KIND_VERSION" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
      desired_kind_version="${BASH_REMATCH[1]}"
      if [[ $actual_kind_version != $desired_kind_version ]]; then
        # TODO: check if actual kind version is newer than desired
        warn "Kind version: $actual_kind_version, required: $desired_kind_version, will attempt to install kind to $HOME/bin"
        install_kind
      else
        pass "Kind version: $actual_kind_version"
      fi
    fi
  else
    fail "Failed to parse kind version: $kind_version"
    exit 1
  fi
fi

# TODO: make ports 80 and 443 configurable on host
function create_kind_cluster() {
  kind_config="\
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    image: kindest/node:v1.28.0
    # This works only for one node, see https://kind.sigs.k8s.io/docs/user/ingress/#ingress-nginx
    # With multiple nodes, a more granular control is needed where nginx pod is running.
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
      # Map Ray client port 10001 to the container port (see nodePort configuration for Ray).
      # Since it is a default Ray port you may need to change it if you have Ray running on the host.
      - containerPort: 30009
        hostPort: 10001
        protocol: TCP
      # Map clusterNodePort 32001 to the same port on host.
      # This port is used to forward SSH to JupyterHub session for the first user. If you are
      # planning to enable SSH for more than one user add more ports (32002 for the second user, and
      # so on).
      - containerPort: 32001
        hostPort: 32001
        protocol: TCP
"
  if [[ -v dockerhub_proxy ]]; then
    pass "DockerHub proxy: ${dockerhub_proxy}"
    kind_config="\
$kind_config
containerdConfigPatches:
  - |-
    [plugins.\"io.containerd.grpc.v1.cri\".registry]
    [plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors]
    [plugins.\"io.containerd.grpc.v1.cri\".registry.mirrors.\"docker.io\"]
    endpoint = [\"${dockerhub_proxy}\"]
    [plugins.\"io.containerd.grpc.v1.cri\".registry.configs.\"${dockerhub_proxy}\".tls]
      insecure_skip_verify = true
"
  fi
  kind create cluster --name $CLUSTER_NAME --config=- <<< "$kind_config"
}

# execute command on kind cluster node
function cluster_node() {
  local docker_cmd=( )

  if [[ -t 0 ]]; then
    docker_cmd+=( --interactive )
  fi
  if [[ -t 1 ]]; then
    docker_cmd+=( --tty )
  fi

  docker_cmd+=( "$CLUSTER_NAME-control-plane" )

  if (( $# != 0 )); then
    docker_cmd+=( /bin/bash -c "$@" )
  fi

  docker exec "${docker_cmd[@]}"
}


function pull_images() {
  xargs -P4 -n1 docker pull -q < "$PROJECT_ROOT/scripts/etc/kind/images.txt"
}

function load_images() {
  xargs -P4 -n1 kind --name $CLUSTER_NAME load docker-image < "$PROJECT_ROOT/scripts/etc/kind/images.txt"
}

function with_proxy() {
  local proxy_url=""
  if [[ -v https_proxy ]]; then
    pass "Using https_proxy: $https_proxy"
    proxy_url="$https_proxy"
  elif [[ -v http_proxy ]]; then
    pass "Using http_proxy: $http_proxy"
    proxy_url="$http_proxy"
  else
    fail "http_proxy or https_proxy must be set"
    exit 1
  fi

  if [[ $proxy_url =~ (https?:\/\/)?([^:]+):([^:]+) ]]; then
    proxy_host="${BASH_REMATCH[2]}"
    proxy_port="${BASH_REMATCH[3]}"
    pass "proxy_host: $proxy_host, proxy_port: $proxy_port"
  else
    fail "Unable to parse proxy URL $proxy_url"
  fi

  docker cp "$PROJECT_ROOT/scripts/etc/kind/redsocks.sh" "$CLUSTER_NAME-control-plane:/redsocks.sh" > /dev/null
  cluster_node "/bin/bash /redsocks.sh $proxy_host $proxy_port"
}

function with_no_proxy() {
  docker cp "$PROJECT_ROOT/scripts/etc/kind/redsocks.sh" "$CLUSTER_NAME-control-plane:/redsocks.sh" > /dev/null
  cluster_node "/bin/bash /redsocks.sh"
}

# Update CoreDNS configuration file to resolve external endpoints in cluster correctly
function with_corefile() {
  CONTROl_PLANE_IP=$(docker inspect --format '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CLUSTER_NAME-control-plane")
  pass "Cluster IP: $CONTROl_PLANE_IP"
  control_node "python -m scripts.kubernetes.coredns $CONTROl_PLANE_IP $ICL_INGRESS_DOMAIN"
}

if [[ " $@ " =~ " --help " ]]; then
  cat <<EOF
Usage: $(basename $0) [option]

Options:
  --help              Show this help
  --console           Start control node console
  --check             Run a quick check for Docker and network connectivity
  --list-images       List images in the existing $CLUSTER_NAME cluster to kind/images.txt
  --pull-images       Pull images listed in kind/images.txt
  --load-images       Load images listed in kind/images.txt to the existing $CLUSTER_NAME cluster
  --with-images       Create a cluster and load images (requires '--pull-images' first)
  --with-clearml      Deploy a cluster with ClearML
  --with-dask         Deploy a cluster with Dask
  --with-cert-manager Deploy a cluster with cert-manager
  --with-proxy        Enable HTTP/HTTPS proxy for the existing cluster (uses https_proxy or http_proxy)
  --with-no-proxy     Disable HTTP/HTTPS proxy for the existing cluster
  --delete            Delete cluster $CLUSTER_NAME
EOF
  exit 0
fi

if [[ " $@ " =~ " --console " ]]; then
  shift
  _rest_args="$@"
  cmd="bash"
  if [[ -n "$_rest_args" ]]; then
    cmd="$_rest_args"
  fi
  control_node "$cmd"
  exit $?
fi

if [[ " $@ " =~ " --check " ]]; then
  control_node "curl https://ipinfo.io/"
  exit 0
fi

if [[ " $@ " =~ " --list-images " ]]; then
  kubectl get pods --all-namespaces -o json | jq -r '.items[].spec.containers[].image' | sort | uniq | tee "$PROJECT_ROOT/scripts/etc/kind/images.txt"
  exit 0
fi

if [[ " $@ " =~ " --pull-images " ]]; then
  pull_images
  exit 0
fi

if [[ " $@ " =~ " --load-images " ]]; then
  load_images
  exit 0
fi

if [[ " $@ " =~ " --delete " ]]; then
  kind delete cluster --name $CLUSTER_NAME
  exit 0
fi

if [[ " $@ " =~ " --with-proxy " ]]; then
  with_proxy
  exit 0
fi

if [[ " $@ " =~ " --with-no-proxy " ]]; then
  with_no_proxy
  exit 0
fi

if [[ " $@ " =~ " --with-corefile " ]]; then
  with_corefile
  exit 0
fi

if kind get clusters | grep -qE "^${CLUSTER_NAME}\$" &> /dev/null; then
  pass "Cluster $CLUSTER_NAME is up"
else
  pass "Cluster $CLUSTER_NAME is not up, will attempt to create a new cluster"
  create_kind_cluster
  if [[ " $@ " =~ " --with-images " ]]; then
    load_images
  fi
  if [[ -v http_proxy || -v https_proxy ]]; then
    with_proxy
  fi
fi

terraform_extra_args=(
  -var local_path_enabled=false         # Kind cluster has local-path-provisioner, another provisioner is not required
  -var default_storage_class="standard" # Kind cluster has local-path-provisioner, it defines "standard" StorageClass
  -var prometheus_enabled=false         # Disable prometheus stack to make footprint smaller
  -var ingress_domain="$ICL_INGRESS_DOMAIN"
  -var externaldns_enabled="$X1_EXTERNALDNS_ENABLED"
)

if [[ " $@ " =~ " --with-clearml " ]]; then
  terraform_extra_args+=( -var clearml_enabled=true )
fi

if [[ " $@ " =~ " --with-dask " ]]; then
  terraform_extra_args+=( -var dask_enabled=true )
fi

if [[ " $@ " =~ " --with-cert-manager " ]]; then
  terraform_extra_args+=( -var cert_manager_enabled=true )
fi

with_corefile
control_node "terraform -chdir=terraform/icl init -upgrade -input=false"
control_node "terraform -chdir=terraform/icl apply -input=false -auto-approve ${terraform_extra_args[*]}"

echo
get_admin_token
echo

echo "To delete the cluster run '$0 --delete'"
