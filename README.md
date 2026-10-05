<div align="center">

### <img src="https://fonts.gstatic.com/s/e/notoemoji/latest/1f680/512.gif" alt="🚀" width="16" height="16"> krisernetes <img src="https://fonts.gstatic.com/s/e/notoemoji/latest/1f6a7/512.gif" alt="🚧" width="16" height="16">

_... a single-node home Kubernetes cluster managed with Flux and Renovate_ <img src="https://fonts.gstatic.com/s/e/notoemoji/latest/1f916/512.gif" alt="🤖" width="16" height="16">

</div>

<div align="center">

[![Talos](https://kromgo.kris.party/badges/talos_version)](https://www.talos.dev)&nbsp;&nbsp;
[![Kubernetes](https://kromgo.kris.party/badges/kubernetes_version)](https://kubernetes.io)&nbsp;&nbsp;
[![Flux](https://kromgo.kris.party/badges/flux_version)](https://fluxcd.io)&nbsp;&nbsp;

</div>

<div align="center">

[![Age](https://kromgo.kris.party/badges/cluster_birth_age)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![Uptime](https://kromgo.kris.party/badges/cluster_uptime_age)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![Nodes](https://kromgo.kris.party/badges/cluster_node_count)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![Pods](https://kromgo.kris.party/badges/cluster_pod_count)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![CPU](https://kromgo.kris.party/badges/cluster_cpu_usage)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![Memory](https://kromgo.kris.party/badges/cluster_memory_usage)](https://github.com/home-operations/kromgo)&nbsp;&nbsp;
[![Alerts](https://kromgo.kris.party/badges/cluster_alert_count)](https://github.com/home-operations/kromgo)

</div>

---

## <img src="https://fonts.gstatic.com/s/e/notoemoji/latest/1f4a1/512.gif" alt="💡" width="20" height="20"> Overview

This is a mono repository for my home Kubernetes cluster. Everything running on it is declared here and applied by [Flux](https://github.com/fluxcd/flux2); [Renovate](https://github.com/renovatebot/renovate) keeps the dependencies up to date through pull requests.

---

## <img src="https://fonts.gstatic.com/s/e/notoemoji/latest/1f331/512.gif" alt="🌱" width="20" height="20"> Kubernetes

My Kubernetes cluster is a single [Talos Linux](https://www.talos.dev) node. This is a semi-hyper-converged cluster; workloads and storage share the same resources, while I have a separate server with btrfs for NFS/SMB shares, bulk file storage and backups.

### Core Components

- **Networking**: [cilium](https://github.com/cilium/cilium) provides eBPF-based networking, replaces kube-proxy and announces LoadBalancer IPs over L2. [envoy-gateway](https://github.com/envoyproxy/gateway) serves the Gateway API with separate internal and external gateways, and [cloudflared](https://github.com/cloudflare/cloudflared) exposes the external one through a Cloudflare Tunnel.
- **DNS & Certificates**: two [external-dns](https://github.com/kubernetes-sigs/external-dns) instances keep records in sync (see [DNS](#-dns)), and [cert-manager](https://github.com/cert-manager/cert-manager) automates the SSL/TLS certificate management.
- **Secrets**: [external-secrets](https://github.com/external-secrets/external-secrets) with [1Password Connect](https://github.com/1Password/connect) injects secrets into Kubernetes.
- **Storage & Data Protection**: [longhorn](https://github.com/longhorn/longhorn) provides application volumes and CSI snapshots, and [openebs](https://github.com/openebs/openebs) local hostpath volumes cover caches and the observability stack. [kopiur](https://github.com/home-operations/kopiur) handles backups and restores, and disaster recovery is declarative: on an empty cluster, every app's volume is restored from its latest backup before the app starts.
- **Observability**: [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) with Alertmanager sending to Discord, [grafana-operator](https://github.com/grafana/grafana-operator) for dashboards, and [victoria-logs](https://github.com/VictoriaMetrics/VictoriaLogs) fed by [fluent-bit](https://github.com/fluent/fluent-bit).

### GitOps

[Flux](https://github.com/fluxcd/flux2), installed and upgraded by the [flux-operator](https://github.com/controlplaneio-fluxcd/flux-operator), watches the [kubernetes](./kubernetes/) folder and makes the changes to my cluster based on the state of my Git repository.

Flux recursively searches the `kubernetes/apps` folder until it finds the top level `kustomization.yaml` per directory and applies all the resources listed in it. That `kustomization.yaml` generally only has a namespace resource and one or many Flux kustomizations (`ks.yaml`). Under the control of those Flux kustomizations there is a `HelmRelease` or other resources related to the application.

[Renovate](https://github.com/renovatebot/renovate) watches my **entire** repository for dependency updates and opens a pull request when it finds one. Every pull request is rendered and diffed with [flate](https://github.com/home-operations/flate) in GitHub Actions, and once merged, Flux applies the change to my cluster.

### Directories

```sh
📁 bootstrap       # helmfile used once to bootstrap the cluster
📁 kubernetes
├── 📁 apps        # applications, one folder per namespace
├── 📁 components  # re-useable kustomize components (kopiur)
└── 📁 flux        # flux system configuration
📁 talos           # talos machine configuration and patches
```

---

## <img src="https://fonts.gstatic.com/s/e/notoemoji/latest/1f636_200d_1f32b_fe0f/512.gif" alt="😶" width="20" height="20"> Cloud Dependencies

Most of my infrastructure is self-hosted, but a few key parts rely on the cloud. This avoids chicken-and-egg problems (the secrets needed to build the cluster can't live inside it) and keeps critical services working when the cluster is down.

| Service                                   | Use                                                                      |
| ----------------------------------------- | ------------------------------------------------------------------------ |
| [1Password](https://1password.com/)       | Secrets with [External Secrets](https://external-secrets.io/)            |
| [Cloudflare](https://www.cloudflare.com/) | Domain, public DNS and the tunnel for external access                    |
| [Discord](https://discord.com/)           | Alertmanager notifications                                               |
| [GitHub](https://github.com/)             | Hosting this repository and continuous integration for pull-based GitOps |

---

## <img src="https://fonts.gstatic.com/s/e/notoemoji/latest/1f30e/512.gif" alt="🌎" width="20" height="20"> DNS

Two instances of [ExternalDNS](https://github.com/kubernetes-sigs/external-dns) run in my cluster. One syncs private records for every route and LoadBalancer service to the UniFi gateway using the [ExternalDNS webhook provider for UniFi](https://github.com/home-operations/external-dns-unifi-webhook), while the other syncs public, proxied records to `Cloudflare`. Only routes attached to the `envoy-external` gateway are published to Cloudflare, so anything on `envoy-internal` stays resolvable on the LAN only.

---

## <img src="https://fonts.gstatic.com/s/e/notoemoji/latest/2699_fe0f/512.gif" alt="⚙" width="20" height="20"> Hardware

### Compute

**Intel NUC 8 (Core i7-8705G)** · 32 GB RAM · Talos / Kubernetes

- **OS**: 500 GB Samsung 970 EVO Plus NVMe
- **Local storage**: 2 TB Samsung 970 EVO Plus NVMe
- **Out-of-band**: JetKVM

### Storage

**Synology DS423+** · DSM / btrfs

- **Volume 1**: 3 × 20 TB Seagate Exos X20 and 1 × 24 TB Seagate Exos X24

### Networking (UniFi)

- **Cloud Gateway Fiber**: router and firewall; also serves the private DNS records synced by ExternalDNS
- **USW Flex 2.5G 5**: 2.5 GbE 5-port switch
- **U7 Pro**: Wi-Fi 7 access point

---

## <img src="https://fonts.gstatic.com/s/e/notoemoji/latest/1f64f/512.gif" alt="🙏" width="20" height="20"> Gratitude and Thanks

Thanks to all the people who donate their time to the [Home Operations](https://discord.gg/home-operations) Discord community. Be sure to check out [kubesearch.dev](https://kubesearch.dev/) for ideas on how to deploy applications or what you could deploy.
