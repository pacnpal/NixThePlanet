{ writeShellScriptBin
, writeText
, lib
, dosbox-x
, makeWfwg311Image
, extraDosboxFlags ? []
, diskImage ? makeWfwg311Image {
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
    imgmount C wfwg311.img
    boot -l C
  '';
in
writeShellScriptBin "run-wfwg311.sh" ''
  args=(
    -conf ${dosboxConf}
    ${lib.concatStringsSep " " extraDosboxFlags}
    "$@"
  )

  if [ ! -f wfwg311.img ]; then
    echo "wfwg311.img not found, making disk image ./wfwg311.img"
    # Avoid `cp --no-preserve=mode` (GNU-only): `cp` then `chmod` works on
    # both GNU coreutils (Linux) and BSD cp (macOS). The Nix store source is
    # mode 0444, so we need to make the local copy writable for dosbox-x.
    # Fail fast on cp/chmod errors so dosbox-x doesn't boot a partial image.
    cp ${diskImage} ./wfwg311.img && \
      chmod u+w ./wfwg311.img || {
        echo "Failed to prepare ./wfwg311.img" >&2
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

