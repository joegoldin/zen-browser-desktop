# Assembles the patched Firefox source tree for the Zen fork (tree-style-tabs).
# Mirrors nixpkgs PR #496647 (Hythera) — drives the Zen `import` steps by hand
# (no `surfer`) so everything runs offline inside the build sandbox.
#
# Fork-specific deltas from the upstream recipe:
#   * Firefox 151.0.3 (from the fork's surfer.json).
#   * `zen-src` is the fork tree itself (`zen-src-tree` = the flake `self`),
#     not a tagged github release — so the tree-style-tabs feature (extra
#     src/ files + new *.patch files) is picked up generically.
#   * Linux-only: the macOS-only external patches are excluded.
{
  branding ? "release",
  fetchurl,
  rsync,
  rustPlatform,
  writeText,
  zen-src-tree,
}:
let
  zen-src = zen-src-tree;

  assets = import ./assets.nix { inherit branding surfer-config writeText; };

  ffprefs = rustPlatform.buildRustPackage {
    cargoHash = "sha256-DZMwxeulQiIiSATU0MoyqiUMA0USZq6umhkr67hZH1Q=";
    pname = "ffprefs";
    postPatch = ''
      substituteInPlace src/main.rs \
        --replace-fail "../engine/" "../"
    '';
    src = "${zen-src}/tools/ffprefs";
    version = zen-version;
  };

  firefox-src = fetchurl {
    url = "mirror://mozilla/firefox/releases/${firefox-version}/source/firefox-${firefox-version}.source.tar.xz";
    hash = "sha512-URcj5c8EKrtmy+2om3jULejRtTVEVlZwFz8+acKnzu/HZGjJBXYiFBi/ybEiFR7BF5eMqkgjz7m4B5fzBkvYlQ==";
  };

  firefox-version = "151.0.3";

  # Hard-coded from the fork's surfer.json (kept in sync manually; these values
  # change very rarely). Drives the branding strings in assets.nix.
  surfer-config = {
    name = "Zen Browser";
    vendor = "Zen OSS Team";
    appId = "zen";
    brands = {
      release = {
        backgroundColor = "#282A33";
        brandShorterName = "Zen";
        brandShortName = "Zen";
        brandFullName = "Zen Browser";
      };
      twilight = {
        backgroundColor = "#282A33";
        brandShorterName = "Zen";
        brandShortName = "Twilight";
        brandFullName = "Zen Twilight";
      };
    };
  };

  zen-version = "1.20.2b";
in
{
  inherit
    ffprefs
    firefox-src
    firefox-version
    zen-version
    ;

  extraNativeBuildInputs = [
    rsync
  ];

  extraPostPatch = ''
    # Compile the Zen pref YAMLs into the engine's static/dynamic pref files.
    # --chmod=u+w: the source is a read-only Nix store path, and plain `rsync -r`
    # would recreate its directories read-only, so the nested mkdir/copy fails
    # ("Permission denied"). Force user-write on everything we copy in.
    rsync -r --chmod=u+w ${zen-src}/prefs/ prefs
    ${ffprefs}/bin/ffprefs .

    # Copy the Zen source overlay in, then apply every Zen *.patch against the
    # Firefox tree (-p1). Skip the two external webrender backports that have
    # already landed upstream in Firefox ${firefox-version} (their added code is
    # verified present in the pristine source, so re-applying fails as
    # "reversed/already applied"). surfer tolerates this upstream; we exclude
    # them explicitly. Re-check this list if the pinned Firefox version changes.
    rsync -r --chmod=u+w --exclude "*.patch" "${zen-src}/src/" .

    find "${zen-src}/src" -type f -name "*.patch" \
      ! -name "bug_2013682_allow_stacking_contexts_to_be_promoted.patch" \
      ! -name "gh-12979_clip_dirty_rect_to_device_size.patch" \
      | sort | while read -r patch_name; do
      patch -p1 --no-backup-if-mismatch < "$patch_name"
    done

    # Locales: en-US plus every supported language (mapped through language-maps).
    rsync -r --chmod=u+w "${zen-src}/locales/en-US/browser/" browser/locales/en-US/
    for language in $(cat ${zen-src}/locales/supported-languages); do
      loc="$(grep -m1 "^$language:" "${zen-src}/locales/language-maps" | cut -d: -f2 || true)"
      loc="''${loc:-$language}"
      rsync -r --chmod=u+w "${zen-src}/locales/$language/." browser/locales/$loc
    done

    # Branding: seed from Firefox's unofficial branding, then overlay Zen's.
    rsync -r --exclude='branding.nsi' browser/branding/unofficial/. browser/branding/${branding}

    cp -r ${zen-src}/configs/branding/${branding} browser/branding
    for size in 16 22 24 32 48 64 128 256 512; do
      cp ${zen-src}/configs/branding/${branding}/logo"$size".png browser/branding/${branding}/default"$size".png
    done

    rsync ${assets.brandDtd} browser/branding/${branding}/locales/en-US/brand.dtd
    rsync ${assets.brandFtl} browser/branding/${branding}/locales/en-US/brand.ftl
    rsync ${assets.brandProperties} browser/branding/${branding}/locales/en-US/brand.properties
    rsync ${assets.brandingNsi} browser/branding/${branding}/branding.nsi
    rsync ${assets.configureSh} browser/branding/${branding}/configure.sh
    rsync ${assets.firefox-brandingJs} browser/branding/${branding}/pref/firefox-branding.js

    find "browser/branding/${branding}" -type f -name "*.css" | while read -r style; do
      echo ":root { --theme-bg: ${surfer-config.brands.${branding}.backgroundColor} }" >> $style
      sed -i -E 's/#130829|hsla\(235, 43%, 10%, 0\.5\)/var(--theme-bg)/g' $style
    done

    # Point the in-app updater at Zen's update host (no-op for us: updates are
    # policy-disabled, so warn-don't-fail if the upstream string drifts).
    substituteInPlace build/application.ini.in \
      --replace-warn 'URL=https://@MOZ_APPUPDATE_HOST@/update/6/%PRODUCT%/%VERSION%/%BUILD_ID%/%BUILD_TARGET%/%LOCALE%/%CHANNEL%/%OS_VERSION%/%SYSTEM_CAPABILITIES%/%DISTRIBUTION%/%DISTRIBUTION_VERSION%/update.xml' 'URL=https://@MOZ_APPUPDATE_HOST@/updates/browser/%BUILD_TARGET%/%CHANNEL%/update.xml'

    substituteInPlace browser/installer/windows/nsis/shared.nsh \
      --replace-warn '"Publisher" "Mozilla"' '"Publisher" "${surfer-config.vendor}"'

    # Merge the vendored remote-settings dumps into the engine offline. Copy the
    # scripts out of the read-only store, then rewrite the two folder constants
    # (the source folder -> the vendored configs/dumps; the engine folder ->
    # relative, since we are already at the Firefox source root).
    scripts="$(mktemp -d)"
    cp -r "${zen-src}/scripts/." "$scripts"
    sed -i '9,15c\
    DUMPS_FOLDER = "${zen-src}/configs/dumps"\
    ENGINE_DUMPS_FOLDER = "services/settings/dumps/main"' $scripts/update_service_dumps.py

    python $scripts/update_service_dumps.py

    for file in browser/config/version.txt browser/config/version_display.txt; do
      echo "${zen-version}" > $file
    done
  '';
}
