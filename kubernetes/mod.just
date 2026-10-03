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
        --overrides='{"spec":{"containers":[{"name":"browse-pvc-{{ claim }}","image":"mirror.gcr.io/alpine:latest","stdin":true,"tty":true,"command":["/bin/sh"],"workingDir":"/mnt","securityContext":{"runAsUser":1000,"runAsGroup":1000},"volumeMounts":[{"mountPath":"/mnt","name":"data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"{{ claim }}"}}]}}'

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

[doc('Restore a PVC from VolSync')]
restore ns app previous='0':
    flux -n {{ ns }} suspend kustomization {{ app }}
    flux -n {{ ns }} suspend helmrelease {{ app }}
    kubectl -n {{ ns }} get deploy,sts -l app.kubernetes.io/name={{ app }} -o name \
        | xargs -r -I{} kubectl -n {{ ns }} scale {} --replicas=0
    kubectl -n {{ ns }} wait pod --for=delete --selector="app.kubernetes.io/name={{ app }}" --timeout=5m
    kubectl -n {{ ns }} get replicationdestination {{ app }}-dst -o json \
        | jq 'del(.status)
            | .metadata = {name: "{{ app }}-manual", namespace: .metadata.namespace}
            | .spec.restic.copyMethod = "Direct"
            | .spec.restic.destinationPVC = "{{ app }}"
            | .spec.restic.previous = {{ previous }}' \
        | kubectl apply --server-side -f -
    kubectl -n {{ ns }} wait job/volsync-dst-{{ app }}-manual --for=create --timeout=120s
    kubectl -n {{ ns }} wait job/volsync-dst-{{ app }}-manual --for=condition=complete --timeout=120m
    kubectl -n {{ ns }} delete replicationdestination {{ app }}-manual
    flux -n {{ ns }} resume kustomization {{ app }}
    flux -n {{ ns }} resume helmrelease {{ app }}
    flux -n {{ ns }} reconcile helmrelease {{ app }} --force
    kubectl -n {{ ns }} wait pod --for=condition=ready --selector="app.kubernetes.io/name={{ app }}" --timeout=5m

[doc('Snapshot a PVC with VolSync')]
snapshot ns app:
    kubectl -n {{ ns }} patch replicationsources {{ app }} --type merge -p "{\"spec\":{\"trigger\":{\"manual\":\"$(date +%s)\"}}}"
    kubectl -n {{ ns }} wait job/volsync-src-{{ app }} --for=create --timeout=120s
    kubectl -n {{ ns }} wait job/volsync-src-{{ app }} --for=condition=complete --timeout=120m

[doc('Snapshot all PVCs with VolSync')]
snapshot-all:
    ts="$(date +%s)"
    sources="$(kubectl get replicationsources -A --no-headers -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name)"
    while read -r ns app; do
        kubectl -n "$ns" patch replicationsources "$app" --type merge -p "{\"spec\":{\"trigger\":{\"manual\":\"${ts}\"}}}"
    done <<< "$sources"
    # A manual trigger overrides the schedule in VolSync, so drop it once the sync is done
    while read -r ns app; do
        kubectl -n "$ns" wait replicationsources "$app" --for=jsonpath='{.status.lastManualSync}'="${ts}" --timeout=120m
        kubectl -n "$ns" patch replicationsources "$app" --type json -p '[{"op":"remove","path":"/spec/trigger/manual"}]'
    done <<< "$sources"

[doc('Unlock a VolSync restic repository')]
unlock ns app:
    kubectl apply --server-side -f - <<EOF
    apiVersion: batch/v1
    kind: Job
    metadata:
      name: volsync-unlock-{{ app }}
      namespace: {{ ns }}
    spec:
      ttlSecondsAfterFinished: 3600
      template:
        spec:
          automountServiceAccountToken: false
          restartPolicy: OnFailure
          containers:
            - name: restic
              image: docker.io/restic/restic:latest
              args: ["unlock", "--remove-all"]
              envFrom:
                - secretRef:
                    name: {{ app }}-volsync-secret
              volumeMounts:
                - name: repository
                  mountPath: /repository
          volumes:
            - name: repository
              nfs:
                server: nas.internal
                path: /volume1/volsync
    EOF
    kubectl -n {{ ns }} wait job/volsync-unlock-{{ app }} --for=condition=complete --timeout=5m
    kubectl -n {{ ns }} delete job volsync-unlock-{{ app }}

[arg('state', pattern='suspend|resume')]
[doc('Suspend or resume VolSync')]
volsync state:
    flux -n volsync-system {{ state }} kustomization volsync
    flux -n volsync-system {{ state }} helmrelease volsync
    kubectl -n volsync-system scale deployment volsync --replicas {{ if state == "suspend" { "0" } else { "1" } }}

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
