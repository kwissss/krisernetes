set default-list
set default-script
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

[doc('Apply local Flux Kustomization')]
apply-ks ns ks:
    just kube render-local-ks "{{ ns }}" "{{ ks }}" | kubectl apply --server-side --force-conflicts --field-manager=kustomize-controller -f -

[doc('Browse a PVC')]
browse-pvc ns claim:
    kubectl run -n {{ ns }} browse-pvc-{{ claim }} -it --rm --restart=Never \
        --image=mirror.gcr.io/alpine:latest \
        --overrides='{"spec":{"containers":[{"name":"browse-pvc-{{ claim }}","image":"mirror.gcr.io/alpine:latest","stdin":true,"tty":true,"command":["/bin/sh"],"workingDir":"/mnt","volumeMounts":[{"mountPath":"/mnt","name":"data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"{{ claim }}"}}]}}'

[doc('Debug a node')]
debug-node node:
    trap 'kubectl delete pod -n default -l app.kubernetes.io/managed-by=kubectl-debug --field-selector spec.nodeName={{ node }} --ignore-not-found --wait=false' EXIT
    kubectl debug node/{{ node }} -n default -it --image=mirror.gcr.io/alpine:latest --profile=sysadmin

[doc('Delete local Flux Kustomization')]
delete-ks ns ks:
    just kube render-local-ks "{{ ns }}" "{{ ks }}" | kubectl delete -f -

[doc('Prune pods in Failed, Pending, or Succeeded state')]
prune-pods:
    for phase in Failed Pending Succeeded; do
        kubectl delete pods -A --field-selector status.phase="$phase" --ignore-not-found=true
    done

[doc('Force Flux to pull in changes from the Git repository')]
reconcile:
    flux -n flux-system reconcile kustomization flux-system --with-source

[doc('Scale an app to 0 until its Longhorn volumes detach, then scale it back')]
remount ns app:
    workloads="$(kubectl -n {{ ns }} get deploy,sts -l app.kubernetes.io/name={{ app }} -o name)"
    declare -A replicas
    for w in $workloads; do
        replicas[$w]="$(kubectl -n {{ ns }} get "$w" -o jsonpath='{.spec.replicas}')"
    done
    scale_back() {
        for w in $workloads; do
            kubectl -n {{ ns }} scale "$w" --replicas="${replicas[$w]}"
        done
    }
    trap scale_back EXIT
    claims="$(kubectl -n {{ ns }} get deploy,sts -l app.kubernetes.io/name={{ app }} -o jsonpath='{.items[*].spec.template.spec.volumes[*].persistentVolumeClaim.claimName}')"
    kubectl -n {{ ns }} scale $workloads --replicas=0
    kubectl -n {{ ns }} wait pod --for=delete --selector="app.kubernetes.io/name={{ app }}" --timeout=5m
    for claim in $claims; do
        pv="$(kubectl -n {{ ns }} get pvc "$claim" -o jsonpath='{.spec.volumeName}')"
        kubectl -n storage get volumes.longhorn.io "$pv" &>/dev/null || continue
        kubectl -n storage wait volumes.longhorn.io "$pv" --for=jsonpath='{.status.state}'=detached --timeout=5m
    done
    trap - EXIT
    scale_back
    kubectl -n {{ ns }} wait pod --for=condition=ready --selector="app.kubernetes.io/name={{ app }}" --timeout=5m

[doc('Remount every app with an attached Longhorn volume')]
remount-all:
    apps="$(kubectl -n storage get volumes.longhorn.io -o json \
        | jq -r '.items[] | select(.status.state == "attached") | .status.kubernetesStatus as $k | $k.workloadsStatus[]? | "\($k.namespace) \(.podName)"' \
        | while read -r ns pod; do
            echo "$ns $(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/name}')"
        done | sort -u)"
    while read -r ns app; do
        just kube remount "$ns" "$app"
    done <<< "$apps"

[doc('Restore a PVC from kopiur')]
restore ns app previous='0':
    flux -n {{ ns }} suspend kustomization {{ app }}
    flux -n {{ ns }} suspend helmrelease {{ app }}
    kubectl -n {{ ns }} get deploy,sts -l app.kubernetes.io/name={{ app }} -o name \
        | xargs -r -I{} kubectl -n {{ ns }} scale {} --replicas=0
    kubectl -n {{ ns }} wait pod --for=delete --selector="app.kubernetes.io/name={{ app }}" --timeout=5m
    # --from-policy defaults to continuing without a snapshot, which would leave the PVC as it is
    kubectl kopiur restore -n {{ ns }} --from-policy {{ app }} --offset {{ previous }} --to-pvc {{ app }} \
        --on-missing-snapshot fail --enable-file-deletion --wait --timeout 2h
    flux -n {{ ns }} resume kustomization {{ app }}
    flux -n {{ ns }} resume helmrelease {{ app }}
    flux -n {{ ns }} reconcile helmrelease {{ app }} --force
    kubectl -n {{ ns }} wait pod --for=condition=ready --selector="app.kubernetes.io/name={{ app }}" --timeout=5m

[doc('Snapshot a PVC with kopiur')]
snapshot ns app:
    kubectl kopiur snapshot now -n {{ ns }} --policy {{ app }} --wait --timeout 2h

[doc('Snapshot all PVCs with kopiur')]
snapshot-all:
    policies="$(kubectl get snapshotpolicies -A --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name)"
    pids=()
    while read -r ns app; do
        kubectl kopiur snapshot now -n "$ns" --policy "$app" --wait --timeout 2h < /dev/null &
        pids+=("$!")
    done <<< "$policies"
    failed=0
    for pid in "${pids[@]}"; do
        wait "$pid" || failed=1
    done
    exit "$failed"

[arg('state', pattern='suspend|resume')]
[doc('Suspend or resume kopiur')]
kopiur state:
    flux -n kopiur-system {{ state }} kustomization kopiur
    flux -n kopiur-system {{ state }} helmrelease kopiur
    kubectl -n kopiur-system scale deployment kopiur-controller --replicas {{ if state == "suspend" { "0" } else { "1" } }}

[arg('resource', pattern='hr|ks|gitrepo|ocirepo|es')]
[doc('Sync a resource')]
sync resource:
    kubectl get {{ resource }} --no-headers -A | while read -r ns name _; do
        kubectl -n "$ns" annotate --field-manager flux-client-side-apply --overwrite {{ resource }} "$name" \
            "force-sync=$(date +%s)" \
            "reconcile.fluxcd.io/requestedAt=$(date +%s)" \
            "reconcile.fluxcd.io/forceAt=$(date +%s)"
    done

[doc('View a secret')]
view-secret ns secret:
    kubectl view-secret -n {{ ns }} {{ secret }}

[private]
render-local-ks ns ks:
    flate build ks --namespace "{{ ns }}" --output yaml "{{ ks }}"
