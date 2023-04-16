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
  };

  outputs = { self, nixpkgs, zig-overlay, zls, ... }@inputs:
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
    in {
      devShells.${system}.default = pkgs.mkShell.override {
        stdenv = oldPkgs.stdenv;
      } { # override stdenv for mkShell call
        buildInputs = [
          zig-overlay.packages.${system}.master
          zls.packages.${system}.default
          oldPkgs.xorg.libX11.dev # we also need Xlib linked against older glibc
        ];
      };
    };
}
