$ErrorActionPreference = "Continue"
$env:Path = "$env:LOCALAPPDATA\kind;C:\Program Files\Docker\Docker\resources\bin;" + $env:Path
Set-Location (Split-Path $PSScriptRoot -Parent)

Write-Output "registry"
$prev = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$running = docker inspect -f "{{.State.Running}}" kind-registry 2>$null
if ($running -ne "true") {
    docker rm -f kind-registry 2>$null | Out-Null
    docker run -d --restart=always -p "127.0.0.1:5001:5000" --network bridge --name kind-registry registry:3
    if ($LASTEXITCODE -ne 0) { throw "registry did not start" }
}
$ErrorActionPreference = $prev

Write-Output "kind cluster"
kind delete cluster --name campus
kind create cluster --config kind-config.yaml
if ($LASTEXITCODE -ne 0) { throw "kind create failed" }
kubectl config use-context kind-campus | Out-Null

$nodes = kind get nodes --name campus
foreach ($node in $nodes) {
    docker exec $node mkdir -p /etc/containerd/certs.d/localhost:5001
    if ($LASTEXITCODE -ne 0) { throw "registry dir on $node failed" }
    docker cp (Join-Path $PSScriptRoot "hosts.toml") "${node}:/etc/containerd/certs.d/localhost:5001/hosts.toml"
    if ($LASTEXITCODE -ne 0) { throw "hosts.toml on $node failed" }
}

$linked = docker inspect -f "{{json .NetworkSettings.Networks.kind}}" kind-registry 2>$null
if ($linked -eq "null" -or [string]::IsNullOrWhiteSpace($linked)) {
    docker network connect kind kind-registry
    if ($LASTEXITCODE -ne 0) { throw "could not connect registry to kind" }
}

Write-Output "calico"
$calicoUrls = @(
    "https://raw.githubusercontent.com/projectcalico/calico/v3.30.2/manifests/calico.yaml",
    "https://raw.githubusercontent.com/projectcalico/calico/v3.29.3/manifests/calico.yaml"
)
$calicoOk = $false
foreach ($url in $calicoUrls) {
    kubectl apply -f $url
    if ($LASTEXITCODE -eq 0) { $calicoOk = $true; break }
}
if (-not $calicoOk) { throw "calico apply failed" }
kubectl -n kube-system rollout status daemonset/calico-node --timeout=240s
if ($LASTEXITCODE -ne 0) { throw "calico-node is not ready" }
kubectl wait --for=condition=Ready nodes --all --timeout=240s
if ($LASTEXITCODE -ne 0) { throw "nodes are not ready" }

Write-Output "ingress-nginx"
$ingressUrls = @(
    "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.13.2/deploy/static/provider/kind/deploy.yaml",
    "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/kind/deploy.yaml"
)
$ingressOk = $false
foreach ($url in $ingressUrls) {
    kubectl apply -f $url
    if ($LASTEXITCODE -eq 0) { $ingressOk = $true; break }
}
if (-not $ingressOk) { throw "ingress apply failed" }
kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=240s
if ($LASTEXITCODE -ne 0) { throw "ingress controller is not ready" }

Write-Output "metrics-server"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
if ($LASTEXITCODE -ne 0) { throw "metrics-server apply failed" }
$patchFile = Join-Path $env:TEMP "metrics-server-patch.json"
[System.IO.File]::WriteAllText($patchFile, '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]')
kubectl -n kube-system patch deployment metrics-server --type=json --patch-file $patchFile
if ($LASTEXITCODE -ne 0) { throw "metrics-server patch failed" }
kubectl -n kube-system rollout status deployment/metrics-server --timeout=240s
if ($LASTEXITCODE -ne 0) { throw "metrics-server is not ready" }

Write-Output "cluster campus is ready"
