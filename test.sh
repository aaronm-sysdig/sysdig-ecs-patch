#!/usr/bin/env bash
# Smoke tests for sysdig-ecs-patch against a real ECR image.
# Usage: ./test.sh IMAGE SECRET_ARN [METHOD]
#   IMAGE must have both an ENTRYPOINT and a CMD, e.g. ACCOUNT.dkr.ecr.REGION.amazonaws.com/repo:tag
set -uo pipefail
cd "$(dirname "$0")"
IMAGE="${1:?image}"; SECRET="${2:?secret arn}"; M="${3:-auto}"
P=./sysdig-ecs-patch
T=$(mktemp -d)
A=(--collector ingest.example.sysdig.com --access-key-secret-arn "$SECRET" --agent-image quay.io/sysdig/workload-agent:6.3.0)
pass=0; fail=0
ok()   { echo "PASS  $1"; pass=$((pass+1)); }
bad()  { echo "FAIL  $1"; fail=$((fail+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got: $2 expected: $3)"; fi; }

jq -n --arg img "$IMAGE" '{family:"t",cpu:"256",memory:"512",networkMode:"awsvpc",requiresCompatibilities:["FARGATE"],
  containerDefinitions:[{name:"workload",image:$img,essential:true}]}' > "$T/in.json"
ENTRY=$($P -i "$T/in.json" -m "$M" --list-original 2>/dev/null | sed -n 's/.*: \(\[.*\]\)$/\1/p')
echo "image original entrypoint+command: $ENTRY"
EP0=$(jq -r '.[0]' <<<"$ENTRY"); REST=$(jq -c '.[1:]' <<<"$ENTRY")

# 1 basic transform
$P -i "$T/in.json" -o "$T/out.json" -m "$M" "${A[@]}" 2>/dev/null
check "entryPoint is instrument"   "$(jq -c '.containerDefinitions[0].entryPoint' "$T/out.json")" '["/opt/draios/bin/instrument"]'
check "command is original ep+cmd" "$(jq -c '.containerDefinitions[0].command' "$T/out.json")" "$ENTRY"
check "sidecar added"              "$(jq -r '.containerDefinitions[1].name' "$T/out.json")" "SysdigInstrumentation"
check "pidMode task"               "$(jq -r '.pidMode' "$T/out.json")" "task"
check "SYS_PTRACE added"           "$(jq -c '.containerDefinitions[0].linuxParameters.capabilities.add' "$T/out.json")" '["SYS_PTRACE"]'
check "volumesFrom sidecar"        "$(jq -r '.containerDefinitions[0].volumesFrom[0].sourceContainer' "$T/out.json")" "SysdigInstrumentation"

# 2 idempotent
$P -i "$T/out.json" -o "$T/out2.json" -m "$M" "${A[@]}" 2>/dev/null
check "re-run changes nothing" "$(jq -S -c . "$T/out.json")" "$(jq -S -c . "$T/out2.json")"

# 3 in place + backup
cp "$T/in.json" "$T/ip.json"; $P -i "$T/ip.json" -m "$M" --backup "${A[@]}" 2>/dev/null
[ -f "$T/ip.json.bak" ] && ok "backup written" || bad "backup written"
check "in-place edit applied" "$(jq -r '.containerDefinitions[0].entryPoint[0]' "$T/ip.json")" "/opt/draios/bin/instrument"

# 4 entryPoint only: image CMD must be dropped
jq --arg e "$EP0" '.containerDefinitions[0].entryPoint=[$e]' "$T/in.json" > "$T/eponly.json"
check "entryPoint-only drops image CMD" "$($P -i "$T/eponly.json" -m "$M" "${A[@]}" -o - 2>/dev/null | jq -c '.containerDefinitions[0].command')" "[\"$EP0\"]"

# 5 explicit both + method none works without lookup
jq '.containerDefinitions[0]+={entryPoint:["/a"],command:["b"]}' "$T/in.json" > "$T/both.json"
check "explicit both, method none" "$($P -i "$T/both.json" -m none "${A[@]}" -o - 2>/dev/null | jq -c '.containerDefinitions[0].command')" '["/a","b"]'

# 6 method none but lookup needed must fail
$P -i "$T/in.json" -m none "${A[@]}" -o - >/dev/null 2>&1 && bad "method none needing lookup should fail" || ok "method none needing lookup fails"

# 7 wrapper + stdin/stdout
check "describe-task-definition wrapper via stdin" "$(jq '{taskDefinition:.}' "$T/in.json" | $P -i - -m "$M" "${A[@]}" 2>/dev/null | jq -r '.containerDefinitions[1].name')" "SysdigInstrumentation"

# 8 skip
check "--skip leaves container alone" "$($P -i "$T/in.json" -m "$M" --skip workload "${A[@]}" -o - 2>/dev/null | jq -c '.containerDefinitions[0].entryPoint')" "null"

# 9 non-plain image rejected
jq '.containerDefinitions[0].image="${REPO}:tag"' "$T/in.json" > "$T/var.json"
$P -i "$T/var.json" -m "$M" "${A[@]}" -o - >/dev/null 2>&1 && bad "non-plain image should fail" || ok "non-plain image rejected"

# 10 bad usage exits 2 and prints help
$P --nonsense >/dev/null 2>&1; check "bad option exits 2" "$?" "2"
BADOUT=$($P --nonsense 2>&1 || true)
case "$BADOUT" in *ERROR:*Usage:*) ok "bad option shows error then help" ;; *) bad "bad option shows error then help" ;; esac
$P --help >/dev/null 2>&1; check "--help exits 0" "$?" "0"

# 11 arm64 selection
check "arm64 lookup" "$($P -i "$T/in.json" -m "$M" --arch arm64 --list-original 2>/dev/null | grep -c "^  workload")" "1"

# 12 agent image mirror (new name and old alias)
check "--workload-agent-image" "$($P -i "$T/in.json" -m "$M" "${A[@]}" --workload-agent-image mirror.local/wa:1 -o - 2>/dev/null | jq -r '.containerDefinitions[1].image')" "mirror.local/wa:1"
check "--agent-image alias"    "$($P -i "$T/in.json" -m "$M" "${A[@]}" --agent-image mirror.local/wa:2 -o - 2>/dev/null | jq -r '.containerDefinitions[1].image')" "mirror.local/wa:2"

# 13 sidecar resources
check "sidecar cpu/memory set" "$($P -i "$T/in.json" -m "$M" "${A[@]}" --sidecar-cpu 128 --sidecar-memory 256 --sidecar-memory-reservation 128 -o - 2>/dev/null | jq -c '.containerDefinitions[1]|[.cpu,.memory,.memoryReservation]')" "[128,256,128]"
$P -i "$T/in.json" -m "$M" "${A[@]}" --sidecar-memory 100 --sidecar-memory-reservation 200 -o - >/dev/null 2>&1; check "reservation > limit exits 2" "$?" "2"
$P -i "$T/in.json" -m "$M" "${A[@]}" --sidecar-cpu abc -o - >/dev/null 2>&1; check "non-numeric cpu exits 2" "$?" "2"

# 14 warnings (need task-level cpu/memory, which the test input has)
W=$($P -i "$T/in.json" -m "$M" "${A[@]}" -o - 2>&1 >/dev/null)
case "$W" in *"shares the task allocation"*) ok "note: sidecar shares task resources" ;; *) bad "note: sidecar shares task resources" ;; esac
W=$($P -i "$T/in.json" -m "$M" "${A[@]}" --priority security -o - 2>&1 >/dev/null)
case "$W" in *"WARNING: priority is 'security'"*) ok "warning: security mode without sidecar resources" ;; *) bad "warning: security mode without sidecar resources" ;; esac
jq '.containerDefinitions[0].memory=400' "$T/in.json" > "$T/mem.json"
W=$($P -i "$T/mem.json" -m "$M" "${A[@]}" --sidecar-memory 300 -o - 2>&1 >/dev/null)
case "$W" in *"memory limits add up to 700"*) ok "warning: limits exceed task memory" ;; *) bad "warning: limits exceed task memory" ;; esac

# 15 dry run writes nothing, makes no backup, still shows the change
cp "$T/in.json" "$T/dry.json"; BEFORE=$(cksum < "$T/dry.json")
DRY=$($P -i "$T/dry.json" -m "$M" --backup --dry-run "${A[@]}" 2>"$T/dry.err"); DRC=$?
check "dry run exits 0" "$DRC" "0"
check "dry run leaves input untouched" "$(cksum < "$T/dry.json")" "$BEFORE"
[ ! -e "$T/dry.json.bak" ] && ok "dry run makes no backup" || bad "dry run makes no backup"
case "$DRY" in *"+"*"/opt/draios/bin/instrument"*) ok "dry run prints the diff" ;; *) bad "dry run prints the diff" ;; esac
$P -i "$T/in.json" -o "$T/never.json" -m "$M" --dry-run "${A[@]}" >/dev/null 2>&1
[ ! -e "$T/never.json" ] && ok "dry run creates no output file" || bad "dry run creates no output file"
$P -i "$T/in.json" -m "$M" -n >/dev/null 2>&1; check "dry run still validates usage" "$?" "2"

# 16 sidecar essential
check "essential auto, availability -> false" "$($P -i "$T/in.json" -m "$M" "${A[@]}" -o - 2>/dev/null | jq -c '.containerDefinitions[1].essential')" "false"
check "essential auto, security -> true"      "$($P -i "$T/in.json" -m "$M" "${A[@]}" --priority security -o - 2>/dev/null | jq -c '.containerDefinitions[1].essential')" "true"
check "--sidecar-essential true"              "$($P -i "$T/in.json" -m "$M" "${A[@]}" --sidecar-essential true -o - 2>/dev/null | jq -c '.containerDefinitions[1].essential')" "true"
check "--sidecar-essential false + security"  "$($P -i "$T/in.json" -m "$M" "${A[@]}" --priority security --sidecar-essential false -o - 2>/dev/null | jq -c '.containerDefinitions[1].essential')" "false"
$P -i "$T/in.json" -m "$M" "${A[@]}" --sidecar-essential maybe -o - >/dev/null 2>&1; check "bad --sidecar-essential exits 2" "$?" "2"

# 17 extra env vars
OUT=$($P -i "$T/in.json" -m "$M" "${A[@]}" --workload-env SYSDIG_LOGGING=info --workload-env 'SYSDIG_EXTRA_CONF=tags: a:b,c:d=e' --sidecar-env SYSDIG_LOGGING=debug -o - 2>/dev/null)
check "workload env added"       "$(jq -r '.containerDefinitions[0].environment[]|select(.name=="SYSDIG_LOGGING").value' <<<"$OUT")" "info"
check "workload env keeps '=' and spaces" "$(jq -r '.containerDefinitions[0].environment[]|select(.name=="SYSDIG_EXTRA_CONF").value' <<<"$OUT")" "tags: a:b,c:d=e"
check "sidecar env added"        "$(jq -r '.containerDefinitions[1].environment[]|select(.name=="SYSDIG_LOGGING").value' <<<"$OUT")" "debug"
check "sidecar still has collector" "$(jq -r '.containerDefinitions[1].environment[]|select(.name=="SYSDIG_COLLECTOR").value' <<<"$OUT")" "ingest.example.sysdig.com"
OUT=$($P -i "$T/in.json" -m "$M" "${A[@]}" --workload-env SYSDIG_PRIORITY=security -o - 2>/dev/null)
check "user env overrides built-in, no duplicates" "$(jq -c '[.containerDefinitions[0].environment[]|select(.name=="SYSDIG_PRIORITY").value]' <<<"$OUT")" '["security"]'
$P -i "$T/in.json" -m "$M" "${A[@]}" --workload-env NOEQUALS -o - >/dev/null 2>&1; check "env without = exits 2" "$?" "2"
$P -i "$T/in.json" -m "$M" "${A[@]}" --workload-env '1BAD=x' -o - >/dev/null 2>&1; check "bad env name exits 2" "$?" "2"

# 17b multi-line YAML value (proxy config, as used on real sidecars)
ML=$'http_proxy:\n  proxy_host: proxy.example.com\n  proxy_port: 3128\ntags:\n  owner:comsec'
OUT=$($P -i "$T/in.json" -m "$M" "${A[@]}" --sidecar-env "SYSDIG_EXTRA_CONF=$ML" -o - 2>/dev/null)
check "multi-line sidecar env value kept intact" "$(jq -r '.containerDefinitions[1].environment[]|select(.name=="SYSDIG_EXTRA_CONF").value' <<<"$OUT")" "$ML"
OUT=$($P -i "$T/in.json" -m "$M" "${A[@]}" --sidecar-env SYSDIG_EXTRA_CONF= -o - 2>/dev/null)
check "empty env value allowed" "$(jq -c '.containerDefinitions[1].environment[]|select(.name=="SYSDIG_EXTRA_CONF").value' <<<"$OUT")" '""'

# 18 log group and stream prefix
OUT=$($P -i "$T/in.json" -m "$M" "${A[@]}" --log-group /ecs/x --log-region ap-southeast-2 --log-stream-prefix mine -o - 2>/dev/null)
check "log group + prefix" "$(jq -c '.containerDefinitions[1].logConfiguration.options|[.["awslogs-group"],.["awslogs-stream-prefix"]]' <<<"$OUT")" '["/ecs/x","mine"]'
OUT=$($P -i "$T/in.json" -m "$M" "${A[@]}" --log-group /ecs/x --log-region ap-southeast-2 -o - 2>/dev/null)
check "default stream prefix is sysdig" "$(jq -r '.containerDefinitions[1].logConfiguration.options["awslogs-stream-prefix"]' <<<"$OUT")" "sysdig"

echo; echo "passed: $pass  failed: $fail"; rm -rf "$T"; [ "$fail" -eq 0 ]
