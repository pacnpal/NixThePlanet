{ writeShellScriptBin
, writeText
, lib
, dosbox-x
, makeWin30Image
, extraDosboxFlags ? []
, diskImage ? makeWin30Image {
    dosPostInstall = ''
      c:
      echo win >> AUTOEXEC.BAT
    '';
  }
}:
let
  dosboxConf = writeText "dosbox.conf" ''
    [sdl]
    autolock = true

    [autoexec]
    imgmount C win30.img
    boot -l C
  '';
in
writeShellScriptBin "run-win30.sh" ''
  args=(
    -conf ${dosboxConf}
    ${lib.concatStringsSep " " extraDosboxFlags}
    "$@"
  )

  if [ ! -f win30.img ]; then
    echo "win30.img not found, making disk image ./win30.img"
    # Avoid `cp --no-preserve=mode` (GNU-only): `cp` then `chmod` works on
    # both GNU coreutils (Linux) and BSD cp (macOS). The Nix store source is
    # mode 0444, so we need to make the local copy writable for dosbox-x.
    # Fail fast on cp/chmod errors so dosbox-x doesn't boot a partial image.
    cp ${diskImage} ./win30.img && \
      chmod u+w ./win30.img || {
        echo "Failed to prepare ./win30.img" >&2
        exit 1
      }
  fi

  run_dosbox() {
    ${dosbox-x}/bin/dosbox-x "''${args[@]}"
  }

  run_dosbox

  if [ $? -ne 0 ]; then
    echo "Dosbox crashed. Re-running with SDL_VIDEODRIVER=x11."
    SDL_VIDEODRIVER=x11 run_dosbox
  fi
''

