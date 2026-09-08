# NixOS module: install Trivalent + (opt-in) an AppArmor profile that stands in
# for the `trivalent-selinux` policy NixOS cannot run.
#
# The profile is generated from the package's own store paths, so a version
# bump needs no edits here. It ships in COMPLAIN mode by default: every access
# the browser makes outside the policy is logged (`journalctl -k --grep=apparmor
# ... profile="trivalent"`) but not blocked, so it is safe to deploy and tune.
# Flip `programs.trivalent.apparmor.enforce = true` after a soak.
#
# Confinement shape (approaching an SELinux targeted domain):
#   - read-only almost everywhere; the ONLY writable app state is
#     ~/.config/trivalent, ~/.cache/trivalent, ~/.pki, the XDG download dir,
#     /tmp, /dev/shm;
#   - $HOME is otherwise unreadable, with hard denies on ssh/gpg/age/keyrings/
#     shell history/credential stores (extend via `denyHomePaths`);
#   - the bwrap + user-namespace + pivot_root machinery Chromium's own sandbox
#     needs is permitted (it is namespaced, not the security boundary here);
#   - network is allowed (a browser); signals/ptrace are restricted to peers in
#     this same profile.
{
  self,
  ...
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.trivalent;
  system = pkgs.stdenv.hostPlatform.system;
  defaultPkg = self.packages.${system}.trivalent or null;

  mkDeny = paths: lib.concatMapStringsSep "\n" (p: "  deny ${p} rwklmx,") paths;
  mkRead = paths: lib.concatMapStringsSep "\n" (p: "  owner ${p} r,") paths;

  baseDenyHome = [
    "@{HOME}/.ssh/**"
    "@{HOME}/.gnupg/**"
    "@{HOME}/.aws/**"
    "@{HOME}/.kube/**"
    "@{HOME}/.docker/config.json"
    "@{HOME}/.local/share/keyrings/**"
    "@{HOME}/.local/share/chezmoi/**"
    "@{HOME}/.mozilla/**"
    "@{HOME}/.password-store/**"
    "@{HOME}/.config/sops/**"
    "@{HOME}/.config/age/**"
    "@{HOME}/.config/gh/**"
    "@{HOME}/.config/git/**"
    "@{HOME}/.config/rclone/**"
    "@{HOME}/.config/Bitwarden*/**"
    "@{HOME}/.config/keepassxc/**"
    "@{HOME}/.claude/**"
    "@{HOME}/.claude.json"
    "@{HOME}/.git-credentials"
    "@{HOME}/.netrc"
    "@{HOME}/.bash_history"
    "@{HOME}/.zsh_history"
    "@{HOME}/.python_history"
    "@{HOME}/**/id_rsa"
    "@{HOME}/**/id_ed25519"
    "@{HOME}/**/id_ecdsa"
    "@{HOME}/**/*.age"
    "@{HOME}/**/*.gpg"
    "@{HOME}/**/*.kdbx"
  ];

  profile = ''
    abi <abi/4.0>,
    include <tunables/global>

    # attach by store glob so version bumps need no change here. One attachment
    # expression only -- brace alternation covers both the buildFHSEnv `-bwrap`
    # launcher (what the bin/ symlink resolves to) and the bin/trivalent path.
    profile trivalent /nix/store/*-trivalent-*{-bwrap,/bin/trivalent} flags=(attach_disconnected,mediate_deleted${
      lib.optionalString (!cfg.apparmor.enforce) ",complain"
    }) {
      include <abstractions/base>
      include <abstractions/nameservice>
      include <abstractions/fonts>
      include <abstractions/mesa>
      include <abstractions/dbus-session-strict>
      include <abstractions/dbus-accessibility-strict>
      include <abstractions/audio>

      # --- bwrap / userns / FHS chroot machinery (namespaced; not the boundary) ---
      userns,
      capability sys_admin,
      capability sys_chroot,
      capability sys_ptrace,
      capability sys_resource,
      capability sys_nice,
      capability setuid,
      capability setgid,
      capability setpcap,
      capability dac_override,
      capability dac_read_search,
      capability fowner,
      capability net_bind_service,
      mount,
      umount,
      remount,
      pivot_root,
      change_profile -> trivalent,
      signal (send,receive) peer=trivalent,
      signal (receive) peer=unconfined,
      ptrace (read,trace) peer=trivalent,
      dbus (send,receive) bus=session,

      # --- executables: the store is world-readable; control is on writes/$HOME ---
      /nix/store/** r,
      /nix/store/**/{bin,sbin,libexec}/** ix,
      /nix/store/*-trivalent-*/** ix,
      /run/current-system/sw/bin/** ix,
      /bin/sh ix,

      # --- the ONLY writable application state ---
      owner @{HOME}/.config/trivalent/ rw,
      owner @{HOME}/.config/trivalent/** rwkl,
      owner @{HOME}/.cache/trivalent/ rw,
      owner @{HOME}/.cache/trivalent/** rwkl,
      owner @{HOME}/.local/share/trivalent/ rw,
      owner @{HOME}/.local/share/trivalent/** rwkl,
      owner @{HOME}/.pki/ rw,
      owner @{HOME}/.pki/** rwk,

      # --- user-facing file exchange ---
      owner @{HOME}/ r,
      owner @{HOME}/Downloads/ r,
      owner @{HOME}/Downloads/** rw,
      owner @{XDG_DOWNLOAD_DIR}/ r,
      owner @{XDG_DOWNLOAD_DIR}/** rw,
    ${mkRead cfg.apparmor.readableHomePaths}

      # --- hard denies (the SELinux-like part) ---
    ${mkDeny (baseDenyHome ++ cfg.apparmor.denyHomePaths)}
      deny @{HOME}/.config/ w,
      deny @{HOME}/.ssh/ r,
      deny @{HOME}/.gnupg/ r,
      deny /home/*/ w,
      deny /root/** rwklmx,
      deny /etc/shadow rwklmx,
      deny /etc/gshadow rwklmx,

      # --- system config the browser legitimately reads ---
      /etc/ r,
      /etc/trivalent/** r,
      /etc/chromium/** r,
      /etc/chrome/** r,
      /etc/machine-id r,
      /etc/os-release r,
      /etc/localtime r,
      /etc/timezone r,
      /etc/nsswitch.conf r,
      /etc/passwd r,
      /etc/group r,
      /etc/fonts/** r,
      /etc/ssl/certs/** r,
      /etc/pki/** r,
      /etc/static/** r,
      /etc/mime.types r,
      /run/current-system/sw/share/** r,
      /run/opengl-driver*/** rm,
      /run/systemd/resolve/stub-resolv.conf r,

      # --- devices ---
      /dev/ r,
      /dev/dri/ r,
      /dev/dri/* rw,
      /dev/null rw,
      /dev/zero rw,
      /dev/full rw,
      /dev/random r,
      /dev/urandom r,
      /dev/tty rw,
      /dev/ptmx rw,
      /dev/pts/* rw,
      /dev/shm/ rw,
      /dev/shm/** rwk,
      /dev/fuse rw,
      owner /dev/hidraw* rw,
      owner /dev/snd/* rw,
      /dev/video* rw,

      # --- runtime sockets ---
      owner /run/user/@{uid}/ r,
      owner /run/user/@{uid}/wayland-* rw,
      owner /run/user/@{uid}/pipewire-* rw,
      owner /run/user/@{uid}/pulse/ rw,
      owner /run/user/@{uid}/pulse/native rw,
      owner /run/user/@{uid}/bus rw,
      owner /run/user/@{uid}/at-spi/bus* rw,
      owner /run/user/@{uid}/.org.chromium.* rwk,
      owner /run/user/@{uid}/trivalent* rwk,
      owner /run/user/@{uid}/xauth_* r,
      /run/dbus/system_bus_socket rw,

      # --- proc / sys ---
      @{PROC}/ r,
      @{PROC}/@{pid}/** r,
      owner @{PROC}/@{pid}/{oom_score_adj,clear_refs,coredump_filter,comm,loginuid} rw,
      owner @{PROC}/@{pid}/task/@{tid}/comm rw,
      owner @{PROC}/@{pid}/setgroups w,
      owner @{PROC}/@{pid}/{uid_map,gid_map} rw,
      @{PROC}/sys/kernel/{yama/ptrace_scope,seccomp/actions_avail,random/boot_id,cap_last_cap,osrelease,ostype,ngroups_max,overflowuid,overflowgid,pid_max,threads-max,unprivileged_userns_clone} r,
      @{PROC}/sys/vm/{max_map_count,overcommit_memory,mmap_min_addr} r,
      @{PROC}/sys/fs/inotify/max_user_watches r,
      @{PROC}/sys/net/core/somaxconn r,
      /sys/ r,
      /sys/devices/** r,
      /sys/bus/ r,
      /sys/bus/*/devices/ r,
      /sys/class/ r,
      /sys/class/** r,
      /sys/fs/cgroup/** r,
      /sys/kernel/mm/transparent_hugepage/{enabled,hpage_pmd_size} r,
      /sys/kernel/security/apparmor/features/** r,

      # --- tmp ---
      /tmp/ r,
      owner /tmp/** rwkl,
      owner /var/tmp/trivalent*/ rw,
      owner /var/tmp/trivalent*/** rwkl,

      # --- network (a browser) ---
      network inet stream,
      network inet6 stream,
      network inet dgram,
      network inet6 dgram,
      network netlink raw,
      network netlink dgram,
      network unix stream,
      network unix dgram,

      include if exists <local/trivalent>
    }
  '';
in
{
  options.programs.trivalent = {
    enable = lib.mkEnableOption "Trivalent (verified-supply-chain hardened Chromium)";

    package = lib.mkOption {
      # nullOr: `self.packages.<system>.trivalent` is absent on systems the flake
      # doesn't build for (currently non-x86_64) -- keep eval working there and
      # let `config` below no-op, rather than a "expected package, got null".
      type = lib.types.nullOr lib.types.package;
      default = defaultPkg;
      defaultText = lib.literalExpression "trivalent-nix.packages.\${system}.trivalent";
      description = "The Trivalent package to install and confine.";
    };

    apparmor = {
      enable = lib.mkEnableOption ''
        an AppArmor profile confining Trivalent -- a stand-in for the
        `trivalent-selinux` policy that NixOS's store layout cannot run'';

      enforce = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          false: complain mode -- violations are logged, not blocked. Safe to
          deploy; audit with
          `journalctl -k --grep='apparmor.*profile="trivalent"'`, then set true.
          true: enforce mode -- violations are blocked. A missing rule means a
          broken browser (worse with `security.apparmor.killUnconfinedConfinables`).
        '';
      };

      denyHomePaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "@{HOME}/Documents/tax/**" ];
        description = "Extra `@{HOME}`-relative globs the browser must never touch.";
      };

      readableHomePaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "@{HOME}/Sync/shared/**" ];
        description = "Extra `@{HOME}`-relative globs the browser may READ (not write).";
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        # Fail LOUDLY rather than silently installing nothing when there is no
        # package for this host (the flake currently builds x86_64-linux only,
        # so `self.packages.<system>.trivalent` is absent elsewhere -> null).
        assertions = [
          {
            assertion = cfg.package != null;
            message = ''
              programs.trivalent.enable is set but no Trivalent package is
              available for ${system}. trivalent-nix currently builds
              x86_64-linux only. Set programs.trivalent.package explicitly, or
              drop the module on this host.
            '';
          }
        ];
        environment.systemPackages = lib.optional (cfg.package != null) cfg.package;
      }

      (lib.mkIf cfg.apparmor.enable {
        assertions = [
          {
            assertion = config.security.apparmor.enable;
            message = "programs.trivalent.apparmor.enable needs security.apparmor.enable = true.";
          }
        ];
        security.apparmor.policies."trivalent".profile = profile;
        # apparmor.d abstractions the profile includes
        security.apparmor.packages = lib.mkDefault [ pkgs.apparmor-profiles ];
      })
    ]
  );
}
