{
  config,
  lib,
  flake-parts-lib,
  ...
}: let
  inherit (lib) mkOption mkPackageOption types;
  inherit (flake-parts-lib) mkPerSystemOption;

  cfg = config.agenix-shell;

  secretType = types.submodule ({config, ...}: {
    options = {
      name = mkOption {
        default = config._module.args.name;
        description = "Name of the variable containing the secret.";
        defaultText = lib.literalExpression "<name>";
      };

      namePath = mkOption {
        default = "${config._module.args.name}_PATH";
        description = "Name of the variable containing the path to the secret.";
        defaultText = lib.literalExpression "<name>_PATH";
      };

      file = mkOption {
        type = types.path;
        description = "Age file the secret is loaded from.";
      };

      path = mkOption {
        type = types.str;
        default = "${cfg.secretsPath}/${config.name}";
        description = "Path where the decrypted secret is installed.";
        defaultText = lib.literalExpression ''"''${config.agenix-shell.secretsPath}/<name>"'';
      };

      mode = mkOption {
        type = types.str;
        default = "0400";
        description = "Permissions mode of the decrypted secret in a format understood by chmod.";
      };
    };
  });
in {
  options.agenix-shell = {
    secrets = mkOption {
      type = types.attrsOf secretType;
      description = "Attrset of secrets.";
      example = lib.literalExpression ''
        {
          foo.file = "secrets/foo.age";
          bar = {
            file = "secrets/bar.age";
            mode = "0440";
          };
        }
      '';
    };

    flakeName = mkOption {
      type = types.str;
      default = "git rev-parse --show-toplevel | xargs basename";
      description = "Command returning the name of the flake, used as part of the secrets path.";
    };

    secretsPath = mkOption {
      type = types.str;
      default = ''/run/user/$(id -u)/agenix-shell/$(${cfg.flakeName})/$(uuidgen)'';
      defaultText = lib.literalExpression ''"/run/user/$(id -u)/agenix-shell/$(''${config.agenix-shell.flakeName})/$(uuidgen)"'';
      description = "Where the secrets are stored.";
    };

    identityPaths = mkOption {
      type = types.listOf types.str;
      default = [
        "$HOME/.ssh/id_ed25519"
        "$HOME/.ssh/id_rsa"
      ];
      description = ''
        Path to SSH keys to be used as identities in age decryption.
      '';
    };
  };

  options.perSystem = mkPerSystemOption ({
    config,
    pkgs,
    ...
  }: {
    options.agenix-shell = {
      agePackage = mkPackageOption pkgs "age" {
        default = "rage";
      };

      _installSecrets = mkOption {
        type = types.str;
        internal = true;
        default =
          ''
            # shellcheck disable=SC2086
            rm -rf "${cfg.secretsPath}"

            IDENTITIES=()
            # shellcheck disable=2043
            for identity in ${builtins.toString cfg.identityPaths}; do
              test -r "$identity" || continue
              IDENTITIES+=(-i)
              IDENTITIES+=("$identity")
            done

            test "''${#IDENTITIES[@]}" -eq 0 && echo "[agenix] WARNING: no readable identities found!"

            mkdir -p "${cfg.secretsPath}"
          ''
          + lib.concatStrings (lib.mapAttrsToList (_: config.agenix-shell._installSecret) cfg.secrets);
      };

      _installSecret = mkOption {
        type = types.functionTo types.str;
        internal = true;
        default = secret: ''
          SECRET_PATH=${secret.path}

          # shellcheck disable=SC2193
          [ "$SECRET_PATH" != "${cfg.secretsPath}/${secret.name}" ] && mkdir -p "$(dirname "$SECRET_PATH")"
          (
            umask u=r,g=,o=
            test -f "${secret.file}" || echo '[agenix] WARNING: encrypted file ${secret.file} does not exist!'
            test -d "$(dirname "$SECRET_PATH")" || echo "[agenix] WARNING: $(dirname "$SECRET_PATH") does not exist!"
            LANG=${config.i18n.defaultLocale or "C"} ${lib.getExe config.agenix-shell.agePackage} --decrypt "''${IDENTITIES[@]}" -o "$SECRET_PATH" "${secret.file}"
          )

          chmod ${secret.mode} "$SECRET_PATH"

          ${secret.name}=$(cat "$SECRET_PATH")
          ${secret.namePath}="$SECRET_PATH"
          export ${secret.name}
          export ${secret.namePath}
        '';
      };

      installationScript = mkOption {
        type = types.package;
        default = pkgs.writeShellScriptBin "install-agenix-shell" config.agenix-shell._installSecrets;
        description = "Script that exports secrets as variables, it's meant to be used as hook in `devShell`s.";
        defaultText = lib.literalMD "An automatically generated package";
      };
    };
  });
}
