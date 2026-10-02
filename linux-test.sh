#!/usr/bin/env bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq jq curl skopeo unzip ca-certificates diff 2>/dev/null >/dev/null || apt-get install -y -qq jq curl skopeo unzip ca-certificates diffutils >/dev/null
ARCH=$(uname -m)
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o /tmp/awscli.zip
unzip -q /tmp/awscli.zip -d /tmp && /tmp/aws/install >/dev/null
echo "os: $(. /etc/os-release; echo $PRETTY_NAME)  arch: $ARCH  bash: ${BASH_VERSION}  jq: $(jq --version)  skopeo: $(skopeo --version | awk '{print $3}')  aws: $(aws --version | awk '{print $1}')"
cp -r /src /work && cd /work && chmod +x sysdig-ecs-patch test.sh
for m in skopeo ecr; do printf '%-8s ' $m; bash ./test.sh "$IMG" "$SECRET" $m 2>&1 | grep -E 'passed:|FAIL' | tr '\n' ' '; echo; done
