{ config, lib, modulesPath, pkgs, ... }:
let
  restoreNetwork = pkgs.writers.writePython3 "restore-network" {
    flakeIgnore = ["E501"];
  } ./restore_routes.py;
in {
  imports = [
    (modulesPath + "/installer/netboot/netboot-minimal.nix")
  ];

  # We are stateless, so just default to latest.
  system.stateVersion = config.system.nixos.version;

  # This is a variant of the upstream kexecScript that also allows embedding
  # a ssh key.
  system.build.kexecRun = lib.mkForce (pkgs.writeScript "kexec-run" ''
    #!/usr/bin/env bash
    set -ex
    shopt -s nullglob
    SCRIPT_DIR=$( cd -- "$( dirname -- "''${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
    INITRD_TMP=$(TMPDIR=$SCRIPT_DIR mktemp -d)
    cd "$INITRD_TMP"
    pwd
    mkdir -p initrd/ssh
    pushd initrd
    if [ -e /root/.ssh/authorized_keys ]; then
      # workaround for debian shenanigans
      grep -o '\(ssh-[^ ]* .*\)' /root/.ssh/authorized_keys >> ssh/authorized_keys
    fi
    if [ -e /etc/ssh/authorized_keys.d/root ]; then
      cat /etc/ssh/authorized_keys.d/root >> ssh/authorized_keys
    fi
    for p in /etc/ssh/ssh_host_*; do
      cp -a "$p" ssh
    done

    # save the networking config for later use
    if type -p ip &>/dev/null; then
      ip --json addr > addrs.json
      ip --json route > routes.json
    else
      echo "Skip saving static network addresses because no iproute2 binary is available." 2>&1
      echo "The image can depends only on DHCP to get network after reboot!" 2>&1
    fi

    find | cpio -o -H newc | gzip -9 > ../extra.gz
    popd
    cat "''${SCRIPT_DIR}/initrd" extra.gz > final-initrd

    "$SCRIPT_DIR/kexec" --load "''${SCRIPT_DIR}/bzImage" \
      --initrd=final-initrd \
      --command-line "init=${config.system.build.toplevel}/init ${toString config.boot.kernelParams}"

    # kexec will map the new kernel in memory so we can remove the kernel at this point
    rm -r "$INITRD_TMP"

    # Disconnect our background kexec from the terminal
    echo "machine will boot into nixos in in 6s..."
    if [[ -e /dev/kmsg ]]; then
      # this makes logging visible in `dmesg`, or the system consol or tools like journald
      exec > /dev/kmsg 2>&1
    else
      exec > /dev/null 2>&1
    fi
    # We will kexec in background so we can cleanly finish the script before the hosts go down.
    # This makes integration with tools like terraform easier.
    nohup bash -c "sleep 6 && '$SCRIPT_DIR/kexec' -e" &
  '');

  system.build.kexecTarball = pkgs.runCommand "kexec-tarball" {} ''
    mkdir kexec $out
    cp "${config.system.build.netbootRamdisk}/initrd" kexec/initrd
    cp "${config.system.build.kernel}/${config.system.boot.loader.kernelFile}" kexec/bzImage
    cp "${config.system.build.kexecRun}" kexec/run
    cp "${pkgs.pkgsStatic.kexec-tools}/bin/kexec" kexec/kexec
    tar -czvf $out/nixos-kexec-installer-${pkgs.stdenv.hostPlatform.system}.tar.gz kexec
  '';

  # IPMI SOL console redirection stuff
  boot.kernelParams = [
    "console=ttyS0,115200n8"
    "console=ttyAMA0,115200n8"
    "console=tty0"
  ];

  documentation.enable = false;
  # Not really needed. Saves a few bytes and the only service we are running is sshd, which we want to be reachable.
  networking.firewall.enable = false;

  # for detection if we are on kexec
  environment.etc.is_kexec.text = "true";

  systemd.services.restoreNetwork = {
    path = [
      pkgs.iproute2
    ];
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    serviceConfig.ExecStart = "${restoreNetwork} /root/network/addrs.json /root/network/routes.json";

    unitConfig.ConditionPathExists = [
      "/root/network/addrs.json"
      "/root/network/routes.json"
    ];
  };

  # Restore ssh host and user keys if they are available.
  # This avoids warnings of unknown ssh keys.
  boot.initrd.postMountCommands = ''
    mkdir -m 700 -p /mnt-root/root/.ssh
    mkdir -m 755 -p /mnt-root/etc/ssh
    mkdir -m 755 -p /mnt-root/root/network
    if [[ -f ssh/authorized_keys ]]; then
      install -m 400 ssh/authorized_keys /mnt-root/root/.ssh
    fi
    install -m 400 ssh/ssh_host_* /mnt-root/etc/ssh
    cp *.json /mnt-root/root/network/
  '';
}
