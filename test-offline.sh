#!/usr/bin/env bash
# Offline tests: needs only bash and jq. No AWS account, registry, network or skopeo.
#
# A stub `skopeo` that returns canned image configs is put first on PATH, so the real
# tool runs its normal `-m skopeo` code path. Then:
#   1. golden test: examples/event-generator/vanilla.json must produce patched.json
#   2. the full ./test.sh suite runs against a fake image that has ENTRYPOINT and CMD
set -uo pipefail
cd "$(dirname "$0")"
command -v jq >/dev/null || { echo "jq is required"; exit 2; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/skopeo" <<'STUB'
#!/usr/bin/env bash
# stub skopeo: `skopeo inspect --config ... docker://IMAGE` -> canned image config
for a in "$@"; do last="$a"; done
img="${last#docker://}"
case "$img" in
  falcosecurity/event-generator:*) cfg='{"Entrypoint":["/bin/event-generator"]}' ;;
  registry.example.com/app:*)      cfg='{"Entrypoint":["/docker-entrypoint.sh"],"Cmd":["nginx","-g","daemon off;"]}' ;;
  registry.example.com/cmd-only:*) cfg='{"Cmd":["/app/start.sh"]}' ;;
  *) echo "stub skopeo: no canned config for $img" >&2; exit 1 ;;
esac
jq -n --argjson c "$cfg" '{architecture:"amd64", os:"linux", config:$c}'
STUB
chmod +x "$T/bin/skopeo"
export PATH="$T/bin:$PATH"

SECRET=arn:aws:secretsmanager:ap-southeast-2:111122223333:secret:sysdig-access-key-AbCdEf
fail=0

echo "== 1. golden test (examples/event-generator)"
./sysdig-ecs-patch -i examples/event-generator/vanilla.json -o "$T/out.json" -m skopeo \
  --collector ingest.au1.sysdig.com --access-key-secret-arn "$SECRET" \
  --workload-agent-image quay.io/sysdig/workload-agent:6.2.1 --priority availability \
  --sidecar-essential true --sidecar-env SYSDIG_EXTRA_CONF= \
  --workload-env SYSDIG_LOGGING=info \
  --workload-env 'SYSDIG_EXTRA_CONF=tags: cluster:extra-conf-cluster-secret,environment:extra-conf-environment-secret' \
  --log-group SysdigFargate-Workload-Instrumentation-SysdigLogGroup-EXAMPLE \
  --log-region ap-southeast-2 --log-stream-prefix TaskDefinition 2>/dev/null
if diff <(jq -S . "$T/out.json") <(jq -S . examples/event-generator/patched.json) >/dev/null; then
  echo "PASS  vanilla.json -> patched.json matches"
else
  echo "FAIL  output differs from examples/event-generator/patched.json:"
  diff -u <(jq -S . examples/event-generator/patched.json) <(jq -S . "$T/out.json") | head -30
  fail=1
fi

echo "== 2. full suite against a stubbed image (ENTRYPOINT + CMD)"
bash ./test.sh registry.example.com/app:1.0 "$SECRET" skopeo | grep -E 'FAIL|passed:' || true
bash ./test.sh registry.example.com/app:1.0 "$SECRET" skopeo | grep -q 'failed: 0' || fail=1

echo "== 3. CMD-only image (no ENTRYPOINT)"
printf '{"family":"t","containerDefinitions":[{"name":"w","image":"registry.example.com/cmd-only:1"}]}' > "$T/c.json"
got=$(./sysdig-ecs-patch -i "$T/c.json" -m skopeo --collector c --access-key-secret-arn "$SECRET" -o - 2>/dev/null | jq -c '.containerDefinitions[0]|[.entryPoint,.command]')
if [ "$got" = '[["/opt/draios/bin/instrument"],["/app/start.sh"]]' ]; then echo "PASS  CMD-only image"; else echo "FAIL  CMD-only image: $got"; fail=1; fi

echo "== 4. every entryPoint/command shape (image: ENTRYPOINT [/docker-entrypoint.sh] CMD [nginx -g 'daemon off;'])"
I='"/opt/draios/bin/instrument"'
shape() {  # label  container-fragment  expected "[entryPoint,command]"
  jq -n --argjson f "$2" '{family:"t",containerDefinitions:[({name:"app",image:"registry.example.com/app:1.0"} + $f)]}' > "$T/s.json"
  got=$(./sysdig-ecs-patch -i "$T/s.json" -m skopeo --collector c --access-key-secret-arn "$SECRET" -o - 2>/dev/null | jq -c '.containerDefinitions[0]|[.entryPoint,.command]')
  if [ "$got" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1"; echo "      got:      $got"; echo "      expected: $3"; fail=1; fi
}
shape "neither set (image supplies both)"        '{}' \
  "[[$I],[\"/docker-entrypoint.sh\",\"nginx\",\"-g\",\"daemon off;\"]]"
shape "entryPoint only (image CMD is dropped)"    '{"entryPoint":["/custom.sh"]}' \
  "[[$I],[\"/custom.sh\"]]"
shape "command only (image ENTRYPOINT kept)"      '{"command":["serve","--port","80"]}' \
  "[[$I],[\"/docker-entrypoint.sh\",\"serve\",\"--port\",\"80\"]]"
shape "both set"                                  '{"entryPoint":["/custom.sh"],"command":["a","b"]}' \
  "[[$I],[\"/custom.sh\",\"a\",\"b\"]]"
shape "multi-word entryPoint, no command"         '{"entryPoint":["/bin/sh","-c","exec nginx"]}' \
  "[[$I],[\"/bin/sh\",\"-c\",\"exec nginx\"]]"
shape "already instrumented, patcher shape: untouched" \
  '{"entryPoint":["/opt/draios/bin/instrument"],"command":["/docker-entrypoint.sh","nginx"]}' \
  "[[$I],[\"/docker-entrypoint.sh\",\"nginx\"]]"
shape "already instrumented, manual shape: untouched" \
  '{"entryPoint":["/opt/draios/bin/instrument","/docker-entrypoint.sh"],"command":["nginx"]}' \
  "[[$I,\"/docker-entrypoint.sh\"],[\"nginx\"]]"

echo "== 5. entryPoint set means no registry lookup is needed"
jq -n '{family:"t",containerDefinitions:[{name:"app",image:"unreachable.example.invalid/${REPO}:tag",entryPoint:["/custom.sh"],command:["a"]},{name:"b",image:"unreachable.example.invalid/x:1",entryPoint:["/only.sh"]}]}' > "$T/n.json"
got=$(./sysdig-ecs-patch -i "$T/n.json" -m skopeo --collector c --access-key-secret-arn "$SECRET" -o - 2>/dev/null | jq -c '[.containerDefinitions[0:2][]|.command]')
if [ "$got" = '[["/custom.sh","a"],["/only.sh"]]' ]; then echo "PASS  entryPoint (+/- command) works with an unreachable image and a placeholder name"; else echo "FAIL  no-lookup case: $got"; fail=1; fi

echo; [ "$fail" -eq 0 ] && echo "ALL OFFLINE TESTS PASSED" || { echo "SOME OFFLINE TESTS FAILED"; exit 1; }
