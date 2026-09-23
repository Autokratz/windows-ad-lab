# Building the lab

Built on Ubuntu with KVM/QEMU. VirtualBox or Hyper-V work equally well; only the host setup section changes.

## Host requirements

| | Minimum | This lab was built on |
|---|---|---|
| CPU | 4 cores with VT-x/AMD-V | 12 cores |
| RAM | 12 GB | 30 GB |
| Disk | 120 GB free | 239 GB free |

Confirm hardware virtualisation is available before anything else:

```bash
grep -cE 'vmx|svm' /proc/cpuinfo   # non-zero
ls -l /dev/kvm                     # must exist
```

## Host setup

```bash
sudo apt update
sudo apt install qemu-kvm libvirt-daemon-system libvirt-clients \
                 virt-manager bridge-utils ovmf

sudo usermod -aG libvirt,kvm "$USER"
# log out and back in, then:
virsh list --all
```

`ovmf` provides UEFI firmware. Windows Server 2022 will install on legacy BIOS, but UEFI with Secure Boot is what you would actually deploy, and it is the configuration where BitLocker and Credential Guard behave normally.

## Downloads

| | Where | Note |
|---|---|---|
| Windows Server 2022 | Microsoft Evaluation Center | 180-day evaluation, no licence key needed |
| Windows 11 Enterprise | Microsoft Evaluation Center | 90-day evaluation |
| virtio-win drivers | fedorapeople.org virtio-win stable ISO | Needed during install for disk and network |

Both evaluations are free and legitimate for exactly this purpose. The server evaluation can be extended twice with `slmgr /rearm`, which is enough for a year of lab time.

## Network

One isolated virtual network so the lab never competes with the host's DHCP:

```bash
cat > /tmp/meridian-net.xml <<'XML'
<network>
  <name>meridian</name>
  <bridge name='virbr-meridian' stp='on' delay='0'/>
  <forward mode='nat'/>
  <ip address='10.20.0.1' netmask='255.255.255.0'>
  </ip>
</network>
XML

virsh net-define /tmp/meridian-net.xml
virsh net-start meridian
virsh net-autostart meridian
```

Note there is **no `<dhcp>` block**. That is deliberate — the domain controller is the DHCP server for this network, and libvirt's dnsmasq would fight it for every DISCOVER. Two DHCP servers on one segment is a genuinely hard fault to diagnose, so it is worth not creating.

The gateway `10.20.0.1` is libvirt's, which matches the gateway handed out by the DHCP scope in `02-Configure-DnsDhcp.ps1`.

## Virtual machines

**DC01** — the domain controller

```bash
virt-install \
  --name DC01 \
  --memory 4096 \
  --vcpus 2 \
  --cpu host-passthrough \
  --disk path=/var/lib/libvirt/images/DC01.qcow2,size=60,bus=virtio,format=qcow2 \
  --disk path=/path/to/virtio-win.iso,device=cdrom \
  --cdrom /path/to/SERVER_EVAL_x64FRE_en-us.iso \
  --network network=meridian,model=virtio \
  --boot uefi \
  --os-variant win2k22 \
  --graphics spice
```

**WS01** — the domain member workstation

```bash
virt-install \
  --name WS01 \
  --memory 4096 \
  --vcpus 2 \
  --cpu host-passthrough \
  --disk path=/var/lib/libvirt/images/WS01.qcow2,size=64,bus=virtio,format=qcow2 \
  --disk path=/path/to/virtio-win.iso,device=cdrom \
  --cdrom /path/to/Win11_Enterprise_Eval.iso \
  --network network=meridian,model=virtio \
  --boot uefi \
  --os-variant win11 \
  --graphics spice
```

Windows 11 requires a TPM. Add one in virt-manager under *Add Hardware → TPM → Emulated, TIS, version 2.0*, or pass `--tpm backend.type=emulator,backend.version=2.0,model=tpm-tis`.

### During Windows setup

The installer will not see a virtio disk. At the disk selection screen choose **Load driver**, browse the virtio-win CD to `viostor\2k22\amd64` (or `w11\amd64`), and load it. Do the same for `NetKVM` if the network adapter is missing after first boot.

Choose the **Desktop Experience** edition of Server 2022. Server Core is the better production answer, but the GUI tools matter here — a large part of this lab's value is being able to demonstrate the same task in both GPMC and PowerShell.

## Snapshots

Take a snapshot after each provisioning step. The fault injection is designed to be reversible, but a snapshot is faster than a repair when an experiment goes further than intended.

```bash
virsh snapshot-create-as DC01 "01-forest-promoted"  --description "after 01-Install-Forest"
virsh snapshot-create-as DC01 "05-baseline-applied" --description "full build, healthy"

virsh snapshot-list DC01
virsh snapshot-revert DC01 "05-baseline-applied"
```

`05-baseline-applied` is the one to keep. Every fault injection starts from there.

## Running the provisioning scripts

Copy the repository onto DC01 — a shared folder, a virtio-9p mount, or simply `git clone` once the VM has internet through the NAT network.

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
cd C:\lab\windows-ad-lab
.\provision\01-Install-Forest.ps1
```

`-Scope Process` rather than a machine-wide change: the relaxed policy lasts for that session only and leaves nothing behind. Making a permanent execution-policy change on a domain controller to run a build script is a habit worth not forming.

## Order

1. `01-Install-Forest.ps1` — reboots twice (once for the rename, once for promotion)
2. `02-Configure-DnsDhcp.ps1`
3. `03-Build-OuStructure.ps1`
4. `04-Import-Users.ps1 -WhatIf`, then for real
5. `05-Set-GpoBaseline.ps1`
6. `validate\Test-DomainHealth.ps1` — expect all PASS before going further
7. Build WS01 and join it (runbook task 6)
8. `validate\Get-LabEvidence.ps1` — capture, then commit `evidence/`
