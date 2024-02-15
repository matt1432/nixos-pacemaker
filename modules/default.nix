nixpkgs-pacemaker: self: {
  config,
  lib,
  pkgs,
  ...
}: let
  inherit
    (lib)
    all
    any
    attrNames
    attrValues
    concatMapStringsSep
    concatStringsSep
    elemAt
    filterAttrs
    findFirst
    hasAttr
    length
    mapAttrsToList
    mdDoc
    mkEnableOption
    mkForce
    mkIf
    mkOption
    optionalString
    types
    ;
  inherit (builtins) listToAttrs toJSON;

  pacemakerPath = "services/cluster/pacemaker/default.nix";
  cfg = config.services.pcsd;
in {
  disabledModules = [pacemakerPath];
  imports = ["${nixpkgs-pacemaker}/nixos/modules/${pacemakerPath}"];

  options.services.pcsd = {
    enable = mkEnableOption (mdDoc "pcsd");

    # Corosync options
    corosyncKeyFile = mkOption {
      type = with types; nullOr path;
      default = null;
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
      description = mdDoc "List of nodes for the corosync config";
      default = [];
      type = with types;
        listOf (submodule {
          options = {
            nodeid = mkOption {
              type = int;
              description = mdDoc "Node ID number";
            };
            name = mkOption {
              type = str;
              description = mdDoc "Node name";
            };
            ring_addrs = mkOption {
              type = listOf str;
              description = mdDoc "List of addresses, one for each ring.";
            };
          };
        });
    };

    # PCS options
    package = mkOption {
      type = types.package;
      default = self.packages.x86_64-linux.default;
    };

    clusterUserPasswordFile = mkOption {
      type = with types; nullOr path;
      default = null;
      description = mdDoc ''
        Required path to a file containing the password in clear text
      '';
    };

    # TODO: add extraResources for custom resources

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
              type = with types; listOf str;
            };

            startBefore = mkOption {
              default = [];
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
              type = with types; listOf str;
            };

            startBefore = mkOption {
              default = [];
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

  config = let
    # Important vars
    mainNode = (elemAt cfg.nodes cfg.mainNodeIndex).name;
    nodeNames = concatMapStringsSep " " (n: n.name) cfg.nodes;
    resEnabled = (filterAttrs (n: v: v.enable) cfg.systemdResources) // cfg.virtualIps;
    tmpCib = "/tmp/pcsd/cib-new.xml";

    # Resource functions
    mkGroupCmd = resource: name:
      concatStringsSep " " [
        # Doesn't work when applying to tmpCib so no '-f'
        "pcs resource group add ${resource.group} ${name}"

        (optionalString
          (length resource.startAfter != 0)
          (concatMapStringsSep
            " "
            (r: "--after ${r}")
            resource.startAfter))

        (optionalString
          (length resource.startBefore != 0)
          (concatMapStringsSep
            " "
            (r: "--before ${r}")
            resource.startBefore))
      ];

    mkVirtIp = vip:
      concatStringsSep " " ([
          "pcs -f ${tmpCib} resource create ${vip.id}"
          "ocf:heartbeat:IPaddr2"
          "ip=${vip.ip}"
          "cidr_netmask=${toString vip.cidr}"
          "nic=${vip.interface}"
        ]
        ++ vip.extraArgs);

    mkSystemdResource = res:
      concatStringsSep " " ([
          "pcs -f ${tmpCib} resource create ${res.systemdName}"
          "systemd:${res.systemdName}"
        ]
        ++ res.extraArgs);

    resourceTypeInfo = resource:
      if (hasAttr "id" resource)
      then {
        name = resource.id;
        type = "virtualIps";
        createCmd = mkVirtIp resource;
        groupCmd = mkGroupCmd resource resource.id;
      }
      else {
        name = resource.systemdName;
        type = "systemdResources";
        createCmd = mkSystemdResource resource;
        groupCmd = mkGroupCmd resource resource.systemdName;
      };

    resNames = mapAttrsToList (n: v: (resourceTypeInfo v).name) resEnabled;
    resourcesWithPositions =
      mapAttrsToList (n: v: {
        inherit (resourceTypeInfo v) name type;
        constraints = v.startAfter ++ v.startBefore;
      })
      resEnabled;

    errRes =
      # Find the first resource that has errors
      findFirst (
        resource:
          !(
            # For every startBefore and startAfter
            all (
              constraint:
              # A constraint needs to have a corresponding resource name
                (any (resName: constraint == resName) resNames)
                # And can't be its own resource name
                && constraint != resource.name
            )
            resource.constraints
          )
      )
      null
      resourcesWithPositions;
  in
    mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.corosyncKeyFile != null;
          message = ''
            The option services.pcsd.corosyncKeyFile needs a path
            containing a valid corosync key in plain text.
          '';
        }
        {
          assertion = cfg.clusterUserPasswordFile != null;
          message = ''
            The option services.pcsd.clusterUserPasswordFile needs
            a path containing a valid user password in plain text.
          '';
        }
        {
          assertion = length cfg.nodes > 0;
          message = ''
            The option services.pcsd.nodes needs at least one device.
          '';
        }
        {
          # We want there to be no errRes to have a functioning config
          assertion = errRes == null;
          message = ''
            The parameters in services.pcsd.${errRes.type}.${errRes.name}.<startAfter|startBefore>
            need to correspond to the name of a virtualIP or a systemd resource and cannot be "${errRes.name}".
          '';
        }
      ];

      # Pacemaker
      services.pacemaker.enable = true;

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

      environment.systemPackages = [
        cfg.package
        pkgs.ocf-resource-agents
        pkgs.pacemaker
      ];

      # This user is created in the pacemaker service.
      # pcsd needs it to have the "haclient" group and
      # a password which is taken care of in the systemd unit
      users.users.hacluster = {
        isSystemUser = true;
        extraGroups = ["haclient"];
      };
      users.groups.haclient = {};

      systemd.packages = [cfg.package];
      systemd.services = let
        # Abstract funcs
        concatMapAttrsToString = func: attrs:
          concatMapStringsSep "\n" func (attrValues attrs);

        # More resource funcs
        mkResource = resource:
          (resourceTypeInfo resource).createCmd;

        addToGroup = resource: let
          resInfo = resourceTypeInfo resource;
        in
          optionalString
          (!(isNull resource.group))
          "pcs -f ${tmpCib} resource group add ${resource.group} ${resInfo.name}";

        handlePosInGroup = resource: let
          resInfo = resourceTypeInfo resource;
        in
          optionalString
          (
            !(isNull resource.group)
            && (
              resource.startAfter != [] || resource.startBefore != []
            )
          )
          resInfo.groupCmd;
      in
        {
          "pcsd-setup" = {
            path = with pkgs; [
              pacemaker
              cfg.package
              shadow
              jq
              diffutils
            ];

            script = ''
              # Set password on user on every node
              echo hacluster:$(cat ${cfg.clusterUserPasswordFile}) | chpasswd

              # The config needs to be installed from one node only
              if [ "$(uname -n)" = "${mainNode}" ]; then
                  # Check for first run
                  if ! pcs status; then
                      pcs cluster setup ${cfg.clusterName} ${nodeNames} --start --enable

                  # We want to reset the cluster completely if
                  # there are any changes in the corosync config
                  # to make sure it is setup correctly
                  CURRENT_NODES=$(pcs cluster config --output-format json | jq --sort-keys '[.["nodes"] | .[] | .ring_addrs = (.addrs | map(.addr)) | del(.addrs) | .nodeid = (.nodeid | tonumber)]')
                  CONFIG_NODES=$(echo '${toJSON cfg.nodes}' | jq --sort-keys)

                  # Same thing if the name changes
                  CURRENT_NAME=$(pcs cluster config --output-format json | jq '.["cluster_name"]')
                  CONFIG_NAME="\"${cfg.clusterName}\""

                  elif ! cmp -s <(echo "$CURRENT_NODES") <(echo "$CONFIG_NODES") ||
                       ! cmp -s <(echo "$CURRENT_NAME") <(echo "$CONFIG_NAME"); then
                      echo "Resetting cluster"
                      pcs stop
                      pcs destroy
                      pcs cluster setup ${cfg.clusterName} ${nodeNames} --start --enable
                  fi

                  # Auth every node
                  pcs host auth ${nodeNames} -u hacluster -p $(cat ${cfg.clusterUserPasswordFile})

                  # Delete files from potential failed runs
                  rm -rf /tmp/pcsd
                  mkdir -p /tmp/pcsd

                  # Query old config
                  cibadmin --query > /tmp/pcsd/cib-old.xml

                  # Setup tmpCib
              ${optionalString (length cfg.nodes <= 2) ''
                pcs -f ${tmpCib} property set stonith-enabled=false
                pcs -f ${tmpCib} property set no-quorum-policy=ignore
              ''}
              ${concatMapAttrsToString mkResource resEnabled}
              ${concatMapAttrsToString addToGroup resEnabled}

                  # Apply diff between old and new config to current CIB
                  crm_diff --no-version -o /tmp/pcsd/cib-old.xml -n ${tmpCib} |
                  cibadmin --patch --xml-pipe

                  # Group pos doesn't work in tmpCib so we apply it on current CIB
              ${concatMapAttrsToString handlePosInGroup resEnabled}

                  # Cleanup
                  rm -rf /tmp/pcsd
              fi
            '';

            wantedBy = ["multi-user.target"];

            after = [
              "corosync.service"
              "pacemaker.service"
              "pcsd.service"
            ];

            restartIfChanged = true;
            restartTriggers = [(toJSON cfg)];

            serviceConfig = {
              Restart = "on-failure";
              RestartSec = "5s";
            };
          };

          "pcsd" = {
            path = [cfg.package pkgs.ocf-resource-agents];
            # The upstream service already defines this, but doesn't get applied.
            wantedBy = ["multi-user.target"];
          };
          "pcsd-ruby" = {
            path = [cfg.package pkgs.ocf-resource-agents];
            preStart = "mkdir -p /var/{lib/pcsd,log/pcsd}";
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
