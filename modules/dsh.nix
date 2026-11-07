# NixOS module for DeepSeek Harness.
#
# `dsh web` is a long-running HTTP server that can read files and run commands in
# the working directory, so this module runs it as a dedicated unprivileged user
# rather than as root. Everything it writes lives under `services.dsh.home`,
# which doubles as DSH_HOME.
#
# The module deliberately does not install plugins: `dsh plugin add` is a pnpm
# install against the profile directory, i.e. a networked mutation of state. Pin
# plugins with `services.dsh.extraPlugins` if you want them installed on
# activation, or manage the profile by hand.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.dsh;
in
{
  options.services.dsh = {
    enable = lib.mkEnableOption "DeepSeek Harness web server";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.dsh or (throw "services.dsh: set services.dsh.package (e.g. inputs.dsh-nix.packages.\${pkgs.system}.dsh)");
      defaultText = lib.literalExpression "pkgs.dsh";
      description = "The dsh package to run.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "dsh";
      description = "User the service runs as. Created if it does not exist.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = cfg.user;
      defaultText = lib.literalExpression "services.dsh.user";
      description = "Group the service runs as.";
    };

    home = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/dsh";
      description = ''
        State directory, also used as `DSH_HOME`: profiles, sessions, credentials
        and the plugin install trees all live here.
      '';
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        Listen address. `dsh web` rejects wildcard addresses, so this has to be
        one concrete literal of a local interface.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3080;
      description = "Listen port.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open `services.dsh.port` in the firewall.";
    };

    trustedHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "nas.lan:3080" ];
      description = ''
        Extra authorities accepted by the `/api` browser-trust fence. Needed when
        the server is reached under a name other than the one it was started
        with — for example through a reverse proxy or by hostname over the LAN.
      '';
    };

    patchFiles = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = ''
        Extra plugin-overlay files passed with `--patch`, applied in order on top
        of the profile layer. Use these for declarations Nix owns; leave
        `$DSH_HOME/profiles/<name>/cordis.patch.yml` to the web UI.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        File of `KEY=value` lines made available to the service — in practice the
        model provider API keys. Loaded at start, so it must be readable by
        `services.dsh.user` and is best rendered by sops-nix.
      '';
    };

    openBrowser = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether dsh should try to open a browser on start. There is none on a server.";
    };

    settings = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra flags, merged into the command line as `key = value`.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.package != null;
        message = "services.dsh.package must be set.";
      }
    ];

    users.users = lib.mkIf (cfg.user == "dsh") {
      dsh = {
        isSystemUser = true;
        inherit (cfg) group;
        home = cfg.home;
        createHome = true;
      };
    };

    users.groups = lib.mkIf (cfg.group == "dsh") { dsh = { }; };

    # The state directory has to survive the service user being recreated.
    systemd.tmpfiles.rules = [
      "d  ${cfg.home} 0750 ${cfg.user} ${cfg.group} -"
    ];

    systemd.services.dsh = {
      description = "DeepSeek Harness web server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        HOME = cfg.home;
        DSH_HOME = cfg.home;
      };

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.home;
        ExecStart = lib.concatStringsSep " " (
          [
            "${cfg.package}/bin/dsh"
            "web"
            "--host"
            cfg.host
            "--port"
            (toString cfg.port)
            "--no-open"
          ]
          ++ lib.concatMap (p: [ "--patch" "${p}" ]) cfg.patchFiles
          ++ lib.concatMap (h: [ "--trusted-host" h ]) cfg.trustedHosts
        );
        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
        Restart = "on-failure";
        RestartSec = "5s";

        # `dsh web` can read and write files in the working directory and spawn
        # subprocesses; that is the point of an agent harness, so the sandbox
        # stays loose around $HOME and tight everywhere else.
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = "tmpfs";
        ReadWritePaths = [ cfg.home ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
