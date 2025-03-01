# Functions used by other scripts

: ${SCRIPT_DIR:=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )}

: ${CONTROL_NODE_IMAGE:=pbchekin/icl-ccn:0.0.1}
: ${PROXY_IMAGE:=pbchekin/icl-proxy:0.0.1}

PROJECT_ROOT="$( cd $SCRIPT_DIR && cd ../.. && pwd)"

function proxy_container_status() {
  # Returns "running" if container icl-proxy is running, empty string
  docker container inspect --format '{{.State.Status}}' icl-proxy 2>/dev/null || echo ""
}

function get_admin_token()
{
  echo "Kubernetes Dashboard: https://dashboard.${ICL_INGRESS_DOMAIN}"
  echo "Cluster token for admin-user:"
  control_node kubectl -n kubernetes-dashboard create token admin-user
}

function warn_about_proxy_and_variables()
{
  proxy_variables_used=0
  proxy_status="$(proxy_container_status)"
  if [[ $proxy_status != "running" ]]; then

    if [[ -v http_proxy ]]; then
      proxy_variables_used=1
    fi

    if [[ -v https_proxy ]]; then
      proxy_variables_used=1
    fi

    if [[ -v no_proxy ]]; then
      proxy_variables_used=1
    fi

    if [[ $proxy_variables_used -eq 1 ]]; then
      warn "HTTP proxy variables are used, but no transparent proxy started. Consider using --start-proxy."
      warn "Otherwise, some software in this session may not detect proxy settings and may not work."
    fi

  fi
}

# Starts the control code in a ephemeral container.
# Mounts ~/.aws and ~/.kube to the container, if exist.
# The repository is mounted to ~/x1, which can be used to persist data, for example, in ~/x1/workspace
function control_node() {
  local docker_cmd=(
    --rm
    --volume $PROJECT_ROOT:/work/x1
    --user "$(id -u):$(id -g)"
    --env USER
    --workdir /work/x1
  )

  if [[ -f $KUBECONFIG ]]; then
    docker_cmd+=( --volume $KUBECONFIG:/work/.kube/config )
  elif [[ -d ${HOME}/.kube ]]; then
    docker_cmd+=( --volume ${HOME}/.kube:/work/.kube )
  fi

  if [[ -d $HOME/.aws ]]; then
    docker_cmd+=( --volume $HOME/.aws:/work/.aws )
  fi

  if [[ -v PG_CONN_STR ]]; then
    docker_cmd+=( --env PG_CONN_STR )
  fi

  if [[ -v TF_PG_CONN_STR ]]; then
    docker_cmd+=( --env TF_PG_CONN_STR )
  fi

  if [[ -v PGUSER ]]; then
    docker_cmd+=( --env PGUSER )
  fi

  if [[ -v PGSSLMODE ]]; then
    docker_cmd+=( --env PGSSLMODE )
  fi

  if [[ -v PG_SCHEMA_NAME ]]; then
    docker_cmd+=( --env PG_SCHEMA_NAME )
  fi

  if [[ -v PGPASSWORD ]]; then
    docker_cmd+=( --env PGPASSWORD )
  fi

  for aws_var in $(env | grep -E '^AWS_' | cut -f1 -d=); do
    docker_cmd+=( --env $aws_var )
  done

  for x1_var in $(env | grep -E '^X1_'  | cut -f1 -d=); do
    docker_cmd+=( --env $x1_var )
  done

  for icl_var in $(env | grep -E '^ICL_'  | cut -f1 -d=); do
    docker_cmd+=( --env $icl_var )
  done

  if [[ -v GOOGLE_APPLICATION_CREDENTIALS ]]; then
    docker_cmd+=( --env GOOGLE_APPLICATION_CREDENTIALS=/work/.config/gcloud/credentials.json )
    docker_cmd+=( -v $GOOGLE_APPLICATION_CREDENTIALS:/work/.config/gcloud/credentials.json )
  fi
  
  if [[ -d $HOME/.config/gcloud ]]; then
    docker_cmd+=( --volume $HOME/.config/gcloud:/work/.config/gcloud )
  fi

  if [[ -t 0 ]]; then
    docker_cmd+=( --interactive )
  fi

  if [[ -t 1 ]]; then
    docker_cmd+=( --tty )
  fi

  proxy_status="$(proxy_container_status)"
  if [[ $proxy_status == "running" ]]; then
    docker_cmd+=( --network "container:icl-proxy" )
  else
    if [[ $proxy_status ]]; then
      echo "Container icl-proxy exists, but not running"
    fi

    # Only set {http,https,no}_proxy when a sidecar proxy container is not used.
    if [[ -v http_proxy ]]; then
      docker_cmd+=( --env http_proxy )
    fi

    if [[ -v https_proxy ]]; then
      docker_cmd+=( --env https_proxy )
    fi

    if [[ -v no_proxy ]]; then
      docker_cmd+=( --env no_proxy )
    fi

    # TODO: kind requires host network, aws/gcp does not
    docker_cmd+=( --network host )
  fi

  docker_cmd+=( $CONTROL_NODE_IMAGE )
  if (( $# != 0 )); then
    docker_cmd+=( -c "$*" )
  fi

  docker run "${docker_cmd[@]}"
}

function deploy_x1() {
  control_node "\
    cd terraform/icl \
    && terraform init -upgrade -migrate-state -input=false \
    && terraform apply -input=false -auto-approve $(x1_terraform_args)
  "
}

# Delete X1 workloads
function delete_x1() {
  control_node "\
  cd terraform/icl \
  && terraform init -upgrade -migrate-state -input=false \
  && terraform destroy -input=false -auto-approve $(x1_terraform_args) || true"
}

# Delete PersistentVolumes
function delete_pvs() {
  control_node "kubectl delete --all -A --wait=false pvc || true"
}

function start_proxy() {
  echo "Starting proxy container ..."
  docker run --detach --rm --privileged --env http_proxy --name icl-proxy "$PROXY_IMAGE" > /dev/null
}

function stop_proxy() {
  echo "Stopping proxy container ..."
  docker kill icl-proxy &>/dev/null || true
}

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
ENDCOLOR="\e[0m"

function pass() {
  echo -e "${GREEN}[PASS]${ENDCOLOR} $1"
}

function warn() {
  echo -e "${YELLOW}[WARN]${ENDCOLOR} $1"
}

function fail() {
  echo -e "${RED}[FAIL]${ENDCOLOR} $1"
}

function check_args() {
  # Flag to check if any invalid argument is found
  invalid_arg=false

  for arg in "$@"; do
      if [[ $arg == "--console" ]]; then
        break
      fi
      # Check if the argument is not in the allowed list
      if [[ ! " ${allowed[@]} " =~ " $arg " ]]; then
          echo "Invalid argument: $arg"
          invalid_arg=true
      fi
  done
  if [ $invalid_arg == true ]; then
      show_help
      exit 1
  fi
}

function is_installed() {
  local cmd="$1"
  if command -v "$cmd"  &> /dev/null; then
    pass "$cmd installed"
    declare -g "is_${cmd/-/_}_installed=1"
    return 0
  else
    fail "$cmd is not installed"
    return 1
  fi
}
