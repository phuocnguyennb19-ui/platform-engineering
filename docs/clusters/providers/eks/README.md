# AWS EKS

Metadata: [`eks-dev`](../../../../environments/dev/kubernetes/cluster/eks-dev.yaml) · [`eks-staging`](../../../../environments/staging/kubernetes/cluster/eks-staging.yaml) ·
[`eks-production`](../../../../environments/prod/kubernetes/cluster/eks-production.yaml). Helm environments `dev` / `staging` /
`prod`; Terraform environments `dev` / `staging` / `production` — never interchangeable.

EKS is the one provider this repository **provisions**, with the existing Terraform. This
page adds nothing to it; it says where things live and how to check them. Commands are
marked **[read]** or **[CHANGES STATE]**. Nothing here was executed while writing it.

## 1. Provision — `terraform/stacks/core`, through CI only

| What | Where it is decided |
|---|---|
| Cluster, version, endpoint access, node groups | `environments/<env>/terraform/core.yaml` → `eks:` (dev: `1.32`, `endpoint_public_access: false`, one SPOT node group `t3.large` 1–3) |
| VPC, subnets, NAT | same file → `vpc:` (`cidr`, `az_count`, `single_nat_gateway`); module `terraform/modules/vpc` |
| Access to the Kubernetes API | `eks.access_entries` in `core.yaml` (module default `authentication_mode = API_AND_CONFIG_MAP`) |
| Add-ons | module default `coredns`, `kube-proxy`, `vpc-cni`, `aws-ebs-csi-driver`; IRSA roles `<eksClusterName>-irsa-<addon>` from `eks.addon_roles` |
| AWS account guard, backend | `environments/<env>/terraform/{environment,backend}.yaml` |

The pipeline (`ci/terraform/platform.yml`) runs `check-inputs` · `config` · `validate` →
`plan:core` (saved plan, role `TF_PLAN_ROLE_ARN` via GitLab OIDC) → `apply:core`
(**[CHANGES STATE]**, `when: manual` on the default branch, role `TF_APPLY_ROLE_ARN`,
`DESTROY_GUARD`). Credentials are short-lived OIDC sessions; none are stored in the repo.
Terraform is never applied from a laptop or from this directory. `make stacks-validate` is
the offline check.

After `core`, the platform layer (`kubernetes/releases/`) is synced per environment by
`helmfile:sync:<env>` (`ci/k8s/helmfile.yml`) and apps by Argo CD
(`kubernetes/argocd/bootstrap/`). Those, not this directory, install ingress-nginx, the Prometheus
Operator, Kong/Gateway API and the rest.

## 2. Connect — kubeconfig context

- **Network:** dev sets `endpoint_public_access: false`. The API answers only from inside the
  VPC (VPN, bastion, a runner there). From elsewhere preflight check 3 fails with a timeout —
  that is the configuration, not an outage.
- **Identity:** your IAM principal needs an access entry (or `aws-auth` mapping) with a
  read policy. Report a missing one; never widen a policy to make a check pass.
- **Kubeconfig:** `aws eks update-kubeconfig --name platform-<env>-eks --region <aws-region>
  --alias <alias> --kubeconfig "$HOME/.kube/eks-<env>.yaml"` writes **[CHANGES STATE: your
  local file only]** a separate kubeconfig with an alias, so the cluster ARN (which embeds
  the account ID) never reaches commands, logs or this repo. Put the alias into
  `<env>/cluster/eks-<dev|staging|production>.yaml` locally or pass it with `CONTEXT=`.
- The entry runs `aws eks get-token` on every `kubectl` call, so preflight calls AWS STS
  for a token. Your AWS credentials come from your own profile/SSO, never from this repo.

## 3. Check — preflight

```bash
make k8s-preflight CLUSTER=eks-dev CONTEXT=<eks-dev-context-alias> KUBECONFIG_FILE=$HOME/.kube/eks-dev.yaml   # [read]
```

Staging and production work the same way and stay read-only; running them is still your
decision, and the identity should have read access only.

## 4. Read-only verification by hand

```bash
CTX=<eks-dev-context-alias>; CLUSTER=platform-dev-eks; REGION=<aws-region>
```

| What | Command [read] |
|---|---|
| Cluster status, version, endpoint, auth mode | `aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --query 'cluster.{status:status,version:version,public:resourcesVpcConfig.endpointPublicAccess,private:resourcesVpcConfig.endpointPrivateAccess,auth:accessConfig.authenticationMode}'` |
| Access entries | `aws eks list-access-entries --cluster-name "$CLUSTER" --region "$REGION"` |
| Policies of one entry | `aws eks list-associated-access-policies --cluster-name "$CLUSTER" --region "$REGION" --principal-arn <principal-arn>` |
| Node groups | `aws eks list-nodegroups --cluster-name "$CLUSTER" --region "$REGION"` |
| Add-ons | `aws eks list-addons --cluster-name "$CLUSTER" --region "$REGION"` · `aws eks describe-addon --cluster-name "$CLUSTER" --region "$REGION" --addon-name aws-ebs-csi-driver` |
| Who am I to Kubernetes | `kubectl --context="$CTX" auth whoami` |
| VPC CNI | `kubectl --context="$CTX" get daemonset aws-node -n kube-system` |
| `aws-auth` (legacy) | `kubectl --context="$CTX" get configmap aws-auth -n kube-system -o yaml` — holds role ARNs with the account ID; read, never paste into the repo |
| Load balancers | `kubectl --context="$CTX" get svc -A --field-selector spec.type=LoadBalancer` (ingress-nginx's NLB); AWS LBC only if `kubectl --context="$CTX" api-resources --api-group=elbv2.k8s.aws` lists anything |
| EBS / EFS CSI | `kubectl --context="$CTX" get csidrivers` · `kubectl --context="$CTX" get storageclass` — no StorageClass is defined in this repository; whether a default exists must be checked |
| IRSA on a controller | `kubectl --context="$CTX" get serviceaccount -n <namespace> <name> -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}'` |
