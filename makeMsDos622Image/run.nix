{ writeShellScriptBin
, writeText
, lib
, dosbox-x
, makeMsDos622Image
, extraDosboxFlags ? []
, diskImage ? (makeMsDos622Image {})
}:
let
  dosboxConf = writeText "dosbox.conf" ''
    [sdl]
    autolock = true

    [autoexec]
    imgmount 2 msdos622.img -fs none
    boot -l c
  '';
in
writeShellScriptBin "run-msdos622.sh" ''
  # jack/pipewire, ugh..
  unset LD_LIBRARY_PATH
  args=(
    -conf ${dosboxConf}
    ${lib.concatStringsSep " " extraDosboxFlags}
    "$@"
  )

  if [ ! -f msdos622.img ]; then
    echo "msdos622.img not found, making disk image ./msdos622.img"
    # Avoid `cp --no-preserve=mode` (GNU-only): `cp` then `chmod` works on
    # both GNU coreutils (Linux) and BSD cp (macOS). The Nix store source is
    # mode 0444, so we need to make the local copy writable for dosbox-x.
    # Fail fast on cp/chmod errors so dosbox-x doesn't boot a partial image.
    cp ${diskImage} ./msdos622.img && \
      chmod u+w ./msdos622.img || {
        echo "Failed to prepare ./msdos622.img" >&2
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
