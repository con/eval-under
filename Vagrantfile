# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Vagrantfile for developing/testing the beegfs-test harness locally.
#
# Provides an Ubuntu 24.04 VM with Docker + BeeGFS client kernel module +
# git-annex, so a dev container without CAP_SYS_MODULE can iterate on the
# eval_under_beegfs wrapper and GH workflows.
#
# Default provider: libvirt (KVM/QEMU). Falls back gracefully if unset.
#
# Env vars:
#   VAGRANT_INSTALL_ACT=1   also install nektos/act for local workflow replays
#   BEEGFS_VERSION=7.4.6    BeeGFS APT repo version to use (default 7.4.6)

Vagrant.configure("2") do |config|
  # Box choice depends on provider:
  #   libvirt      -> cloud-image/ubuntu-24.04  (Canonical official; also has qemu)
  #   virtualbox   -> bento/ubuntu-24.04        (no libvirt provider available)
  # generic/* boxes were retired from Vagrant Cloud in 2024.
  provider = ENV["VAGRANT_DEFAULT_PROVIDER"] || "libvirt"
  config.vm.box = case provider
                  when "virtualbox" then "bento/ubuntu-24.04"
                  else "cloud-image/ubuntu-24.04"
                  end
  config.vm.hostname = "beegfs-test"

  # Static private-network IP so the host (and containers routed via the
  # host's VPN) can reach the guest at a stable address without going
  # through `vagrant ssh`. Same 172.28.128.0/24 subnet used by the
  # datalad-in-a-box VM (which is already routed on this workstation);
  # distinct IP to avoid collision. Override with BEEGFS_VM_IP.
  vm_ip = ENV.fetch("BEEGFS_VM_IP", "172.28.128.50")
  config.vm.network "private_network", ip: vm_ip

  # Sync the repo into the guest. rsync is more portable than 9p/virtiofs
  # and avoids permission surprises when root inside the VM touches files.
  config.vm.synced_folder ".", "/vagrant", type: "rsync",
    rsync__exclude: [".git/", ".datalad/", ".vagrant/"]

  config.vm.provider :libvirt do |lv|
    lv.cpus = 4
    lv.memory = 6144
    lv.machine_virtual_size = 30
    lv.cpu_mode = "host-passthrough"
    lv.nested = true
  end

  config.vm.provider :virtualbox do |vb|
    vb.cpus = 4
    vb.memory = 6144
  end

  beegfs_version = ENV.fetch("BEEGFS_VERSION", "7.4.6")

  config.vm.provision "setup", type: "shell",
    path: "provision/setup.sh",
    env: { "BEEGFS_VERSION" => beegfs_version },
    privileged: true

  if ENV["VAGRANT_INSTALL_ACT"] == "1"
    config.vm.provision "act", type: "shell",
      path: "provision/install-act.sh",
      privileged: true
  end
end
