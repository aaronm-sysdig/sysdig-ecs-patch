# sysdig-ecs-patch

Field tool that instruments a plain ECS Fargate task definition (JSON) with the
Sysdig Workload Agent. It does what the CloudFormation serverless-patcher does,
but for pipelines that register task definition JSON directly (GitHub Actions,
Azure DevOps, CodeBuild, scripts).

> **Proof of concept, provided as is.** This is a personal field tool written to
> prove out a task. It is **not an official Sysdig product**, is **not supported
> by Sysdig**, and comes with **no warranty of any kind** (see the Apache-2.0
> [LICENSE](LICENSE)). Review it, test it in a non-production account first, and
> use it at your own risk. Behaviour was verified only as described under
> [Testing](#testing).

Single bash script. Requirements: `bash`, `jq`, plus the tool for the lookup
method you pick.

## Try it in two minutes (no AWS account, no registry)

You need only `bash` and `jq`.

    ./test-offline.sh                      # 51 checks + a golden-file test, fully offline

    # Patch the sample task definition yourself. The sample image's config is not
    # reachable offline, so give the tool both fields explicitly (no lookup needed):
    jq '.containerDefinitions[0].entryPoint=["/bin/event-generator"]' \
        examples/event-generator/vanilla.json > /tmp/in.json
    ./sysdig-ecs-patch -i /tmp/in.json --dry-run -m none \
        --collector ingest.example.sysdig.com \
        --access-key-secret-arn arn:aws:secretsmanager:us-east-1:111122223333:secret:sysdig-key-AbCdEf

With a public image and any ARN-shaped string you can also run the real suite
against a real registry, with skopeo and no AWS credentials:

    ./test.sh public.ecr.aws/docker/library/nginx:alpine \
        arn:aws:secretsmanager:us-east-1:111122223333:secret:dummy-AbCdEf skopeo

## Why it exists

ECS follows Docker semantics. If a container sets only `entryPoint` in the task
definition, the image `CMD` is discarded, and Sysdig's `instrument` launcher
panics with `no command or entry point specified`. So when the customer's images
carry their own ENTRYPOINT/CMD and the task definition sets neither, the values
must be read from the image and written into the task definition as:

    entryPoint: ["/opt/draios/bin/instrument"]
    command:    [<original entrypoint>, <original command>]

(the same shape the serverless-patcher recipe produces), plus the sidecar,
`volumesFrom`, `SYS_PTRACE`, `SYSDIG_SIDECAR`/`SYSDIG_PRIORITY` and `pidMode: task`.

## Usage

    sysdig-ecs-patch -i taskdef.json -o taskdef-sysdig.json -m skopeo \
        --collector ingest.au1.sysdig.com \
        --access-key-secret-arn arn:aws:secretsmanager:REGION:ACCOUNT:secret:NAME

    # edit in place, keep a backup
    sysdig-ecs-patch -i taskdef.json -m dockerinspect --backup ...

    # see what each container runs today, change nothing
    sysdig-ecs-patch -i taskdef.json --list-original -m ecr

Run with `--help` for all options. Wrong or missing options print an error
followed by the help text and exit with status 2.

## Lookup methods

| Method | Needs | Auth |
|---|---|---|
| `skopeo` | skopeo | ECR login done automatically (needs aws cli) |
| `crane` | crane | log in beforehand (`crane auth login`, or docker login) |
| `regctl` | regctl | log in beforehand (`regctl registry login`) |
| `ecr` | aws cli + curl | AWS credentials; private ECR images only |
| `dockerinspect` | docker | docker login; pulls the image if not local |
| `buildx` | docker buildx | docker login |
| `none` | nothing | never looks anything up; every container must set both fields |
| `auto` (default) | | first available of skopeo, crane, regctl, ecr, dockerinspect |

Multi-arch: the architecture comes from the task definition `runtimePlatform`
(ARM64 or default amd64), or `--arch`.

IAM for the `ecr` method: `ecr:GetAuthorizationToken` is not needed, but
`ecr:BatchGetImage` and `ecr:GetDownloadUrlForLayer` are.

## What happens for each kind of container

The tool works out what the container would run today (task definition values win,
anything unset comes from the image), then wraps it: `entryPoint: [instrument]`,
`command: [<original entrypoint> + <original command>]`. The image used for the
examples has `ENTRYPOINT [/docker-entrypoint.sh]` and `CMD [nginx -g 'daemon off;']`.

| Container in the task definition | Treated as | Image looked up? |
|---|---|---|
| neither `entryPoint` nor `command` | image ENTRYPOINT + image CMD | yes |
| `entryPoint` only | that `entryPoint` alone (ECS drops the image CMD) | no |
| `command` only | image ENTRYPOINT + that `command` | yes |
| both | `entryPoint` + `command` as written | no |
| already starts with `instrument` | left untouched | no |

All of these are covered by `./test-offline.sh`.

## Mirroring the agent image, priority and sidecar resources

- `--workload-agent-image IMAGE` (alias `--agent-image`) sets the sidecar image,
  so customers can point at an internal mirror instead of `quay.io/sysdig/workload-agent`.
  Env default: `SYSDIG_WORKLOAD_AGENT_IMAGE`.
- `--priority availability|security` sets `SYSDIG_PRIORITY` on the sidecar and the
  workload containers. Security mode also marks the sidecar essential.
- `--sidecar-cpu`, `--sidecar-memory`, `--sidecar-memory-reservation` give the
  sidecar its own CPU/memory. By default it has none and shares the task's
  allocation with the customer's containers.
- `--sidecar-essential true|false|auto` (default auto: true only for `security`,
  as in Sysdig's CloudFormation template). An essential sidecar that exits stops
  the whole task.
- `--workload-env NAME=VALUE` and `--sidecar-env NAME=VALUE` (repeatable) add env
  vars to every instrumented container / the sidecar, for example
  `SYSDIG_LOGGING=info` or `SYSDIG_EXTRA_CONF='tags: team:payments'`. They win over
  the built-in values of the same name. Only applied to containers being
  instrumented in this run (already-instrumented containers are left untouched).
- `--log-group`, `--log-region`, `--log-stream-prefix` send the sidecar's logs to
  CloudWatch (prefix defaults to `sysdig`).
- `--dry-run` / `-n` prints a diff and writes nothing (no file, no backup).
- Notes and warnings (stderr, never fatal): the sidecar has no log configuration
  (no `--log-group`, so the agent's logs are not captured); the sidecar has no
  resources of its own; security mode with no sidecar resources; container
  CPU/memory adding up to more than the task-level size.

## pidMode

The tool sets `pidMode: task`, as Sysdig's docs require for sidecar mode. All
containers in the task then share one PID namespace: processes are visible
across containers and a container's main process is no longer PID 1. Fargate
only supports `task` for `pidMode`, so there is nothing to conflict with.

## Behaviour to know

- Values set in the task definition win; anything unset comes from the image.
  If `entryPoint` is set but `command` is not, the image CMD is dropped.
- Already-instrumented containers are left alone, so re-running is safe.
- Fails (non-zero) rather than guessing: image not readable, no entrypoint or
  command anywhere, image name not a plain string (e.g. `${REPO}:tag`).
- The access key is referenced as a secret ARN, never written in plaintext.
- Accepts the output of `aws ecs describe-task-definition` and strips the
  read-only fields so the result can go straight to `register-task-definition`.
- Not handled: `dependsOn` ordering, digest pinning, `repositoryCredentials`,
  embedded (no-sidecar) mode.

## Pipeline examples

- [examples/github-actions.yml](examples/github-actions.yml)
- [examples/azure-pipelines.yml](examples/azure-pipelines.yml)

Both follow the same order: build and push the image, substitute the real image
name into the task definition, run this tool, then register/deploy. They use
`-m ecr`, which needs only the AWS CLI, curl and jq, all preinstalled on the
hosted Ubuntu runners. Status: the YAML parses and the shell steps (image
substitution, then the tool, then a register-ready file) were run locally, but
the workflows have **not** been run in a real GitHub or Azure DevOps pipeline,
and the action/task input names are from their documentation, not from a
working pipeline.

## Scope decisions and known limitations

Decided with the field team; revisit only if a customer needs it.

- **Sidecar mode only.** Embedded mode (agent baked into the image, no sidecar) is
  not supported: customers are not expected to go that way, and it was never
  confirmed working on Fargate in testing (launch chain correct, workload output
  never seen).
- **No orchestrator mode.** `SYSDIG_ORCHESTRATOR` / `SYSDIG_ORCHESTRATOR_PORT` setups
  are retired, so `--collector` is always required.
- **Not handled by the tool** (left as the pipeline's job):
  - `dependsOn` ordering between containers is not touched.
  - `repositoryCredentials` in a container definition are not used for the image
    lookup. The environment running the tool must already be logged in to the
    registry (ECR access via the runner's AWS role is enough for `skopeo`, `ecr`).
  - **Pipeline ordering:** the tool needs the real image name, so run it after any
    step that substitutes the image into the task definition (for example the
    GitHub Actions render-task-definition step, or an Azure DevOps token
    replacement), and before the register/deploy step.
  - Image names that are still placeholders (`${REPO}:tag`) are rejected.
- **Already-instrumented containers are skipped, not updated.** A container whose
  `entryPoint` already starts with `/opt/draios/bin/instrument` is left exactly as
  it is, and an existing `SysdigInstrumentation` sidecar is kept as is. Changing the
  collector, priority or env on a task that is already instrumented therefore means
  starting again from the vanilla definition. (Containers that merely have their own
  `entryPoint` and/or `command` are NOT skipped; see the table above.)
- **Lookups are not retried.** A registry blip fails the run, which is the safe
  outcome. Re-run the step.
- **Credentials:** the tool assumes the runner already has registry and AWS access.
  With `skopeo` and ECR the short-lived ECR password is passed on the skopeo command
  line for the duration of the call.
- **Agent version:** the default is `quay.io/sysdig/workload-agent:latest`. Customers
  should pass `--workload-agent-image` with an explicit version (or their internal mirror).
- **Not measured:** the agent's real CPU/memory use. The headroom warning is advisory.
- **jq:** developed and tested with jq 1.8.2 (and skopeo 1.24.0). Other versions are untested; anything older than jq 1.6 is unlikely to work.

## Testing

| Script | Needs | What it does |
|---|---|---|
| `./test-offline.sh` | bash, jq | Stub skopeo with canned image configs. Golden test (`examples/event-generator/vanilla.json` must produce `patched.json`), the full 51-check suite, and a CMD-only image case. |
| `./test.sh IMAGE SECRET_ARN [METHOD]` | the tool for METHOD | The same 51 checks against a real image. IMAGE needs an ENTRYPOINT or CMD. SECRET_ARN can be any ARN-shaped string. |
| `./linux-test.sh` | Docker | Runs `test.sh` inside an Ubuntu container (installs jq, skopeo, curl, AWS CLI v2). Needs AWS credentials and an ECR image. |

Results so far (51/51 each unless noted):

| Environment | jq | Result |
|---|---|---|
| macOS, bash 5.3 | 1.8.2 | `test.sh`, all six lookup methods (skopeo, crane, regctl, ecr, dockerinspect, buildx) |
| macOS | 1.8.2 | `test.sh` against a public image with a dummy ARN (skopeo, no AWS credentials) |
| Ubuntu 24.04, 22.04 (aarch64) | 1.7, 1.6 | `test-offline.sh`; `test.sh` with skopeo and ecr |
| Ubuntu 24.04, x86_64 (emulated) | 1.7 | skopeo passes; ecr 48/49 on the first run (one check got no output), 30/30 clean on a repeat. Unexplained; likely a transient lookup failure under emulation. The tool fails closed (non-zero exit, no output). |

On AWS Fargate, the event-generator example (`examples/event-generator/`) was run both
as the vanilla task definition and as the tool's patched output: workload HEALTHY and
`pdig` wrapping the original command in both. Not yet run in a real GitHub Actions or
Azure DevOps pipeline.

## Worked example

`examples/event-generator/` holds a real round trip, with identifiers anonymised:

| File | What it is |
|---|---|
| `original.json` | A task definition instrumented by Sysdig's own tooling |
| `vanilla.json` | The same task with all Sysdig instrumentation removed |
| `patched.json` | What this tool produces from `vanilla.json` (reproduced by `test-offline.sh`) |
| `original-vs-patched.diff` | Normalised diff: only the command path (`/bin` vs `/usr/bin`, the image's real entrypoint) and an extra `SYSDIG_PRIORITY` env var on the workload (the docs say to set it) differ |
