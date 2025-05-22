#!/bin/bash


create_subscription() {
  local name source channel
  local extras=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--name)
        name="$2"; shift 2
        ;;
      -s|--source)
        source="$2"; shift 2
        ;;
      -c|--channel)
        channel="$2"; shift 2
        ;;
      -e|--extra-args)
        extras+=("$2"); shift 2
        ;;
      --)
        shift; break
        ;;
      -*)
        echo "Unknown option: $1" >&2
        return 1
        ;;
      *)
        echo "Unexpected argument: $1" >&2
        return 1
        ;;
    esac
  done

  if [[ -z $name ]]; then
    echo "Error: --name is required" >&2
    return 1
  fi

  source=${source:-redhat-operators}
  channel=${channel:-stable}

  echo "Creating Subscription resource for '$name'..."

  cat <<EOF | kubectl apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${name}
  namespace: openshift-operators
spec:
  channel: ${channel}
  installPlanApproval: Automatic
  name: ${name}
  source: ${source}
  sourceNamespace: openshift-marketplace
$(for line in "${extras[@]}"; do
    printf '  %s\n' "$line"
done)
EOF
}

install_operators() {
  echo "Installing required operators..."
  
  create_subscription --name "servicemeshoperator"
  create_subscription --name "authorino-operator" --source "community-operators"

  if [[ "$KSERVE_MODE" == "serverless" ]]; then
    create_subscription --name "serverless-operator"
  fi
  
  create_subscription --name "opendatahub-operator" \
      --source "community-operators" \
      --channel fast \
      --extra-args "startingCSV: opendatahub-operator.${ODH_VERSION}"
}

wait_for_crd() {
  local crd="$1"
  local timeout=180
  local interval=1
  local elapsed=0

  echo "Waiting for CRD $crd to be available..."
  while ! kubectl get crd "$crd" &>/dev/null; do
    if [[ $elapsed -ge $timeout ]]; then
      echo "Error: CRD $crd not available after ${timeout}s" >&2
      exit 1
    fi
    sleep $interval
    elapsed=$((elapsed + interval))
  done
  echo "CRD $crd is available"
}



# Remove .metadata.ownerReferences from a given resource
# Usage: hack_remove_owner_ref <kind> <name> <namespace>
hack_remove_owner_ref() {
  local kind="$1"
  local name="$2"
  local namespace="$3"
  if [[ -z "$kind" || -z "$name" || -z "$namespace" ]]; then
    echo "Usage: hack_remove_owner_ref <kind> <name> <namespace>" >&2
    return 1
  fi
  if ! kubectl -n "$namespace" get "$kind" "$name" -o json | jq -e '.metadata.ownerReferences' | grep -q '\['; then
    echo "$kind/$name in namespace $namespace has no ownerReferences, skipping."
    return 0
  fi
  echo "Setting .metadata.ownerReferences to [] for $kind/$name in namespace $namespace..."
  kubectl -n "$namespace" patch "$kind" "$name" --type merge -p '{"metadata":{"ownerReferences":[]}}'
}

