# Supermicro SYS-5019D-FN8TP — Storage Upgrade & Order Record

_Last updated: 30 June 2026_

## Base server

| Component | Spec |
|---|---|
| System | Supermicro SYS-5019D-FN8TP (1U, short-depth) |
| Motherboard | Supermicro X11SDV-8C-TP8F |
| CPU | Intel Xeon D-2146NT (8 cores / 16 threads) |
| Memory | 128 GB ECC |
| Onboard NVMe slot | 1× M.2 **M-key, NVMe, PCIe 3.0 x4, 2280 only** (a 22110 / 110 mm drive does NOT fit) |
| Expansion slots | 1× PCIe 3.0 x16, 1× PCIe 3.0 x8, Mini-PCIe (mSATA) |
| Other storage options | 4× 2.5" drive bays, onboard SATA3 ports |
| M.2 B-key (3042) slot | **WWAN / cellular only** (PCIe x1 + USB, SIM holder underneath) — NOT usable for an NVMe SSD: wrong key, 3042 size, x2 max |

### Workload
VM host running Android emulators, a Kubernetes cluster with node workloads, and light
CPU-based encoding of the Android VM display output. Write-heavy and sync-heavy.
Kubernetes etcd needs good fsync performance and **hardware power-loss protection (PLP)**.
Single drive per role, no RAID/mirror.

## Storage architecture (split design)

Rationale: enterprise M.2-2280 drives with PLP are scarce and expensive (mid-2026 NAND
price surge — a single 960 GB enterprise PLP drive was ~€600). Only etcd truly needs PLP,
and it is tiny, so PLP-grade flash is bought only for the small boot/etcd drive, while the
bulk VM/container data goes on a cheaper, faster consumer NVMe.

| Role | Drive | Where it goes | Why |
|---|---|---|---|
| OS + etcd (needs PLP) | Kingston DC2000B 240GB (SEDC2000BM8/240G) | Onboard M.2 2280 slot | Enterprise, hardware PLP (capacitors), 0.4 DWPD / 175 TBW, NVMe 1.4, 5-yr warranty |
| Bulk VM / container data | WD Black SN7100 1TB (WDS100T4X0E-00CJA0) | PCIe 3.0 x8 slot via the Delock card | TLC, 600 TBW, 5-yr warranty, DRAM-less (HMB), efficient / runs cool — good for a bare drive in a 1U |
| Mount for the bulk NVMe | Delock 90047 — PCIe 4.0 x4 → 1× M.2 M-key NVMe | PCIe 3.0 x8 slot | Passive single-M.2 card, **low-profile bracket** (required for 1U), bootable |

### Install notes
- Both the onboard M.2 slot and the PCIe slot run at **PCIe Gen3** here (~3,500 MB/s ceiling);
  the drives' Gen4 capability is unused — expected and fine.
- Fit the Delock card with its **low-profile bracket** for the 1U chassis.
- Put OS + etcd on the **DC2000B** (has PLP). The **SN7100 has no PLP**, so keep only
  ephemeral / reconstructible data on it, or back up anything important that lands there.
- The bulk drive sits bare on the riser (no dedicated heatsink) — watch temps under
  sustained writes.

