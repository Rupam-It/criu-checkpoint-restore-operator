#!/usr/bin/env bats

CHECKPOINT_DIR=${CHECKPOINT_DIR:-/var/lib/kubelet/checkpoints}

function log_and_run() {
  echo "Running: $*" >&2
  "$@"
  status=$?
  echo "Status: $status" >&2
  if [ "$status" -ne 0 ]; then
    echo "Command failed with status $status: $*" >&2
    echo "Output:" >&2
    echo "$output" >&2
  fi
  return $status
}

function setup() {
  TEST_TMPDIR=$(mktemp -d)
}

function teardown() {
  log_and_run sudo rm -rf "${CHECKPOINT_DIR:?}"/*
  rm -rf "$TEST_TMPDIR"
}

function operator_logs() {
  if [ -n "$OPERATOR_LOG_CMD" ]; then
    $OPERATOR_LOG_CMD
  else
    kubectl logs -n checkpoint-restore-operator-system deployment/checkpoint-restore-operator-controller-manager --tail=-1
  fi
}

# --- individual trigger tests ---

@test "interval trigger" {
  log_and_run kubectl apply -f ./test/test_checkpointschedule_pod.yaml
  [ "$status" -eq 0 ]
  log_and_run kubectl wait --for=condition=Ready --timeout=120s pod/schedule-test-pod
  [ "$status" -eq 0 ]
  log_and_run kubectl apply -f ./test/test_trigger_interval.yaml
  [ "$status" -eq 0 ]

  last=""
  for _ in $(seq 1 30); do
    last=$(kubectl get checkpointschedule trigger-interval -o jsonpath='{.status.lastCheckpointTime}')
    [ -n "$last" ] && break
    sleep 3
  done

  log_and_run kubectl delete checkpointschedule trigger-interval --timeout=60s
  log_and_run kubectl delete pod schedule-test-pod --ignore-not-found=true

  echo "lastCheckpointTime: $last" >&2
  [ -n "$last" ]
}

@test "annotation trigger" {
  log_and_run kubectl apply -f ./test/test_checkpointschedule_pod.yaml
  [ "$status" -eq 0 ]
  log_and_run kubectl wait --for=condition=Ready --timeout=120s pod/schedule-test-pod
  [ "$status" -eq 0 ]
  log_and_run kubectl apply -f ./test/test_trigger_annotation.yaml
  [ "$status" -eq 0 ]
  log_and_run kubectl annotate pod schedule-test-pod checkpoint.criu.org/trigger=true --overwrite
  [ "$status" -eq 0 ]

  # The annotation trigger polls every 30s. Wait up to 3 minutes for the first
  # poll to fire. Accept annotation consumed (checkpoint succeeded) or a
  # checkpoint-specific log entry (checkpoint attempted) as proof. Do NOT
  # match "annotation trigger started" — that fires as soon as the schedule
  # is applied, before any pod is polled.
  result=""
  for _ in $(seq 1 36); do
    val=$(kubectl get pod schedule-test-pod -o jsonpath='{.metadata.annotations.checkpoint\.criu\.org/trigger}' 2>/dev/null)
    if [ -z "$val" ]; then
      result="annotation consumed"
      break
    fi
    if operator_logs | grep -q "annotation trigger: checkpoint"; then
      result="annotation trigger checkpoint attempted"
      break
    fi
    sleep 5
  done

  log_and_run kubectl delete checkpointschedule trigger-annotation --timeout=60s
  log_and_run kubectl delete pod schedule-test-pod --ignore-not-found=true

  echo "annotation trigger result: '$result'" >&2
  [ -n "$result" ]
}

@test "resource threshold trigger" {
  log_and_run kubectl apply -f ./test/test_checkpointschedule_resource_pod.yaml
  [ "$status" -eq 0 ]
  log_and_run kubectl wait --for=condition=Ready --timeout=120s pod/resource-test-pod
  [ "$status" -eq 0 ]
  log_and_run kubectl apply -f ./test/test_checkpointschedule_resource.yaml
  [ "$status" -eq 0 ]

  found=""
  for _ in $(seq 1 60); do
    if operator_logs | grep -q "resource trigger: threshold exceeded"; then
      found="yes"
      break
    fi
    sleep 5
  done

  log_and_run kubectl delete -f ./test/test_checkpointschedule_resource.yaml
  log_and_run kubectl delete -f ./test/test_checkpointschedule_resource_pod.yaml

  [ -n "$found" ]
}

@test "kubernetes events trigger (NodeDrain)" {
  log_and_run kubectl apply -f ./test/test_checkpointschedule_pod.yaml
  [ "$status" -eq 0 ]
  log_and_run kubectl wait --for=condition=Ready --timeout=120s pod/schedule-test-pod
  [ "$status" -eq 0 ]
  log_and_run kubectl apply -f ./test/test_checkpointschedule_events.yaml
  [ "$status" -eq 0 ]

  node=$(kubectl get pod schedule-test-pod -o jsonpath='{.spec.nodeName}')
  log_and_run kubectl cordon "$node"
  [ "$status" -eq 0 ]

  found=""
  for _ in $(seq 1 12); do
    if operator_logs | grep -q "event trigger: node drain detected"; then
      found="yes"
      break
    fi
    sleep 5
  done

  log_and_run kubectl uncordon "$node"
  log_and_run kubectl delete -f ./test/test_checkpointschedule_events.yaml
  log_and_run kubectl delete -f ./test/test_checkpointschedule_pod.yaml

  [ -n "$found" ]
}

# --- all four triggers at once ---

@test "all four triggers combined" {
  log_and_run kubectl apply -f ./test/test_trigger_all_pod.yaml
  [ "$status" -eq 0 ]
  log_and_run kubectl wait --for=condition=Ready --timeout=120s pod/trigger-all-pod
  [ "$status" -eq 0 ]

  # record the log position before applying the schedule so we only inspect
  # entries produced by this test and avoid false positives from earlier runs
  log_offset=$(operator_logs | wc -l)

  log_and_run kubectl apply -f ./test/test_trigger_all.yaml
  [ "$status" -eq 0 ]

  # kick the annotation trigger right away
  log_and_run kubectl annotate pod trigger-all-pod checkpoint.criu.org/trigger=true --overwrite
  [ "$status" -eq 0 ]

  # kick the events trigger (NodeDrain)
  node=$(kubectl get pod trigger-all-pod -o jsonpath='{.spec.nodeName}')
  log_and_run kubectl cordon "$node"
  [ "$status" -eq 0 ]

  # interval and resource threshold fire on their own within the poll window
  interval_ok="" annotation_ok="" resource_ok="" event_ok=""

  for _ in $(seq 1 48); do
    new_logs=$(operator_logs | tail -n +"$((log_offset + 1))")

    if [ -z "$interval_ok" ]; then
      ts=$(kubectl get checkpointschedule trigger-all -o jsonpath='{.status.lastCheckpointTime}' 2>/dev/null)
      [ -n "$ts" ] && interval_ok="yes"
    fi
    [ -z "$annotation_ok" ] && echo "$new_logs" | grep -q "annotation trigger"           && annotation_ok="yes"
    [ -z "$resource_ok"   ] && echo "$new_logs" | grep -q "resource trigger: threshold exceeded" && resource_ok="yes"
    [ -z "$event_ok"      ] && echo "$new_logs" | grep -q "event trigger: node drain detected"   && event_ok="yes"

    [ -n "$interval_ok" ] && [ -n "$annotation_ok" ] && [ -n "$resource_ok" ] && [ -n "$event_ok" ] && break
    sleep 5
  done

  log_and_run kubectl uncordon "$node"
  log_and_run kubectl delete checkpointschedule trigger-all --timeout=60s
  log_and_run kubectl delete pod trigger-all-pod --ignore-not-found=true

  echo "interval=$interval_ok annotation=$annotation_ok resource=$resource_ok event=$event_ok" >&2
  [ -n "$interval_ok" ]
  [ -n "$annotation_ok" ]
  [ -n "$resource_ok"   ]
  [ -n "$event_ok"      ]
}
