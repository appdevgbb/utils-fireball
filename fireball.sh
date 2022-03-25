#!/usr/bin/env bash
# shfmt -i 2 -ci -w
set -eo pipefail

###############################################################################
_FLAMEGRAPH="flamegraph"
_PROFILER=ebpf-profiler
_REGISTRY=https://registry.hub.docker.com/v2/repositories/dcasati/ebpf-tools/tags
_VIEWER="firefox -new-window"
###############################################################################

# exit and remove the profiler pod
trap __clear_exit INT
__clear_exit() {
  echo -e "\n\naborting!"
  do_delete_profiler
  exit
}

__usage="
    -p	pod to be profiled
    -c	the name of the container inside of the pod.
    -t	time to run the profiler in seconds. Defaults to 30 seconds.
    -i	image name of the profiler.
    -x	action to be executed. See available actions below.
    -o  options. See available options below.

Possible actions are:
    list-images		  list available images for the profiler.

Possible options are:
    try-opening     try to open the file. On Linux this uses xdg-open. On MacOS: open. 
    copy-perf-data  copy the raw perf_events data to the local machine.
"
usage() {
  echo "usage: ${0##*/} [options]"
  echo "${__usage/[[:space:]]/}"
  exit 1
}

do_create_profiler_pod() {
  sed \
    's@{{PROFILER_IMAGE}}@'"$_PROFILER_IMAGE"'@ 
      s@{{TARGET_POD}}@'"$_TARGET_POD"'@
      s@{{SAMPLING_PERIOD}}@'"$_SAMPLING_PERIOD"'@
      s@{{TARGET_CONTAINER}}@'"$_TARGET_CONTAINER"'@
      s@{{AKS_NODE}}@'"$_AKS_NODE"'@' ebpf-profiler.yaml |
    kubectl apply -f -
}

do_copy_flamegraph() {
  # copy the flamegraph svc from the profiler pod to our local host
  kubectl cp "${_PROFILER}":/"${_TARGET_CONTAINER}".svg ./"${_FLAMEGRAPH}".svg 2>/dev/null
  echo "copied flamegraph to $PWD/${_FLAMEGRAPH}.svg"
}

do_delete_profiler() {
  # remove the profiler
  echo "removing the $_PROFILER pod"
  kubectl delete po $_PROFILER
}

# lists the available profiler docker images
do_list_images() {
  echo -e "\nAvailable images for the profiler"
  echo "----------------"
  curl -s "${_REGISTRY}" | jq -r '."results"[]["name"]'
  exit 0
}

# wait for profiler to complete
wait_loop() {
  kubectl wait --for=condition=Ready po/"$_PROFILER"
  completed_flag=""
  echo -n "profiling ${_TARGET_POD} ..."
  while [[ "$completed_flag" != "profiling complete" ]]; do
    completed_flag=$(kubectl logs --tail=1 $_PROFILER)
    echo -n "."
    sleep 5
  done
}

# functions defining our options
# try opening the downloaded flamegraph svg file. If $VIEWER is specicified use that, otherwise
# use xdg-open on Linux or open on Darwin
option_try_opening() {
  local _os=$(uname)
  local _default_viewer

  # check on what OS we are running first
  if [[ ${_os} == "Linux" ]]; then
    _default_viewer=xdg-open
  elif [[ ${_os} == "Darwin" ]]; then
    _default_viewer=open
  else
    echo "Can't find a viewer to open the ${_FLAMEGRAPH}.svg on this platform"
  fi

  # if VIEWER is specified, use that instead of the _default_viewer
  if [[ ${_VIEWER+x} ]]; then
    ${_VIEWER} "$PWD"/${_FLAMEGRAPH}.svg &
  elif [ "$(which ${_default_viewer})" ]; then
    ${_default_viewer} "$PWD"/${_FLAMEGRAPH}.svg &
  else
    echo "_default_viewer not found. Can't open ${_FLAMEGRAPH}.svg"
    exit 0
  fi

  echo "Opening ${_FLAMEGRAPH}.svg"
}

# copy raw perf data to the local host
option_copy_perf_data() {
  kubectl cp "${_PROFILER}":/"${_TARGET_CONTAINER}".perf ./"${_TARGET_CONTAINER}".perf 2>/dev/null
  echo "copied perf data into $PWD/${_TARGET_CONTAINER}.perf"
}

exec_case() {
  local _exec_opt=$1

  case ${_exec_opt} in
    list-images) do_list_images ;;
    *) usage ;;
  esac
  unset _exec_opt
}

options_case() {
  local _opt=$1

  case ${_opt} in
    try-opening) option_try_opening ;;
    copy-perf-data) option_copy_perf_data ;;
    *) usage ;;
  esac
  unset _opt
}

main() {
  while getopts "c:f:i:o:p:t:x:" opt; do
    case $opt in
      c) _TARGET_CONTAINER="${OPTARG}" ;;
      f) _FLAMEGRAPH="${OPTARG}" ;;
      i) _PROFILER_IMAGE="${OPTARG}" ;;
      o)
        opt_flag=true
        OPT="${OPTARG}"
        ;;
      p) _TARGET_POD="${OPTARG}" ;;
      t) _SAMPLING_PERIOD="${OPTARG}" ;;
      x)
        exec_flag=true
        EXEC_OPT="${OPTARG}"
        ;;
      *) usage ;;
    esac
  done
  shift $(($OPTIND - 1))

  if [ $OPTIND = 1 ]; then
    usage
    exit 0
  fi

  # -x actions will follow here
  if [[ "${exec_flag}" == "true" ]]; then
    exec_case "${EXEC_OPT}"
  fi

  # the single condition we need for this to work: the name of the pod we want to profile
  if [ -z "${_TARGET_POD+x}" ]; then
    echo "please specify a pod that you'd like to profile."
    usage
  fi

  # if an image for the profiler wasnt specified we will try to get one based on the node kernel version
  if [ -z "${_PROFILER_IMAGE+x}" ]; then
    _AKS_NODE=$(kubectl get po "${_TARGET_POD}" -o jsonpath='{.spec.nodeName}')
    _PROFILER_IMAGE=$(kubectl get no "${_AKS_NODE}" -o jsonpath="{.status.nodeInfo.kernelVersion}")
    _PROFILER_IMAGE=dcasati/ebpf-tools:${_PROFILER_IMAGE}
    echo -e "\nusing $_PROFILER_IMAGE as an image."
  else
    _AKS_NODE=$(kubectl get po "${_TARGET_POD}" -o jsonpath='{.spec.nodeName}')
    echo -e "\nusing $_PROFILER_IMAGE as an image."
  fi

  # if no time was specified for the sampling we will default to 30 seconds
  if [ -z "${_SAMPLING_PERIOD+x}" ]; then
    _SAMPLING_PERIOD=30
  fi

  # by default we will execute against the first container we see in the pod. The user can chage that behaviour
  # using the -c flag
  if [ -z "${_TARGET_CONTAINER+x}" ]; then
    local SPEC_CONTAINERS

    SPEC_CONTAINERS=$(kubectl get po "${_TARGET_POD}" -o jsonpath="{.spec.containers[*].name}")

    if [ "${#SPEC_CONTAINERS[@]}" -gt 1 ]; then
      _TARGET_CONTAINER=${SPEC_CONTAINERS[0]}
      echo "Found the following containers on this pod:" "${SPEC_CONTAINERS[@]}"
      echo "profiling the first container we found:" "${_TARGET_CONTAINER}"
      echo "You can change this behaviour by specifying a container image with the -c flag."

    fi
    _TARGET_CONTAINER=${SPEC_CONTAINERS[0]}
  fi

  do_create_profiler_pod
  wait_loop
  do_copy_flamegraph

  # -o options will follow here
  if [[ "${opt_flag}" == "true" ]]; then
    options_case "${OPT}"
  fi

  do_delete_profiler
}

main "$@"
exit 0
