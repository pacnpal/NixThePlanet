{
  # Optional binary-cache hint. With `accept-flake-config = true` in
  # nix.conf (or `--accept-flake-config` on the command line, or your
  # user listed in `trusted-users`), Nix will pull prebuilt .img
  # outputs from this Cachix cache instead of building them locally.
  # If the cache is unreachable or the user does not opt in, Nix
  # prints a warning and falls back to a local build (or your
  # linux-builder VM).
  #
  # Maintainer note: `extra-trusted-public-keys` is intentionally
  # omitted until the `nixtheplanet` cache exists and a real Cachix
  # public key can be recorded here. Until then, opting into the flake
  # config only adds the substituter URL and Nix falls back to a local
  # build if it cannot trust the cache.
  nixConfig = {
    extra-substituters = [
      "https://nixtheplanet.cachix.org"
    ];
  };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    hercules-ci-effects.url = "github:hercules-ci/hercules-ci-effects";
    osx-kvm = {
      url = "github:kholia/OSX-KVM";
      flake = false;
    };
  };
  outputs = inputs@{ flake-parts, osx-kvm, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        flake-parts.flakeModules.easyOverlay
#        ./effects/macos-repeatability-test
      ];
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      flake = {
        packages.aarch64-linux.macos-ventura-image = throw "QEMU TCG doesn't emulate certain CPU features needed for MacOS x86 to boot, unsupported";
        nixosModules = {
          macos-ventura = { ... }: {
            imports = [ ./makeDarwinImage/module.nix ];
            nixpkgs.overlays = [
              (self: super: {
                inherit (inputs.self.legacyPackages.${super.stdenv.hostPlatform.system}) makeDarwinImage;
                inherit (inputs.self.packages.${super.stdenv.hostPlatform.system}) macos-ventura-image;
              })
            ];
          };
        };
      };
      perSystem = { config, pkgs, lib, system, ... }:
        let
          # Derive isDarwin from `system` (a plain string), not from
          # pkgs.stdenv — pkgs depends on the overlay, the overlay depends
          # on legacyPackages, and legacyPackages branches on isDarwin.
          # Using pkgs here would close that loop and stack-overflow.
          isDarwin = lib.hasSuffix "-darwin" system;
          # Image-build derivations rely on Linux-only tooling
          # (xvfb-run, x11vnc, expect-driven VNC + tesseract OCR). On
          # darwin we construct them from a matching-arch Linux nixpkgs so
          # they have system = {aarch64,x86_64}-linux and Nix offloads the
          # build to a Linux remote builder. Matching the host arch lets
          # darwin.linux-builder accelerate the VM via HVF instead of TCG.
          # The runScript still uses native darwin dosbox-x.
          linuxBuildSystem =
            if lib.hasPrefix "aarch64-" system then "aarch64-linux"
            else "x86_64-linux";
          imagePkgs =
            if isDarwin
            then import inputs.nixpkgs { system = linuxBuildSystem; }
            else pkgs;
          withNativeRunScript = subdir: image:
            if isDarwin
            then image.overrideAttrs (old: {
              passthru = (old.passthru or { }) // (
                let
                  # `makeRunScript` is the documented public API
                  # (README: `(makeWin30Image {}).makeRunScript { diskImage = ...; }`)
                  # — a function that takes overrides and returns the
                  # runner derivation. `runScript` is `makeRunScript {}`.
                  # The image-side `passthru.makeRunScript` resolves
                  # `callPackage` against `imagePkgs` (the Linux nixpkgs
                  # we use to build the .img on a remote builder), so its
                  # `dosbox-x` etc. would be Linux-typed. Override both
                  # entrypoints with `pkgs.callPackage` (darwin nixpkgs)
                  # and a darwin-built default `diskImage` so the
                  # generated runners actually execute natively on macOS.
                  makeRunScript = args: pkgs.callPackage (./. + "/${subdir}/run.nix") ({
                    diskImage = image;
                  } // args);
                in {
                  inherit makeRunScript;
                  runScript = makeRunScript {};
                }
              );
            })
            else image;
          genOverridenDrvList = drv: howMany: builtins.genList (x: drv.overrideAttrs { name = drv.name + "-" + toString x; }) howMany;
          genOverridenDrvLinkFarm = drv: howMany: pkgs.linkFarm (drv.name + "-linkfarm-${toString howMany}") (builtins.genList (x: rec { name = toString x + "-" + drv.name; path = drv.overrideAttrs { inherit name; }; }) howMany);
        in
      {
        _module.args.pkgs = import inputs.nixpkgs {
          overlays = [
            inputs.self.overlays.default
          ];
          inherit system;
        };
        overlayAttrs = config.legacyPackages;
        legacyPackages = let
          # Raw image-builder functions, callPackage'd against imagePkgs
          # (Linux nixpkgs on darwin so the build offloads to a Linux remote).
          rawImageFns = rec {
            makeMsDos622Image = imagePkgs.callPackage ./makeMsDos622Image {};
            makeWin30Image = imagePkgs.callPackage ./makeWin30Image {
              inherit makeMsDos622Image;
            };
            makeWfwg311Image = imagePkgs.callPackage ./makeWfwg311Image {
              inherit makeMsDos622Image;
            };
            makeWin98Image = imagePkgs.callPackage ./makeWin98Image {};
#            makeSystem7Image = imagePkgs.callPackage ./makeSystem7Image {};
          };
          # On darwin, wrap each function so its returned image's
          # passthru.runScript / passthru.makeRunScript use native darwin
          # dosbox-x. This makes the public API
          # `(legacyPackages.makeWin30Image {}).makeRunScript { ... }` produce
          # native runners on macOS, not Linux ones.
          imageFns =
            if isDarwin
            then lib.mapAttrs (name: fn: args: withNativeRunScript name (fn args)) rawImageFns
            else rawImageFns;
        in {
          inherit osx-kvm;
        } // imageFns // lib.optionalAttrs (!isDarwin) {
          makeDarwinImage = pkgs.callPackage ./makeDarwinImage {
            # substitute relative input with absolute input
            qemu_kvm = pkgs.qemu_kvm.overrideAttrs {
              prePatch = ''
                substituteInPlace ui/ui-hmp-cmds.c --replace "qemu_input_queue_rel(NULL, INPUT_AXIS_X, dx);" "qemu_input_queue_abs(NULL, INPUT_AXIS_X, dx, 0, 1920);"
                substituteInPlace ui/ui-hmp-cmds.c --replace "qemu_input_queue_rel(NULL, INPUT_AXIS_Y, dy);" "qemu_input_queue_abs(NULL, INPUT_AXIS_Y, dy, 0, 1080);"
              '';
            };
          };
        };
        apps = {
          msdos622 = {
            type = "app";
            program = config.packages.msdos622-image.runScript;
          };
          win30 = {
            type = "app";
            program = config.packages.win30-image.runScript;
          };
          wfwg311 = {
            type = "app";
            program = config.packages.wfwg311-image.runScript;
          };
          win98 = {
            type = "app";
            program = config.packages.win98-image.runScript;
          };
        } // lib.optionalAttrs (!isDarwin) {
          macos-ventura = {
            type = "app";
            program = config.packages.macos-ventura-image.runScript;
          };
        };
        packages = let
          # legacyPackages.make*Image is already darwin-aware on darwin
          # (wrapped via withNativeRunScript), so calling it directly
          # produces an image with native runScript / makeRunScript.
          msdos622-image = config.legacyPackages.makeMsDos622Image {};
          win30-image = config.legacyPackages.makeWin30Image {};
          wfwg311-image = config.legacyPackages.makeWfwg311Image {};
          win98-image = config.legacyPackages.makeWin98Image {};
        in {
          inherit msdos622-image win30-image wfwg311-image win98-image;
          #system7-image = config.legacyPackages.makeSystem7Image {};
        } // lib.optionalAttrs (!isDarwin) {
          macos-ventura-image = config.legacyPackages.makeDarwinImage {};
          #macos-repeatability-test = genOverridenDrvLinkFarm (macos-ventura-image.overrideAttrs { repeatabilityTest = true; }) 3;
          win98-repeatability-test = genOverridenDrvLinkFarm win98-image 100;
          wfwg311-repeatability-test = genOverridenDrvLinkFarm wfwg311-image 100;
          win30-repeatability-test = genOverridenDrvLinkFarm win30-image 100;
          msDos622-repeatability-test = genOverridenDrvLinkFarm msdos622-image 100;
        };
        checks = lib.optionalAttrs (!isDarwin) {
          macos-ventura = pkgs.callPackage ./makeDarwinImage/vm-test.nix { nixosModule = inputs.self.nixosModules.macos-ventura; };
        };
      };
    };
}
