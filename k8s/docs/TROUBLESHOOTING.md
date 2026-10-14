# Kubernetes Troubleshooting Log

A log of K8s issues we hit and how we fixed them. Each entry follows this format:

```
### <short title>
- Scope:      cluster | node | pod | tool:<name>
- Issue:      the observed symptom
- Root cause: the actual root cause (verified with evidence, not guessed)
- Solution:   how to fix it (with commands)
```

> Rule: pick **Scope** by the tier where the ROOT cause lives, not where the
> symptom shows up. E.g. a pod `ImagePullBackOff` whose root cause is node
> networking → Scope = node/cluster.

Table of contents:
- [cluster — Container can't pull images (Docker Desktop proxy + VPN)](#cluster--container-cant-pull-images)
- [node — Broken in-cluster DNS from a wrong kubelet `--cluster-dns`](#node--broken-in-cluster-dns-from-a-wrong-kubelet---cluster-dns)
- [tool:argocd — redis CreateContainerConfigError + server panic](#toolargocd--redis-createcontainerconfigerror--server-panic)
- [pod — wrong `kubectl describe` syntax](#pod--wrong-kubectl-describe-syntax)
- [tool:argocd — Stale ReplicaSet stuck after a chart version change](#toolargocd--stale-replicaset-stuck-after-a-chart-version-change)

---

### cluster — Container can't pull images

- **Scope:** cluster (Docker Desktop / node egress networking)
- **Issue:**
  - All pods `ImagePullBackOff` / `ErrImagePull`.
  - Events: `Failed to pull image ".../...": ... Client.Timeout exceeded while
    awaiting headers` or `context deadline exceeded` (timeout — NOT a wrong
    tag/401).
  - `curl https://quay.io/v2/` from the macOS host **works (401)** but from
    inside the node it **times out `000`**.
- **Root cause:**
  - Docker Desktop is configured with an internal proxy `http.docker.internal:3128`
    (=`192.168.65.1:3128`) that is **dead**; `docker pull` on the host also fails:
    `proxyconnect tcp: dial tcp 192.168.65.1:3128: i/o timeout`.
  - minikube uses the **docker driver** → the node is a container inside Docker
    Desktop → its egress goes through that same broken proxy.
  - The host has a **VPN** active (multiple `utun*` interfaces) → blocks the
    proxy's upstream.
- **Solution:**
  ```bash
  # 1. Confirm the root cause is the proxy, not the registry:
  docker info | grep -i proxy                     # shows http.docker.internal:3128
  minikube ssh -- 'curl -sI --max-time 8 https://quay.io/v2/'   # timeout 000

  # 2. Restart Docker Desktop so it re-reads the network/VPN config:
  osascript -e 'quit app "Docker"'; open -a Docker
  #    wait for the daemon: until docker info; do sleep 3; done
  #    docker driver → the node stops too, bring it back:
  minikube start

  # 3. Test egress:
  docker pull busybox:latest                       # exit 0 = OK

  # 4. Pods are pullPolicy=IfNotPresent, so just trigger a re-pull:
  kubectl -n <ns> delete pod -l <selector>
  ```
- **Prevention:** if you must use a VPN → Docker Desktop → Settings → Resources →
  Proxies: fix/disable the manual proxy; or **mirror images through Harbor** so
  you don't depend on quay.io/ghcr when the VPN blocks them.

---

### node — Broken in-cluster DNS from a wrong kubelet `--cluster-dns`

- **Scope:** node (kubelet)
- **Issue:**
  - Pods run but logs are full of: `dial tcp: lookup <svc> on 8.8.8.8:53: no such host`.
  - In-cluster Services (e.g. `argocd-redis`) don't resolve; DNS-dependent apps
    crash/loop.
  - Inside a pod: `/etc/resolv.conf` → `nameserver 8.8.8.8` (should be the CoreDNS
    ClusterIP, e.g. `10.96.0.10`).
- **Root cause:**
  - kubelet gets the **flag `--cluster-dns=8.8.8.8`** (set via
    `minikube --extra-config=kubelet.cluster-dns=8.8.8.8` and persisted in the profile).
  - The command-line flag **overrides** `clusterDNS` in `/var/lib/kubelet/config.yaml`
    → even though the config file has `10.96.0.10`, kubelet hands `8.8.8.8` to pods.
  - `8.8.8.8` is a public resolver that knows nothing about in-cluster names → `no such host`.
- **Solution:**
  ```bash
  # 1. Find the value kubelet ACTUALLY uses (flag > config.yaml):
  minikube ssh -- "cat /proc/\$(pgrep -x kubelet)/cmdline | tr '\0' '\n' | grep cluster-dns"
  minikube ssh -- 'sudo systemctl cat kubelet | grep -n cluster-dns'   # source: 10-kubeadm.conf
  kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}'  # correct IP, e.g. 10.96.0.10

  # 2. Fix the flag in the systemd drop-in + restart kubelet:
  minikube ssh -- '
    for f in $(sudo grep -rl "cluster-dns=8.8.8.8" /etc/systemd /var/lib/kubelet /etc/kubernetes 2>/dev/null); do
      sudo sed -i "s/cluster-dns=8.8.8.8/cluster-dns=10.96.0.10/g" "$f"
    done
    sudo systemctl daemon-reload && sudo systemctl restart kubelet'

  # 3. Fix the profile so a future start doesn't reintroduce it:
  minikube start --extra-config=kubelet.cluster-dns=10.96.0.10
  #    (or minikube delete && minikube start to drop the override → use the default)

  # 4. resolv.conf is set at pod CREATION → recreate pods to pick up the new DNS:
  kubectl rollout restart deploy,statefulset,daemonset -A

  # 5. Verify from a fresh pod:
  kubectl -n <ns> exec <pod> -- sh -c 'grep nameserver /etc/resolv.conf; getent hosts <svc>'
  ```
- **Note:** this affects the **WHOLE cluster** (every pod), not just the app that
  reported the error. Restarting a container in an old pod does NOT change
  resolv.conf — you must recreate the pod.

---

### tool:argocd — redis CreateContainerConfigError + server panic

- **Scope:** tool:argocd (Helm values)
- **Issue:**
  - Pod `argocd-redis` `CreateContainerConfigError`; describe:
    `Error: secret "argocd-redis" not found`.
  - `argocd-server` `CrashLoopBackOff` with `fatal error: sync: unlock of
    unlocked mutex` (goroutine dump in `session.loadRevokedTokens` + redis
    healthcheck).
- **Root cause:**
  - The values had `redisSecretInit.enabled: false` (the secret-init job was
    disabled to avoid its ImagePullBackOff while the network was broken).
  - → The `argocd-redis` Secret (key `auth`) is never created → redis won't start;
    the server loses redis at startup → **panic** (a known argocd v2 bug).
- **Solution:**
  ```bash
  # Option A (fast, supported by the chart when redisSecretInit=false): create the secret manually
  kubectl -n infra create secret generic argocd-redis \
    --from-literal=auth="$(openssl rand -base64 24)"
  kubectl -n infra rollout restart deploy/argocd-redis deploy/argocd-server

  # Option B (proper GitOps, once egress works): re-enable the init job
  #   platform/argocd/values.yaml.gotmpl:  redisSecretInit.enabled: true
  helmfile -e <env> -l name=argocd sync     # needs SOPS_AGE_KEY_FILE
  ```
- **Note:** `fatal error: sync: unlock of unlocked mutex` is only a **consequence**
  of losing redis — always read the log line RIGHT BEFORE the panic (here
  `lookup argocd-redis ... no such host`) to find the root cause; don't get lost
  in the goroutine dump.

---

### pod — wrong `kubectl describe` syntax

- **Scope:** pod (diagnostic operation)
- **Issue:**
  - `error: the server doesn't have a resource type "argocd-server-xxxx"`.
- **Root cause:**
  - Running `kubectl describe <pod-name>` without the resource type → kubectl
    reads the pod name as the **kind**.
- **Solution:**
  ```bash
  kubectl describe pod -n <ns> <pod-name>
  kubectl describe pod -n <ns> -l <selector>        # by label
  # quickly see the pull/crash reason:
  kubectl describe pod -n <ns> <pod> | grep -A6 Events:
  ```

---

### tool:argocd — Stale ReplicaSet stuck after a chart version change

- **Scope:** tool:argocd (rollout)
- **Issue:**
  - Two ReplicaSets with different image versions coexist (e.g. `argocd:v3.4.5`
    and `v2.14.1`); pods doubled; rollout never completes.
  - Some pods use the **wrong** image host `ecr-public.aws.com/...` (should be
    `public.ecr.aws/...`).
- **Root cause:**
  - The chart version was changed (10.x→7.8.0) while pods couldn't pull → the new
    RS was created but never became Ready → the Deployment **never scaled the old
    RS to 0** (stuck rollout).
  - The wrong image host is only in the old RS (chart 10.x), **not committed** in the repo.
- **Solution:**
  ```bash
  # After fixing the root cause (egress/DNS/secret), force convergence to the current spec:
  kubectl -n infra rollout restart deploy,statefulset -l app.kubernetes.io/part-of=argocd
  # The old RS scales to 0 once the new pods are Ready. Check:
  kubectl -n infra get rs -l app.kubernetes.io/part-of=argocd
  ```
- **Note:** no need to delete old RS/pods manually — once the new pods are Ready
  the Deployment cleans them up.
```
