nixpkgs-pacemaker: self: {
  config,
  lib,
  pkgs,
  ...
}: let
  inherit
    (lib)
    attrNames
    attrValues
    concatMapStringsSep
    concatStringsSep
    elemAt
    filterAttrs
    length
    mdDoc
    mkForce
    mkIf
    mkOption
    optionals
    optionalString
    types
    ;
  inherit (builtins) listToAttrs;

  pacemakerPath = "services/cluster/pacemaker/default.nix";
  cfg = config.services.pacemaker;
in {
  disabledModules = [pacemakerPath];
  imports = ["${nixpkgs-pacemaker}/nixos/modules/${pacemakerPath}"];

  options.services.pacemaker = {
    # Corosync options
    corosyncKeyFile = mkOption {
      type = types.path;
    };

    clusterName = mkOption {
      type = types.str;
      default = "nixcluster";
    };

    mainNodeIndex = mkOption {
      type = types.int;
      default = 0;
      description = mdDoc ''
        The index of the node you want to take care of updating
        the cluster settings in the nodes list.
      '';
    };

    nodes = mkOption {
      type = with types;
        listOf (submodule {
          options = {
            nodeid = mkOption {
              type = int;
              description = lib.mdDoc "Node ID number";
            };
            name = mkOption {
              type = str;
              description = lib.mdDoc "Node name";
            };
            ring_addrs = mkOption {
              type = listOf str;
              description = lib.mdDoc "List of addresses, one for each ring.";
            };
          };
        });
      default = [];
    };

    # PCS options
    pcsPackage = mkOption {
      type = types.package;
      default = self.packages.x86_64-linux.default;
    };

    clusterUser = mkOption {
      type = types.str;
      default = "hacluster";
    };

    # TODO: add password file option
    clusterUserPasswordFile = mkOption {
      type = types.path;
      description = mdDoc ''
        Required path to a file containing the password in clear text
      '';
    };

    systemdResources = mkOption {
      default = {};
      type = with types;
        attrsOf (submodule ({name, ...}: {
          options = {
            enable = mkOption {
              default = true;
              type = types.bool;
            };

            systemdName = mkOption {
              default = name;
              type = types.str;
            };

            group = mkOption {
              type = with types; nullOr str;
            };

            startAfter = mkOption {
              default = [];
              # TODO: assert possible strings
              type = with types; listOf str;
            };

            startBefore = mkOption {
              default = [];
              # TODO: assert possible strings
              type = with types; listOf str;
            };

            extraArgs = mkOption {
              type = with types; listOf str;
              default = [];
              description = mdDoc ''
                Additional command line options to pcs when making a systemd resource
              '';
            };
          };
        }));
    };

    virtualIps = mkOption {
      default = {};
      type = with types;
        attrsOf (submodule ({name, ...}: {
          options = {
            id = mkOption {
              type = types.str;
              default = name;
            };

            interface = mkOption {
              default = "eno1";
              type = types.str;
            };

            ip = mkOption {
              type = types.str;
            };

            cidr = mkOption {
              default = 24;
              type = types.int;
            };

            group = mkOption {
              type = with types; nullOr str;
            };

            startAfter = mkOption {
              default = [];
              # TODO: assert possible strings
              type = with types; listOf str;
            };

            startBefore = mkOption {
              default = [];
              # TODO: assert possible strings
              type = with types; listOf str;
            };

            extraArgs = mkOption {
              type = with types; listOf str;
              default = [];
              description = mdDoc ''
                Additional command line options to pcs when making a virtual IP
              '';
            };
          };
        }));
    };
  };

  config = mkIf cfg.enable {
    # Corosync
    services.corosync = {
      enable = true;
      clusterName = mkForce cfg.clusterName;
      nodelist = mkForce cfg.nodes;
    };

    environment.etc."corosync/authkey" = {
      source = cfg.corosyncKeyFile;
    };

    # PCS
    security.pam.services.pcsd.text = ''
      #%PAM-1.0
      auth       include      systemd-user
      account    include      systemd-user
      password   include      systemd-user
      session    include      systemd-user
    '';
    environment.systemPackages = [cfg.pcsPackage];

    # FIXME: this is definitely not how you do it
    users.users.${cfg.clusterUser} = {
      isSystemUser = true;
      extraGroups = ["haclient"];
    };
    users.groups.haclient = {};

    systemd.packages = [cfg.pcsPackage];
    systemd.services = let
      host = (elemAt cfg.nodes cfg.mainNodeIndex).name;
      nodeNames = concatMapStringsSep " " (n: n.name) cfg.nodes;
      resEnabled = filterAttrs (n: v: v.enable) cfg.systemdResources;

      mkCondVirtIp = vip: ''
        if pcs resource config --output-format json | jq '.["primitives"][].id' | grep \"${vip.id}\";
        then
            # Already exists
            # FIXME: find better way
            pcs resource delete ${vip.id}
            ${mkVirtIp vip}
        else
            # Doesn't exist
            ${mkVirtIp vip}
        fi
      '';

      mkVirtIp = vip:
        concatStringsSep " " ([
            "pcs resource create ${vip.id}"
            "ocf:heartbeat:IPaddr2"
            "ip=${vip.ip}"
            "cidr_netmask=${toString vip.cidr}"
            "nic=${vip.interface}"
          ]
          ++ (optionals (!(isNull vip.group)) [
            "--group ${vip.group}"

            (optionalString
              (length vip.startAfter != 0)
              (concatMapStringsSep
                " "
                (v: "--after ${v}")
                vip.startAfter))

            (optionalString
              (length vip.startBefore != 0)
              (concatMapStringsSep
                " "
                (v: "--before ${v}")
                vip.startBefore))
          ])
          ++ vip.extraArgs
          # FIXME: figure out why this is needed
          ++ ["--force"]);

      mkCondSystemdRes = res: ''
        if pcs resource config --output-format json | jq '.["primitives"][].id' | grep \"${res.systemdName}\";
        then
            # Already exists
            # FIXME: find better way
            pcs resource delete ${res.systemdName}
            ${mkSystemdResource res}
        else
            # Doesn't exist
            ${mkSystemdResource res}
        fi
      '';

      mkSystemdResource = res:
        concatStringsSep " " ([
            "pcs resource create ${res.systemdName}"
            "systemd:${res.systemdName}"
          ]
          ++ (optionals (!(isNull res.group)) [
            "--group ${res.group}"

            (optionalString
              (length res.startAfter != 0)
              (concatMapStringsSep
                " "
                (v: "--after ${v}")
                res.startAfter))

            (optionalString
              (length res.startBefore != 0)
              (concatMapStringsSep
                " "
                (v: "--before ${v}")
                res.startBefore))
          ])
          ++ res.extraArgs);
    in
      {
        "pcsd" = {
          enable = true;
          partOf = ["pacemaker.service"];
        };
        "pcsd-ruby" = {
          enable = true;
          partOf = ["pacemaker.service"];
          preStart = "mkdir -p /var/{lib/pcsd,log/pcsd}";
        };

        "pacemaker-setup" = {
          after = [
            "corosync.service"
            "pacemaker.service"
            "pcsd.service"
            "pcsd-ruby.service"
          ];

          restartIfChanged = true;
          restartTriggers = [cfg];

          serviceConfig = {
            Restart = "on-failure";
            RestartSec = "5s";
          };

          path = with pkgs; [
            pacemaker
            cfg.pcsPackage
            shadow
            jq
          ];

          script = ''
            # Set password on user
            echo ${cfg.clusterUser}:$(cat ${cfg.clusterUserPasswordFile}) | chpasswd

            # FIXME: it needs to be restarted the first time you do it

            # The config needs to be installed from one node only
            if [ "$(uname -n)" = ${host} ]; then
                pcs host auth ${nodeNames} -u ${cfg.clusterUser} -p $(cat ${cfg.clusterUserPasswordFile})

                # FIXME: make this not make errors when already configured
                #pcs cluster setup ${cfg.clusterName} ${nodeNames} --start --enable

                # 2 node setup TODO: make this an option or auto when 2 nodes
                pcs property set stonith-enabled=false
                pcs property set no-quorum-policy=ignore

                ${concatMapStringsSep "\n" mkCondVirtIp (attrValues cfg.virtualIps)}
                ${concatMapStringsSep "\n" mkCondSystemdRes (attrValues resEnabled)}
            fi
          '';
        };
      }
      # Force all systemd units handled by pacemaker to not start automatically
      // listToAttrs (map (x: {
        name = x;
        value = {
          wantedBy = mkForce [];
        };
      }) (attrNames cfg.systemdResources));

    # Overlays that fix some bugs
    # FIXME: https://github.com/NixOS/nixpkgs/pull/208298
    nixpkgs.overlays = [
      (final: prev: {
        inherit
          (nixpkgs-pacemaker.legacyPackages.x86_64-linux)
          pacemaker
          ocf-resource-agents
          ;
      })
    ];
  };
}
