{
  description = "Pinshift development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { nixpkgs, ... }:
    let
      system = "aarch64-darwin";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      devShells.${system}.default = pkgs.mkShellNoCC {
        shellHook = ''
          if [ -x "$PWD/bin/pinshift" ]; then
            export PATH="$PWD/bin:$PATH"
          fi
        '';
        packages = with pkgs; [
          fish
          jq
          xcodegen
        ];
      };
    };
}
