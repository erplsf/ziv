{
  description = "Zig development environment";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    zls = {
      url = "github:zigtools/zls";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.zig-overlay.follows = "zig-overlay";
    };

    # needed for shell shim: see NixOS Flakes wiki page
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };

    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, zig-overlay, zls, flake-utils, ... }@inputs:
    let
      system = "x86_64-linux";

      # HACK: fetch nixpkgs with glibc 2.35-224m until Zig starts supporting new libc (https://github.com/ziglang/zig/pull/15309 is merged)
      # TODO: figure out how to trick Zig to use system (packaged) libc
      oldPkgs = import (pkgs.fetchFromGitHub {
        owner = "NixOS";
        repo = "nixpkgs";
        rev = "8ad5e8132c5dcf977e308e7bf5517cc6cc0bf7d8";
        sha256 = "sha256-0gI2FHID8XYD3504kLFRLH3C2GmMCzVMC50APV/kZp8=";
      }) { inherit system; };

      pkgs = import nixpkgs { inherit system; };

      buildInputs = [
        zig-overlay.packages.${system}.master
        oldPkgs.xorg.libX11.dev # we also need Xlib linked against older glibc
      ];
    in {
      devShells.${system}.default = pkgs.mkShell.override {
        stdenv = oldPkgs.stdenv;
      } { # override stdenv for mkShell call
        buildInputs = buildInputs ++ [ zls.packages.${system}.default ];
      };
      defaultPackage.${system} = pkgs.stdenv.mkDerivation {
        pname = "ziv";
        version = "master";
        src = ./.;

        hardeningDisable = [ "all" ];

        nativeBuildInputs = buildInputs ++ [ pkgs.autoPatchelfHook ];

        dontConfigure = true;
        dontInstall = true;

        buildPhase = ''
          mkdir -p $out
          mkdir -p .cache/
          zig build --cache-dir $(pwd)/zig-cache --global-cache-dir $(pwd)/.cache -Dcpu=baseline -Doptimize=ReleaseSafe --prefix $out
        '';
      };
      defaultApp = flake-utils.lib.mkApp {
        drv =
          self.defaultPackage."${system}".override { stdenv = oldPkgs.stdenv; };
      };
    };
}
