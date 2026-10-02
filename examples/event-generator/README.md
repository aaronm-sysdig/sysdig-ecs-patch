# event-generator round trip

Identifiers (account ID, secret and role ARNs, log group, family names) are anonymised.

1. `original.json`: a task definition instrumented by Sysdig's own tooling.
2. `vanilla.json`: the same task with all Sysdig bits removed (no sidecar, no entryPoint,
   no volumesFrom, no SYS_PTRACE, no SYSDIG_* env, no pidMode). The image
   (`falcosecurity/event-generator`) supplies `ENTRYPOINT ["/bin/event-generator"]`.
3. `patched.json`: `sysdig-ecs-patch` run over `vanilla.json`:

       sysdig-ecs-patch -i vanilla.json -o patched.json -m skopeo \
         --collector ingest.au1.sysdig.com \
         --access-key-secret-arn arn:aws:secretsmanager:ap-southeast-2:111122223333:secret:sysdig-access-key-AbCdEf \
         --workload-agent-image quay.io/sysdig/workload-agent:6.2.1 --priority availability \
         --sidecar-essential true --sidecar-env SYSDIG_EXTRA_CONF= \
         --workload-env SYSDIG_LOGGING=info \
         --workload-env 'SYSDIG_EXTRA_CONF=tags: cluster:extra-conf-cluster-secret,environment:extra-conf-environment-secret' \
         --log-group SysdigFargate-Workload-Instrumentation-SysdigLogGroup-EXAMPLE \
         --log-region ap-southeast-2 --log-stream-prefix TaskDefinition

   `./test-offline.sh` reproduces this offline and checks the result byte-for-byte (as JSON).
4. `original-vs-patched.diff`: the two remaining differences, both explained in the main README.
