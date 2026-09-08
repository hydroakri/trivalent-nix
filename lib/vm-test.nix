# Hermetic VM check for F5 -- the runtime sandbox self-check as a nixosTest.
# NOT wired into `checks` (it boots a QEMU VM and needs /dev/kvm). Run it
# explicitly:  nix build .#sandbox-vm-test  (or on a bump you care about).
#
# It boots a real kernel, serves a page locally, launches the FHS-wrapped
# browser as a non-root user, and asserts -- via strace -- the renderer/zygote
# creates an unprivileged user namespace + installs a seccomp-bpf filter and
# never execs a setuid chrome-sandbox, and that the page renders.
#
# The VM kernel is nixpkgs' generic kernel, not any specific host's -- this is a
# regression gate, not a substitute for `verify/30-sandbox-selfcheck.sh` on the
# actual machine.
{
  pkgs,
  self,
}:
pkgs.testers.runNixOSTest {
  name = "trivalent-sandbox";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ self.nixosModules.default ];
      programs.trivalent.enable = true;
      # security.apparmor.enable is left at its default (false), so the module
      # contributes no profile -- this test is about the sandbox, not AppArmor.

      users.users.tester = {
        isNormalUser = true;
        uid = 1000;
      };

      services.nginx = {
        enable = true;
        virtualHosts."localhost".locations."/".return =
          "200 '<html><body><h1 id=marker>trivalent-vm-ok</h1></body></html>'";
      };

      environment.systemPackages = [ pkgs.strace ];
      virtualisation.diskSize = 4096;
      virtualisation.memorySize = 3072;
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("nginx.service")
    machine.succeed("curl -sf http://localhost/ | grep -q trivalent-vm-ok")

    common = (
        "--headless=new --no-first-run --no-default-browser-check --disable-gpu "
        "--user-data-dir=/tmp/prof --virtual-time-budget=8000"
    )

    # render a real (local) page
    dom = machine.succeed(
        f"su - tester -c 'trivalent {common} --dump-dom http://localhost/'"
    )
    assert "trivalent-vm-ok" in dom, "page did not render inside the VM"

    # strace the launch; inspect the sandbox syscalls
    machine.succeed(
        "su - tester -c '"
        "strace -f -qq -e trace=unshare,clone,clone3,setuid,seccomp,prctl,execve "
        f"-o /tmp/trace.log trivalent {common} --dump-dom http://localhost/ >/dev/null'"
    )
    trace = machine.succeed("cat /tmp/trace.log")

    assert "CLONE_NEWUSER" in trace, "no unprivileged user namespace in the renderer/zygote"
    assert (
        "seccomp(SECCOMP_SET_MODE_FILTER" in trace
        or "prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER" in trace
    ), "no seccomp-bpf filter installed"
    assert "chrome-sandbox" not in trace, "a setuid chrome-sandbox was exec'd"
    assert "--no-sandbox" not in trace, "--no-sandbox in effect"

    machine.copy_from_machine("/tmp/trace.log", "trace.log")
  '';
}
