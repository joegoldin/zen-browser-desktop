# The stages of the per-directory build. Each is an override of the monolithic
# buildMozillaMach derivation, so every stage has its exact toolchain, inputs
# and environment. ./default.nix uses these at eval time and ./nodes.nix at
# build time; both must produce identical derivations, so nothing here may
# depend on anything but its arguments.
{ lib, zen }:
let
  # The patched Firefox tree: buildMozillaMach's unpack and patch, nothing
  # else. Every later stage uses it in place, read-only.
  source = zen.overrideAttrs (old: {
    pname = "${old.pname}-source";
    outputs = [ "out" ];
    separateDebugInfo = false;
    phases = [
      "unpackPhase"
      "patchPhase"
      "installPhase"
    ];
    installPhase = "cp -r . $out";
  });

  # Runs mach from the read-only source with the objdir at a fixed path
  # outside it, so the absolute paths configure records hold in every stage.
  # With a profile, its files go where buildMozillaMach's preConfigure looks
  # for them: configure switches to --enable-profile-use, and every compile
  # reads the profile through the path configure recorded.
  stage =
    {
      name,
      profile ? null,
      keepInstall ? false,
    }:
    attrs:
    zen.overrideAttrs (
      old:
      {
        pname = "${old.pname}-${name}";
        preConfigurePhases = [ ];
        dontUnpack = true;
        dontPatch = true;
        preConfigure = ''
          cd ${source}
          export PYTHONDONTWRITEBYTECODE=1
        ''
        + lib.optionalString (profile != null) ''
          cp ${profile}/merged.profdata ${profile}/jarlog $TMPDIR/
        ''
        + old.preConfigure
        + ''
          export MOZ_OBJDIR=$NIX_BUILD_TOP/objdir
        '';
      }
      # Intermediate stages produce one plain output; only the final stage
      # keeps buildMozillaMach's outputs, install, fixup and checks.
      // lib.optionalAttrs (!keepInstall) {
        outputs = [ "out" ];
        separateDebugInfo = false;
        dontFixup = true;
        doInstallCheck = false;
      }
      // attrs old
    );

  # Rebuilds the objdir from the configured snapshot and the outputs of
  # earlier groups, in dependency order. Everything copied keeps the store's
  # constant mtime, so make treats all of it as up to date. mach's state
  # directory comes back too: generated-file rules run their Python through
  # the virtualenv configure created there.
  assemble = configured: layers: ''
    runHook preConfigure
    rsync -a --chmod=u+w ${configured}/mozbuild/ $MOZBUILD_STATE_PATH/
    for layer in ${configured}/objdir ${lib.concatStringsSep " " layers}; do
      rsync -a --chmod=u+w "$layer/" $MOZ_OBJDIR/
    done
  '';

  # The tiers after compile, one make each, as `mach build` runs them. Given
  # together, make -j would run them concurrently, and libs needs files that
  # only misc generates.
  remainingTiers = ''
    for tier in misc libs tools; do
      make -C $MOZ_OBJDIR -j$NIX_BUILD_CORES $tier
    done
  '';
in
{
  inherit source;

  # configure and the export tier, plus the compile tier's graph.
  configured =
    {
      profile ? null,
      chunkSize,
    }:
    stage
      {
        name = "configured";
        inherit profile;
      }
      (_: {
        buildPhase = ''
          make -C $MOZ_OBJDIR -j$NIX_BUILD_CORES pre-export export
          python3 ${./graph.py} $MOZ_OBJDIR ${toString chunkSize} > $NIX_BUILD_TOP/graph.json
        '';
        installPhase = ''
          mkdir -p $out
          cp -a $MOZ_OBJDIR $out/objdir
          cp -a $MOZBUILD_STATE_PATH $out/mozbuild
          cp $NIX_BUILD_TOP/graph.json $out/
        '';
      });

  # One group of compile-tier targets. Its output is every file the build
  # wrote, laid out relative to the objdir.
  group =
    {
      name,
      targets,
      configured,
      layers,
      profile ? null,
    }:
    stage
      {
        name = "group-${name}";
        inherit profile;
      }
      (_: {
        configurePhase = assemble configured layers + ''
          touch $NIX_BUILD_TOP/assembled
          # timestamp resolution: everything the build writes changes after this
          sleep 1
        '';
        buildPhase = ''
          make -C $MOZ_OBJDIR -j$NIX_BUILD_CORES ${lib.escapeShellArgs targets}
        '';
        # By ctime, not mtime: the build backdates some files with touch -t
        # (every .deps/.mkdir.done is set to 1980), and a later group missing a
        # .mkdir.done treats every object in that directory as stale.
        installPhase = ''
          mkdir -p $out
          cd $MOZ_OBJDIR
          find . -cnewer $NIX_BUILD_TOP/assembled ! -type d -print0 \
            | tar --null -cf - -T - | tar -xf - -C $out
        '';
      });

  # The rest of the instrumented build, then buildMozillaMach's profiling
  # run. profileserver.py writes its profiles to the working directory, which
  # here cannot be the read-only source.
  profile =
    {
      configured,
      layers,
    }:
    stage { name = "profile"; } (_: {
      configurePhase = assemble configured layers;
      buildPhase = ''
        ${remainingTiers}

        export MOZ_PKG_FORMAT=TAR
        ${source}/mach package

        mkdir $NIX_BUILD_TOP/pgo
        cd $NIX_BUILD_TOP/pgo
        HOME=$TMPDIR LLVM_PROFDATA=llvm-profdata JARLOG_FILE=$PWD/jarlog \
          xvfb-run -w 10 -s "-screen 0 1920x1080x24" \
          ${source}/mach python ${source}/build/pgo/profileserver.py
      '';
      installPhase = ''
        mkdir -p $out
        cp merged.profdata jarlog $out/
      '';
    });

  # The rest of the build, then buildMozillaMach's own install, fixup and
  # install check. configure recorded the configured stage's $out as the
  # prefix, so install is pointed at this derivation's instead.
  final =
    {
      configured,
      layers,
      profile ? null,
    }:
    stage
      {
        name = "final";
        inherit profile;
        keepInstall = true;
      }
      (old: {
        pname = old.pname;
        configurePhase = assemble configured layers;
        buildPhase = ''
          ${remainingTiers}
          # buildMozillaMach's preInstall enters ./objdir
          cd $NIX_BUILD_TOP
        '';
        installFlags = (old.installFlags or [ ]) ++ [
          "prefix=${placeholder "out"}"
          "exec_prefix=${placeholder "out"}"
          "bindir=${placeholder "out"}/bin"
          "libdir=${placeholder "out"}/lib"
          "includedir=${placeholder "out"}/include"
          "datadir=${placeholder "out"}/share"
          "mandir=${placeholder "out"}/share/man"
        ];
      });
}
