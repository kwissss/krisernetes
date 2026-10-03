set default-list
set default-script
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

[confirm('Apply Talos config to ' + node + ' [y|N] ?')]
[doc('Apply Talos config to a node')]
apply-node node *args:
    just talos render-config "{{ node }}" | talosctl -n "{{ node }}" apply-config -f /dev/stdin {{ args }}

[doc('Download Talos ISO')]
download-image version:
    schematic="$(just talos schematic-id)"
    curl -fL --remove-on-error --retry 5 --retry-delay 5 --retry-all-errors --progress-bar \
        -o "{{ source_directory() }}/talos-{{ version }}.iso" \
        "https://factory.talos.dev/image/${schematic}/{{ version }}/metal-amd64.iso"
    just log info "Downloaded Talos" version "{{ version }}" schematic "${schematic}"

[doc('Generate the kubeconfig')]
kubeconfig:
    talosctl kubeconfig -n "$(talosctl config info -o yaml | yq -r -e '.endpoints[0]')" --force {{ justfile_dir() }}

[confirm('Reboot node ' + node + ' [y|N] ?')]
[doc('Reboot a node')]
reboot-node node *args:
    talosctl -n "{{ node }}" reboot {{ args }}

[doc('Render Talos config for a node')]
render-config node:
    talosctl machineconfig patch <(op inject -i "{{ source_directory() }}/machineconfig.yaml") \
        -p @"{{ source_directory() }}/nodes/{{ node }}.yaml"

[confirm('Reset node ' + node + ' [y|N] ?')]
[doc('Reset a node')]
reset-node node *args:
    talosctl -n "{{ node }}" reset --reboot --graceful=false {{ args }}

[confirm('Shutdown node ' + node + ' [y|N] ?')]
[doc('Shutdown a node')]
shutdown-node node *args:
    talosctl -n "{{ node }}" shutdown --force {{ args }}

[confirm('Upgrade Kubernetes to ' + version + ' [y|N] ?')]
[doc('Upgrade Kubernetes version on the cluster')]
upgrade-k8s version:
    talosctl -n "$(talosctl config info -o yaml | yq -r -e '.endpoints[0]')" upgrade-k8s --to {{ version }}

[confirm('Upgrade node ' + node + ' [y|N] ?')]
[doc('Upgrade Talos version on a node')]
upgrade-node node *args:
    talosctl -n "{{ node }}" upgrade -i "$(just talos machine-image "{{ node }}")" -m powercycle --timeout=10m {{ args }}

[private]
machine-image node:
    just talos render-config "{{ node }}" | yq -r -e 'select(.machine) | .machine.install.image'

[private]
schematic-id:
    minijinja-cli "{{ source_directory() }}/schematic.yaml.j2" \
        | curl -sX POST --data-binary @- "https://factory.talos.dev/schematics" \
        | jq -r '.id'
