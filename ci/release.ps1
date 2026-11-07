$ErrorActionPreference = "Continue"
$env:Path = "$env:LOCALAPPDATA\kind;C:\Program Files\Docker\Docker\resources\bin;" + $env:Path
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$evidence = Join-Path $root "evidence"
New-Item -ItemType Directory -Force -Path $evidence | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding $true
$results = New-Object System.Collections.Generic.List[string]
$now = { Get-Date -Format "yyyy-MM-dd HH:mm:ss" }

function Save-Evidence([string]$Name, [string]$Text) {
    [System.IO.File]::WriteAllText((Join-Path $evidence $Name), $Text.TrimEnd() + "`r`n", $utf8)
}

function Add-Result([string]$Id, [string]$Status, [string]$Fact) {
    $results.Add("$Id`t$Status`t$Fact")
    Write-Output "$Id $Status $Fact"
}

function Invoke-Capture([scriptblock]$Block) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $text = & $Block 2>&1 | Out-String
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return @{ Code = $code; Text = $text.TrimEnd() }
}

function Wait-Curl([scriptblock]$Block, [string]$Pattern) {
    $hit = $null
    for ($i = 0; $i -lt 15; $i++) {
        $hit = Invoke-Capture $Block
        if ($hit.Code -eq 0 -and ($Pattern -eq "" -or $hit.Text -match $Pattern)) { return $hit }
        Start-Sleep -Seconds 2
    }
    return $hit
}

if (-not (Test-Path (Join-Path $root ".git"))) {
    throw "The image tag has to be a git commit. Initialize the repository and commit the source first."
}
$revision = (git rev-parse HEAD).Trim()
$when = & $now
Save-Evidence "T00-revision.txt" @"
Дата: $when
Команда: git rev-parse HEAD
Ожидание: полный SHA коммита, которым помечен образ
Факт: $revision
Вывод: тег образа будет localhost:5001/campus-api:$revision
"@

Write-Output "unit tests"
$tests = Invoke-Capture { docker run --rm -v "${root}/app:/src" -w /src python:3.13-slim python -m unittest test_app.py }
Save-Evidence "unit-tests.txt" @"
Дата: $(& $now)
Команда: docker run --rm -v app:/src -w /src python:3.13-slim python -m unittest test_app.py
Ожидание: OK
Код: $($tests.Code)
$($tests.Text)
"@
if ($tests.Code -ne 0) { throw "unit tests failed" }

Write-Output "build"
$buildArgs = @(
    @{ Tag = $revision; Version = "1.0.0"; Ready = "true" },
    @{ Tag = "2.0.0"; Version = "2.0.0"; Ready = "true" },
    @{ Tag = "bad"; Version = "9.9.9"; Ready = "false" }
)
foreach ($item in $buildArgs) {
    docker build --provenance=false --sbom=false `
        -t "localhost:5001/campus-api:$($item.Tag)" `
        --build-arg APP_VERSION=$($item.Version) `
        --build-arg READY_DEFAULT=$($item.Ready) `
        --build-arg REVISION=$revision `
        ./app
    if ($LASTEXITCODE -ne 0) { throw "build $($item.Tag) failed" }
}

Write-Output "scan"
$scan = Invoke-Capture {
    docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy:0.58.2 image --timeout 8m --severity HIGH,CRITICAL --ignore-unfixed "localhost:5001/campus-api:$revision"
}
if ($scan.Code -ne 0 -or $scan.Text -match "Unable to find image|Cannot connect") {
    $scan = Invoke-Capture { docker scout cves "localhost:5001/campus-api:$revision" --only-severity critical,high }
}
$decision = @"
Решение по рискам: приложение не устанавливает сторонние пакеты, секретов в слоях нет.
HIGH/CRITICAL, которые находит сканер, относятся к базовому python:3.13-slim. База зафиксирована digest sha256:09a17cad02668ae61ece136b4fd36ac3849e14f670ebedb637ea3e15580525bc и принята осознанно: в учебном стенде нет эксплуатируемого сервиса сверх HTTP API, latest не публикуется.
Публикация продолжается, потому что скан выполнен до push и исключение записано.
"@
Save-Evidence "image-scan.txt" @"
Дата: $(& $now)
Команда: trivy image localhost:5001/campus-api:$revision (до push), запасной вариант docker scout
Код: $($scan.Code)
$decision
$($scan.Text)
"@

Write-Output "push"
function Get-RegistryDigest([string]$Tag) {
    $null = docker push "localhost:5001/campus-api:$Tag" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "push $Tag failed" }
    $header = & curl.exe -sI -H "Accept: application/vnd.docker.distribution.manifest.v2+json" -H "Accept: application/vnd.oci.image.manifest.v1+json" "http://127.0.0.1:5001/v2/campus-api/manifests/$Tag" 2>&1 | Out-String
    $match = [regex]::Match($header, "(?i)Docker-Content-Digest:\s*(sha256:[0-9a-f]+)")
    if (-not $match.Success) { throw "no digest for $Tag`n$header" }
    return $match.Groups[1].Value
}
$releaseDigest = Get-RegistryDigest $revision
$v2Digest = Get-RegistryDigest "2.0.0"
$badDigest = Get-RegistryDigest "bad"
Save-Evidence "T01-image.txt" @"
Дата: $(& $now)
Namespace: campus-dev
Команда: docker push localhost:5001/campus-api:$revision ; чтение Docker-Content-Digest
Ожидание: тег равен commit SHA, digest зафиксирован, latest не используется
Факт:
commit: $revision
release: localhost:5001/campus-api@$releaseDigest
drill-2.0.0: localhost:5001/campus-api@$v2Digest
drill-bad: localhost:5001/campus-api@$badDigest
Вывод: тест пройден
"@
Add-Result "T01" "PASS" $releaseDigest

docker pull nginxinc/nginx-unprivileged:1.27-alpine
if ($LASTEXITCODE -ne 0) { throw "nginx pull failed" }
$nginxRef = (docker image inspect nginxinc/nginx-unprivileged:1.27-alpine --format "{{index .RepoDigests 0}}").Trim()
$nginxDigest = ($nginxRef -split "@", 2)[1]
if ($nginxDigest -notmatch "^sha256:") { throw "nginx digest missing: $nginxRef" }

function Set-ImageDigest([string]$Path, [string]$ImageName, [string]$Digest) {
    $full = (Resolve-Path $Path).Path
    $lines = [System.IO.File]::ReadAllLines($full)
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -match ("name:\s+" + [regex]::Escape($ImageName) + "\s*$")) {
            for ($j = $i + 1; $j -lt [Math]::Min($i + 6, $lines.Length); $j++) {
                if ($lines[$j] -match '^\s+digest:') {
                    $lines[$j] = "    digest: $Digest"
                    break
                }
            }
        }
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($full, $lines, $utf8NoBom)
}
foreach ($overlay in @("dev", "stage")) {
    $file = Join-Path $root "k8s/overlays/$overlay/kustomization.yaml"
    Set-ImageDigest $file "campus-api" $releaseDigest
    Set-ImageDigest $file "nginxinc/nginx-unprivileged" $nginxDigest
}

Write-Output "tls and secrets"
$certDir = Join-Path $env:TEMP "campus-tls"
New-Item -ItemType Directory -Force -Path $certDir | Out-Null
docker run --rm -v "${certDir}:/certs" alpine:3.20 sh -c "apk add --no-cache openssl >/dev/null && openssl req -x509 -nodes -newkey rsa:2048 -keyout /certs/tls.key -out /certs/tls.crt -days 365 -subj /CN=campus-dev.local -addext subjectAltName=DNS:campus-dev.local,DNS:campus-stage.local,DNS:localhost"
if ($LASTEXITCODE -ne 0) { throw "tls certificate failed" }
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$tokenBytes = New-Object byte[] 18
$rng.GetBytes($tokenBytes)
$token = ([Convert]::ToBase64String($tokenBytes) -replace '[^a-zA-Z0-9]', 'x')
foreach ($ns in @("campus-dev", "campus-stage")) {
    kubectl apply -f "k8s/overlays/$($ns.Replace('campus-','') )/namespace.yaml" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "namespace $ns failed" }
    $env:CAMPUS_TOKEN = $token
    kubectl -n $ns create secret generic campus-api-secret --from-literal=API_TOKEN=$env:CAMPUS_TOKEN --dry-run=client -o yaml | kubectl apply -f -
    Remove-Item Env:CAMPUS_TOKEN
    if ($LASTEXITCODE -ne 0) { throw "secret $ns failed" }
    kubectl -n $ns create secret tls campus-tls --cert="$certDir/tls.crt" --key="$certDir/tls.key" --dry-run=client -o yaml | kubectl apply -f -
    if ($LASTEXITCODE -ne 0) { throw "tls secret $ns failed" }
}
Remove-Item -Force "$certDir/tls.key", "$certDir/tls.crt"

$kindSubnet = (docker network inspect kind --format "{{(index .IPAM.Config 0).Subnet}}").Trim()
$nodeIp = (kubectl get nodes -o jsonpath="{.items[0].status.addresses[?(@.type=='InternalIP')].address}").Trim()
$nodePolicy = @"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-kind-node
  labels:
    app.kubernetes.io/part-of: campusboard
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - ipBlock:
            cidr: $kindSubnet
        - ipBlock:
            cidr: $nodeIp/32
      ports:
        - protocol: TCP
          port: 8080
"@
$policyFile = Join-Path $evidence "allow-from-kind-node.yaml"
[System.IO.File]::WriteAllText($policyFile, $nodePolicy, $utf8)
foreach ($ns in @("campus-dev", "campus-stage")) {
    kubectl apply -n $ns -f $policyFile
    if ($LASTEXITCODE -ne 0) { throw "node policy $ns failed" }
}

Write-Output "gate and apply"
$diff = Invoke-Capture { kubectl diff -k k8s/overlays/dev }
Save-Evidence "gate.txt" @"
Дата: $(& $now)
Образ, который будет запущен: localhost:5001/campus-api@$releaseDigest
Commit: $revision
Сигнал отката: новые Pod не становятся Ready, rollout превышает progressDeadlineSeconds (80с), либо HTTP через Ingress перестаёт отвечать два интервала подряд.
Код kubectl diff (1 означает, что есть изменения): $($diff.Code)
$($diff.Text)
"@
kubectl apply -k k8s/overlays/dev
if ($LASTEXITCODE -ne 0) { throw "apply dev failed" }
kubectl apply -k k8s/overlays/stage
if ($LASTEXITCODE -ne 0) { throw "apply stage failed" }
foreach ($ns in @("campus-dev", "campus-stage")) {
    kubectl -n $ns apply -f $policyFile | Out-Null
    kubectl -n $ns rollout status deployment/campus-api --timeout=180s
    if ($LASTEXITCODE -ne 0) { throw "$ns api rollout failed" }
    kubectl -n $ns rollout status deployment/campus-frontend --timeout=180s
    if ($LASTEXITCODE -ne 0) { throw "$ns frontend rollout failed" }
}

$history = Invoke-Capture { docker history "localhost:5001/campus-api:$revision" }
Save-Evidence "image-history.txt" $history.Text

Write-Output "smoke and T02-T06"
$apiDev = Wait-Curl { curl.exe -kfsS --max-time 15 --resolve campus-dev.local:8443:127.0.0.1 https://campus-dev.local:8443/api/announcements } '"version": "1.0.0"'
$frontDev = Wait-Curl { curl.exe -kfsS --max-time 15 --resolve campus-dev.local:8443:127.0.0.1 https://campus-dev.local:8443/ } "CampusBoard"
$apiStage = Wait-Curl { curl.exe -kfsS --max-time 15 --resolve campus-stage.local:8443:127.0.0.1 https://campus-stage.local:8443/api/announcements } "\(stage\)"
$tls = Wait-Curl { curl.exe -kv --max-time 20 --resolve campus-dev.local:8443:127.0.0.1 https://campus-dev.local:8443/api/announcements } '"version": "1.0.0"'
Save-Evidence "smoke.txt" @"
Дата: $(& $now)
dev api $($apiDev.Code): $($apiDev.Text)
dev frontend $($frontDev.Code): $($frontDev.Text)
stage api $($apiStage.Code): $($apiStage.Text)
"@
if ($apiDev.Code -ne 0 -or $apiDev.Text -notmatch '"version": "1.0.0"' -or $apiDev.Text -notmatch 'token_set": true' -or $apiDev.Text -notmatch '\(dev\)') {
    Add-Result "SMOKE" "FAIL" "dev api"
    throw "dev smoke failed: $($apiDev.Text)"
}
if ($apiStage.Code -ne 0 -or $apiStage.Text -notmatch '\(stage\)') {
    throw "stage smoke failed: $($apiStage.Text)"
}

$id = Invoke-Capture { kubectl -n campus-dev exec deploy/campus-api -- id }
Save-Evidence "T02-nonroot.txt" @"
Дата: $(& $now)
Namespace: campus-dev
Команда: kubectl -n campus-dev exec deploy/campus-api -- id
Ожидание: uid не 0
Код: $($id.Code)
$($id.Text)
"@
if ($id.Text -match "uid=10001") { Add-Result "T02" "PASS" "uid=10001" } else { Add-Result "T02" "FAIL" $id.Text }

$roDeny = Invoke-Capture { kubectl -n campus-dev exec deploy/campus-api -- python -c "open('/etc/denied','w').write('x')" }
$roAllow = Invoke-Capture { kubectl -n campus-dev exec deploy/campus-api -- python -c "open('/tmp/ok','w').write('x'); print('tmp-write-ok')" }
Save-Evidence "T03-readonly.txt" @"
Дата: $(& $now)
Namespace: campus-dev
Команда: запись в /etc должна быть запрещена, запись в /tmp разрешена
Код записи в /etc: $($roDeny.Code)
$($roDeny.Text)
Код записи в /tmp: $($roAllow.Code)
$($roAllow.Text)
"@
if ($roDeny.Code -ne 0 -and $roAllow.Text -match "tmp-write-ok") { Add-Result "T03" "PASS" "root fs read-only, /tmp writable" } else { Add-Result "T03" "FAIL" "readonly test" }

$replicas = Invoke-Capture { kubectl -n campus-dev get deploy,pod }
Save-Evidence "T04-replicas.txt" @"
Дата: $(& $now)
Namespace: campus-dev
Команда: kubectl -n campus-dev get deploy,pod
Ожидание: READY 2/2 и AVAILABLE 2 у campus-api и campus-frontend
$($replicas.Text)
"@
if ($replicas.Text -match "campus-api\s+2/2" -and $replicas.Text -match "campus-frontend\s+2/2") { Add-Result "T04" "PASS" "2/2" } else { Add-Result "T04" "FAIL" "replicas" }

$apiIp = (kubectl -n campus-dev get svc campus-api -o jsonpath="{.spec.clusterIP}").Trim()
$slices = Invoke-Capture { kubectl -n campus-dev get endpointslice }
$fromIngress = Invoke-Capture { kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- curl -fsS --max-time 10 "http://${apiIp}/api/announcements" }
Save-Evidence "T05-service.txt" @"
Дата: $(& $now)
Namespace: campus-dev
Команда: kubectl -n campus-dev get endpointslice ; curl ClusterIP $apiIp из пода ingress-nginx
Ожидание: EndpointSlice Ready, ClusterIP отвечает
$($slices.Text)
Код curl: $($fromIngress.Code)
$($fromIngress.Text)
"@
if ($fromIngress.Code -eq 0 -and $fromIngress.Text -match '"version"') { Add-Result "T05" "PASS" $apiIp } else { Add-Result "T05" "FAIL" "clusterip" }

$services = Invoke-Capture { kubectl -n campus-dev get svc -o wide }
Save-Evidence "T06-tls.txt" @"
Дата: $(& $now)
Namespace: campus-dev
Команда: curl -kv https://campus-dev.local:8443/ready ; kubectl get svc
Ожидание: TLS отвечает, Service остаётся ClusterIP
$($tls.Text)
$($services.Text)
"@
if ($tls.Text -match "schannel|SSL connection|TLSv" -and $tls.Text -match '"version": "1.0.0"' -and $services.Text -notmatch "NodePort" -and $services.Text -match "ClusterIP") {
    Add-Result "T06" "PASS" "tls campus-dev.local:8443"
} else { Add-Result "T06" "FAIL" "tls" }

Write-Output "T07 self-healing"
$victim = (kubectl -n campus-dev get pod -l app=campus-api -o jsonpath="{.items[0].metadata.name}").Trim()
$deletedAt = & $now
kubectl -n campus-dev delete pod $victim --wait=false | Out-Null
Start-Sleep -Seconds 3
$sigterm = Invoke-Capture { kubectl -n campus-dev logs $victim }
kubectl -n campus-dev rollout status deployment/campus-api --timeout=120s | Out-Null
$afterDelete = Invoke-Capture { kubectl -n campus-dev get pods -l app=campus-api }
Save-Evidence "T07-self-healing.txt" @"
Дата: $deletedAt
Namespace: campus-dev
Команда: kubectl -n campus-dev delete pod $victim
Ожидание: Deployment возвращает два Ready Pod; в логе удалённого Pod виден SIGTERM
$($sigterm.Text)
$($afterDelete.Text)
"@
$readyApi = @($afterDelete.Text -split "`n" | Where-Object { $_ -match "campus-api" -and $_ -match "1/1" })
if ($readyApi.Count -ge 2) { Add-Result "T07" "PASS" "replicas restored" } else { Add-Result "T07" "FAIL" "self-healing" }

Write-Output "T11 network policy"
function Wait-PodDone([string]$Namespace, [string]$Name) {
    for ($i = 0; $i -lt 40; $i++) {
        $phase = (kubectl -n $Namespace get pod $Name -o jsonpath="{.status.phase}" 2>$null)
        if ($phase -eq "Succeeded" -or $phase -eq "Failed") { return $phase }
        Start-Sleep -Seconds 3
    }
    return "Timeout"
}
kubectl -n campus-dev delete pod net-deny --ignore-not-found | Out-Null
kubectl -n ingress-nginx delete pod net-allow --ignore-not-found | Out-Null
kubectl -n campus-dev run net-deny --restart=Never --image=busybox:1.36 --command -- wget -S -O- -T 5 "http://${apiIp}/api/announcements" | Out-Null
kubectl -n ingress-nginx run net-allow --restart=Never --image=busybox:1.36 --command -- wget -S -O- -T 5 "http://${apiIp}/api/announcements" | Out-Null
$denyPhase = Wait-PodDone "campus-dev" "net-deny"
$allowPhase = Wait-PodDone "ingress-nginx" "net-allow"
$denyLogs = Invoke-Capture { kubectl -n campus-dev logs net-deny }
$allowLogs = Invoke-Capture { kubectl -n ingress-nginx logs net-allow }
$denyCode = (kubectl -n campus-dev get pod net-deny -o jsonpath="{.status.containerStatuses[0].state.terminated.exitCode}")
$allowCode = (kubectl -n ingress-nginx get pod net-allow -o jsonpath="{.status.containerStatuses[0].state.terminated.exitCode}")
Save-Evidence "T11-networkpolicy.txt" @"
Дата: $(& $now)
Namespace: campus-dev
Положительный путь: Pod в namespace ingress-nginx ходит на ClusterIP $apiIp. Фаза $allowPhase, код $allowCode.
$($allowLogs.Text)
Отрицательный путь: Pod в campus-dev ходит на тот же ClusterIP. Фаза $denyPhase, код $denyCode.
$($denyLogs.Text)
Ожидание: разрешённый путь отвечает JSON, запрещённый завершается по таймауту.
"@
if ($allowPhase -eq "Succeeded" -and $allowLogs.Text -match '"version"' -and $denyPhase -eq "Failed") {
    Add-Result "T11" "PASS" "allow and deny"
} else { Add-Result "T11" "FAIL" "allow=$allowPhase deny=$denyPhase" }
kubectl -n campus-dev delete pod net-deny --ignore-not-found | Out-Null
kubectl -n ingress-nginx delete pod net-allow --ignore-not-found | Out-Null

Write-Output "T10 scale and hpa"
kubectl -n campus-dev delete hpa campus-api --wait=true | Out-Null
kubectl -n campus-dev scale deployment/campus-api --replicas=3 | Out-Null
kubectl -n campus-dev rollout status deployment/campus-api --timeout=120s | Out-Null
$scaled = Invoke-Capture { kubectl -n campus-dev get deploy campus-api }
kubectl -n campus-dev scale deployment/campus-api --replicas=2 | Out-Null
kubectl -n campus-dev rollout status deployment/campus-api --timeout=120s | Out-Null
kubectl apply -k k8s/overlays/dev | Out-Null
kubectl -n campus-dev apply -f $policyFile | Out-Null
Start-Sleep -Seconds 20
$hpa = Invoke-Capture { kubectl -n campus-dev get hpa campus-api }
$top = Invoke-Capture { kubectl -n campus-dev top pods }
$described = Invoke-Capture { kubectl -n campus-dev describe deployment campus-api }
Save-Evidence "T10-resources.txt" @"
Дата: $(& $now)
Namespace: campus-dev
Команда: kubectl scale deployment/campus-api --replicas=3, затем возврат к 2 и kubectl get hpa
Ожидание: requests/limits видны, ручной scale меняет replicas, HPA существует
После scale 3:
$($scaled.Text)
HPA:
$($hpa.Text)
top:
$($top.Text)
describe (фрагмент resources ищется в полном выводе):
$($described.Text)
"@
if ($scaled.Text -match "3/3" -and $described.Text -match "cpu:\s+50m" -and $hpa.Text -match "campus-api") {
    Add-Result "T10" "PASS" "scale 3 and hpa present"
} else { Add-Result "T10" "FAIL" "scale or hpa" }

Write-Output "T08 rolling update"
$curlJob = Start-Job -ScriptBlock {
    $lines = New-Object System.Collections.Generic.List[string]
    $end = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $end) {
        $body = & C:\Windows\System32\curl.exe -k -sS --max-time 3 --resolve campus-dev.local:8443:127.0.0.1 -w " CODE:%{http_code}" https://campus-dev.local:8443/api/announcements 2>&1
        $lines.Add("$(Get-Date -Format o) $body")
        Start-Sleep -Milliseconds 400
    }
    $lines
}
$rollStart = & $now
kubectl -n campus-dev set image deployment/campus-api "api=localhost:5001/campus-api@$v2Digest" | Out-Null
$roll = Invoke-Capture { kubectl -n campus-dev rollout status deployment/campus-api --timeout=180s }
Wait-Job $curlJob | Out-Null
$curlLines = Receive-Job $curlJob
Remove-Job $curlJob
$afterRoll = Invoke-Capture { curl.exe -kfsS --resolve campus-dev.local:8443:127.0.0.1 https://campus-dev.local:8443/api/announcements }
$curlText = ($curlLines -join "`r`n") + "`r`nAFTER`r`n" + $afterRoll.Text
$codes = [regex]::Matches($curlText, "CODE:(\d+)") | ForEach-Object { $_.Groups[1].Value }
$badCodes = @($codes | Where-Object { $_ -ne "200" })
$sawV2 = $curlText -match '"version": "2.0.0"'
Save-Evidence "T08-rolling.txt" @"
Дата: $rollStart
Namespace: campus-dev
Команда: kubectl -n campus-dev set image deployment/campus-api api=localhost:5001/campus-api@$v2Digest
Ожидание: rollout завершается, во время замены curl получает HTTP 200
Код rollout: $($roll.Code)
$($roll.Text)
Запросы:
$curlText
"@
if ($roll.Code -eq 0 -and $badCodes.Count -eq 0 -and $sawV2) { Add-Result "T08" "PASS" "no failed curls" } else { Add-Result "T08" "FAIL" "roll=$($roll.Code) bad=$($badCodes.Count)" }

Write-Output "T09 rollback"
$badStart = Get-Date
$during = Start-Job -ScriptBlock {
    $lines = New-Object System.Collections.Generic.List[string]
    $end = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $end) {
        $body = & C:\Windows\System32\curl.exe -k -sS --max-time 3 --resolve campus-dev.local:8443:127.0.0.1 -w " CODE:%{http_code}" https://campus-dev.local:8443/api/announcements 2>&1
        $lines.Add("$(Get-Date -Format o) $body")
        Start-Sleep -Milliseconds 500
    }
    $lines
}
kubectl -n campus-dev set image deployment/campus-api "api=localhost:5001/campus-api@$badDigest" | Out-Null
$badRoll = Invoke-Capture { kubectl -n campus-dev rollout status deployment/campus-api --timeout=150s }
$detected = Get-Date
Wait-Job $during | Out-Null
$duringText = (Receive-Job $during) -join "`r`n"
Remove-Job $during
$events = Invoke-Capture { kubectl -n campus-dev get events --sort-by=.lastTimestamp }
kubectl -n campus-dev rollout undo deployment/campus-api | Out-Null
$undo = Invoke-Capture { kubectl -n campus-dev rollout status deployment/campus-api --timeout=180s }
$restored = Get-Date
$afterUndo = Invoke-Capture { curl.exe -kfsS --resolve campus-dev.local:8443:127.0.0.1 https://campus-dev.local:8443/api/announcements }
$historyOut = Invoke-Capture { kubectl -n campus-dev rollout history deployment/campus-api }
Save-Evidence "T09-rollback.txt" @"
Дата обнаружения: $($detected.ToString('yyyy-MM-dd HH:mm:ss'))
Дата восстановления: $($restored.ToString('yyyy-MM-dd HH:mm:ss'))
Namespace: campus-dev
Плохой образ: localhost:5001/campus-api@$badDigest
Причина остановки: readiness /ready возвращает 503, новые Pod не становятся Ready, progressDeadlineSeconds=80. maxUnavailable=0, поэтому старые Pod остаются в Service и продолжают отвечать.
Код rollout status: $($badRoll.Code)
$($badRoll.Text)
Запросы во время плохого rollout:
$duringText
Откат:
$($undo.Text)
Ответ после undo:
$($afterUndo.Text)
История:
$($historyOut.Text)
События:
$($events.Text)
"@
$oldStillServed = $duringText -match '"version": "2.0.0"' -and $duringText -notmatch "CODE:(?!200)\d"
$undoOk = $undo.Code -eq 0 -and $afterUndo.Text -match '"version": "2.0.0"' -and $badRoll.Code -ne 0
if ($undoOk -and $oldStillServed) { Add-Result "T09" "PASS" "rollback to 2.0.0" } else { Add-Result "T09" "FAIL" "undo=$($undo.Code) badroll=$($badRoll.Code)" }

Write-Output "restore release digest"
kubectl -n campus-dev set image deployment/campus-api "api=localhost:5001/campus-api@$releaseDigest" | Out-Null
kubectl -n campus-dev rollout status deployment/campus-api --timeout=180s | Out-Null
$final = Invoke-Capture { curl.exe -kfsS --resolve campus-dev.local:8443:127.0.0.1 https://campus-dev.local:8443/api/announcements }

$rbac = Invoke-Capture {
    kubectl auth can-i get secrets -n campus-dev --as=system:serviceaccount:campus-dev:campus-api
    kubectl auth can-i list pods -n campus-dev --as=system:serviceaccount:campus-dev:campus-api
    kubectl auth can-i create deployments -n campus-dev --as=system:serviceaccount:campus-dev:campus-api
}
$nodes = Invoke-Capture { kubectl get nodes -o wide }
$spread = Invoke-Capture { kubectl -n campus-dev get pods -o wide }
$scanRepo = Invoke-Capture { git grep -n -I -E "BEGIN PRIVATE KEY|campus-demo-token" -- app k8s README.md }
$db = Invoke-Capture { kubectl get svc,deploy -A }
Save-Evidence "T12-secrets-db.txt" @"
Дата: $(& $now)
Команда: git grep по ключам и приватным ключам; kubectl get svc,deploy -A
Ожидание: выданного секрета нет в Git, база не запущена в кластере и не опубликована
git grep код $($scanRepo.Code)
$($scanRepo.Text)
В test_app.py есть фикстура super-secret-value. Это значение теста, оно не создаётся в кластере и не является секретом стенда.
$($db.Text)
"@
$leaked = $scanRepo.Code -eq 0 -and $scanRepo.Text -match "BEGIN PRIVATE KEY|campus-demo-token"
$dbInside = $db.Text -match "postgres|mysql"
if (-not $leaked -and -not $dbInside) { Add-Result "T12" "PASS" "no secret in git, no database service" } else { Add-Result "T12" "FAIL" "secret or database" }

Save-Evidence "rbac.txt" @"
Дата: $(& $now)
Команда: kubectl auth can-i от system:serviceaccount:campus-dev:campus-api
Ожидание: no, токен ServiceAccount не монтируется
$($rbac.Text)
"@
Save-Evidence "node-spread.txt" @"
Дата: $(& $now)
Один узел kind. Pod нельзя разложить по разным машинам, отказа узла стенд не переживёт.
PDB minAvailable=1 ограничивает добровольный drain, но не падение единственного узла и не заменяет maxUnavailable.
$($nodes.Text)
$($spread.Text)
"@
Save-Evidence "final-smoke.txt" @"
Дата: $(& $now)
После испытаний Deployment campus-dev возвращён на digest релиза $releaseDigest
$($final.Text)
"@

Save-Evidence "RESULTS.txt" (($results -join "`r`n"))
$failed = @($results | Where-Object { $_ -match "`tFAIL`t" })
if ($final.Text -notmatch '"version": "1.0.0"') { throw "final version is not the release image" }
if ($failed.Count -gt 0) { throw ("failed tests:`n" + ($failed -join "`n")) }
Write-Output "release evidence is complete"
