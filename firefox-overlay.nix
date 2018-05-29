# This file provide the latest binary versions of Firefox published by Mozilla.
self: super:

# firefo.key file is downloaded from:
# https://gpg.mozilla.org/pks/lookup?search=Mozilla+Software+Releases+%3Crelease%40mozilla.com%3E&op=get

let
  # This file is currently maintained manually, if this Nix expression attempt
  # to download the wrong version, this is likely to be the problem.
  #
  # Open a pull request against https://github.com/mozilla-releng/ship-it/ to
  # update the version, as done in
  # https://github.com/mozilla-releng/ship-it/pull/182
  firefox_versions = with builtins;
    fromJSON (readFile (fetchurl https://product-details.mozilla.org/1.0/firefox_versions.json));

  arch = if self.stdenv.system == "i686-linux"
    then "linux-i686"
    else "linux-x86_64";

  yearOf = with super.lib; yyyymmddhhmmss:
    head (splitString "-" yyyymmddhhmmss);
  monthOf = with super.lib; yyyymmddhhmmss:
    head (tail (splitString "-" yyyymmddhhmmss));

  # Given SHA512SUMS file contents and file name, extract matching sha512sum.
  extractSha512Sum = sha512sums: file:
    with builtins;
    # Nix 1.x do not have `builtins.split`.
    # Nix 2.0 have an bug in `builtins.match` (see https://github.com/NixOS/nix/issues/2147).
    # So I made separate logic for Nix 1.x and Nix 2.0.
    if builtins ? split then
      substring 0 128 (head
        (super.lib.filter
          (s: isString s && substring 128 (stringLength s) s == "  ${file}")
          (split "\n" sha512sums)))
    else
      head (match ".*[\n]([0-9a-f]*)  ${file}.*" sha512sums);

  # The timestamp argument is a yyyy-mm-dd-hh-mm-ss date, which corresponds to
  # one specific version. This is used mostly for bisecting.
  versionInfo = { name, version, release, system ? arch, timestamp ? null }: with builtins;
    if release then
      # For versions such as Beta & Release:
      # http://download.cdn.mozilla.net/pub/firefox/releases/55.0b3/SHA256SUMS
      let
        dir = "http://download.cdn.mozilla.net/pub/firefox/releases/${version}";
        file = "${system}/en-US/firefox-${version}.tar.bz2";
      in rec {
        chksum = "${dir}/SHA512SUMS";
        chksumSig = "${chksum}.asc";
        url = "${dir}/${file}";
        sha512 = extractSha512Sum (readFile (fetchurl chksum)) file;
      }
    else
      # For Nightly versions:
      # http://download.cdn.mozilla.net/pub/firefox/nightly/latest-mozilla-central/firefox-56.0a1.en-US.linux-x86_64.checksums
      let
        dir =
          if timestamp == null then "http://download.cdn.mozilla.net/pub/firefox/nightly/latest-mozilla-central"
          else "http://download.cdn.mozilla.net/pub/firefox/nightly/${yearOf timestamp}/${monthOf timestamp}/${timestamp}-mozilla-central" ;
        file = "firefox-${version}.en-US.${system}.tar.bz2";
      in rec {
        chksum = "${dir}/firefox-${version}.en-US.${system}.checksums";
        chksumSig = "${chksum}.asc";
        # file content:
        # <hash> sha512 62733881 firefox-56.0a1.en-US.linux-x86_64.tar.bz2
        # <hash> sha256 62733881 firefox-56.0a1.en-US.linux-x86_64.tar.bz2
        url = "${dir}/${file}";
        sha512 = head (match ".*[\n]([0-9a-f]*) sha512 [0-9]* ${file}[\n].*" (readFile (fetchurl chksum)));
      };

  # From the version info, check the authenticity of the check sum file, such
  # that we guarantee that we have
  verifyAuthenticity = info:
    super.runCommandNoCC "check-firefox-signature" {
      buildInputs = [ self.gnupg ];
      CHKSUM_FILE = builtins.fetchurl info.chksum;
      CHKSUM_ASC = builtins.fetchurl info.chksumSig;
    } ''
      HOME=`mktemp -d`
      set -eux
      cat ${./firefox.key} | gpg --import
      gpgv --keyring=$HOME/.gnupg/pubring.kbx $CHKSUM_ASC $CHKSUM_FILE
      mkdir $out
    '';

  # From the version info, create a fetchurl derivation which will get the
  # sources from the remote.
  fetchVersion = info:
    super.fetchurl {
      inherit (info) url sha512;

      # This is a fixed derivation, but we still add as a dependency the
      # verification of the checksum.  Thus, this fetch script can only be
      # executed once the verifyAuthenticity script finished successfully.
      postFetch = ''
        : # Authenticity Check (${verifyAuthenticity info})
      '';
  };

  firefoxVersion = version:
    let info = versionInfo version; in
    super.wrapFirefox ((self.firefox-bin-unwrapped.override {
      generated = {
        version = version.version;
        sources = { inherit (info) url sha512; };
      };
    }).overrideAttrs (old: {
      # Add a dependency on the signature check.
      src = fetchVersion info;
    })) {
      browserName = "firefox";
      name = "firefox-bin-${version.version}";
      desktopName = "Firefox";
    };
in

{
  lib = super.lib // {
    firefoxOverlay = {
      inherit firefoxVersion;
    };
  };

  # Set of packages which are automagically updated. Do not rely on these for
  # reproducible builds.
  latest = (super.latest or {}) // {
    firefox-nightly-bin = firefoxVersion {
      name = "Firefox Nightly";
      version = firefox_versions.FIREFOX_NIGHTLY;
      release = false;
    };
    firefox-beta-bin = firefoxVersion {
      name = "Firefox Beta";
      version = firefox_versions.LATEST_FIREFOX_DEVEL_VERSION;
      release = true;
    };
    firefox-bin = firefoxVersion {
      name = "Firefox";
      version = firefox_versions.LATEST_FIREFOX_VERSION;
      release = true;
    };
    firefox-esr-bin = firefoxVersion {
      name = "Firefox Esr";
      version = firefox_versions.FIREFOX_ESR;
      release = true;
    };
  };

  # Set of packages which used to build developer environment
  devEnv = (super.shell or {}) // {
    gecko = super.callPackage ./pkgs/gecko {
      inherit (self.python35Packages) setuptools;
      pythonFull = self.python35Full;

      # Due to std::ascii::AsciiExt changes in 1.23, Gecko does not compile, so
      # use the latest Rust version before 1.23.
      # rust = (super.rustChannelOf { channel = "stable"; date = "2017-11-22"; }).rust;
      inherit (self.latest.rustChannels.stable) rust;
    };
  };

  # Set of packages which are frozen at this given revision of nixpkgs-mozilla.
  firefox-nightly-bin = super.callPackage ./pkgs/firefox-nightly-bin/default.nix { };
}
