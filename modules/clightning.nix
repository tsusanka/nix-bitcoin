{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.clightning;
  nbLib = config.nix-bitcoin.lib;
  nbPkgs = config.nix-bitcoin.pkgs;
  network = config.services.bitcoind.makeNetworkName "bitcoin" "regtest";
  configFile = pkgs.writeText "config" ''
    network=${network}
    bitcoin-datadir=${config.services.bitcoind.dataDir}
    ${optionalString (cfg.proxy != null) "proxy=${cfg.proxy}"}
    always-use-proxy=${boolToString cfg.always-use-proxy}
    bind-addr=${cfg.address}:${toString cfg.port}
    bitcoin-rpcconnect=${config.services.bitcoind.rpc.address}
    bitcoin-rpcport=${toString config.services.bitcoind.rpc.port}
    bitcoin-rpcuser=${config.services.bitcoind.rpc.users.public.name}
    rpc-file-mode=0660
    ${cfg.extraConfig}
  '';
in {
  options.services.clightning = {
    enable = mkEnableOption "clightning";
    address = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "IP address or UNIX domain socket to listen for peer connections.";
    };
    port = mkOption {
      type = types.port;
      default = 9735;
      description = "Port to listen for peer connections.";
    };
    proxy = mkOption {
      type = types.nullOr types.str;
      default = if cfg.enforceTor then config.services.tor.client.socksListenAddress else null;
      description = ''
        Socks proxy for connecting to Tor nodes (or for all connections if option always-use-proxy is set).
      '';
    };
    always-use-proxy = mkOption {
      type = types.bool;
      default = cfg.enforceTor;
      description = ''
        Always use the proxy, even to connect to normal IP addresses.
        You can still connect to Unix domain sockets manually.
        This also disables all DNS lookups, to avoid leaking address information.
      '';
    };
    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/clightning";
      description = "The data directory for clightning.";
    };
    networkDir = mkOption {
      readOnly = true;
      default = "${cfg.dataDir}/${network}";
      description = "The network data directory.";
    };
    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Extra lines appended to the configuration file.";
    };
    user = mkOption {
      type = types.str;
      default = "clightning";
      description = "The user as which to run clightning.";
    };
    group = mkOption {
      type = types.str;
      default = cfg.user;
      description = "The group as which to run clightning.";
    };
    cli = mkOption {
      readOnly = true;
      default = pkgs.writeScriptBin "lightning-cli" ''
        ${nbPkgs.clightning}/bin/lightning-cli --lightning-dir='${cfg.dataDir}' "$@"
      '';
      description = "Binary to connect with the clightning instance.";
    };
    getPublicAddressCmd = mkOption {
      type = types.str;
      default = "";
      description = ''
        Bash expression which outputs the public service address to announce to peers.
        If left empty, no address is announced.
      '';
    };
    inherit (nbLib) enforceTor;
  };

  config = mkIf cfg.enable {
    services.bitcoind = {
      enable = true;
      # Increase rpc thread count due to reports that lightning implementations fail
      # under high bitcoind rpc load
      rpc.threads = 16;
    };

    environment.systemPackages = [ nbPkgs.clightning (hiPrio cfg.cli) ];

    systemd.tmpfiles.rules = [
      "d '${cfg.dataDir}' 0770 ${cfg.user} ${cfg.group} - -"
    ];

    systemd.services.clightning = {
      path  = [ nbPkgs.bitcoind ];
      wantedBy = [ "multi-user.target" ];
      requires = [ "bitcoind.service" ];
      after = [ "bitcoind.service" ];
      preStart = ''
        chown -R '${cfg.user}:${cfg.group}' '${cfg.dataDir}'
        # The RPC socket has to be removed otherwise we might have stale sockets
        rm -f ${cfg.networkDir}/lightning-rpc
        install -m 640 ${configFile} '${cfg.dataDir}/config'
        {
          echo "bitcoin-rpcpassword=$(cat ${config.nix-bitcoin.secretsDir}/bitcoin-rpcpassword-public)"
          ${optionalString (cfg.getPublicAddressCmd != "") ''
            echo "announce-addr=$(${cfg.getPublicAddressCmd})"
          ''}
        } >> '${cfg.dataDir}/config'
      '';
      serviceConfig = nbLib.defaultHardening // {
        ExecStart = "${nbPkgs.clightning}/bin/lightningd --lightning-dir=${cfg.dataDir}";
        User = cfg.user;
        Restart = "on-failure";
        RestartSec = "10s";
        ReadWritePaths = cfg.dataDir;
      } // nbLib.allowedIPAddresses cfg.enforceTor;
      # Wait until the rpc socket appears
      postStart = ''
        while [[ ! -e ${cfg.networkDir}/lightning-rpc ]]; do
            sleep 0.1
        done
        # Needed to enable lightning-cli for users with group 'clightning'
        chmod g+x ${cfg.networkDir}
      '';
    };

    users.users.${cfg.user} = {
      group = cfg.group;
      extraGroups = [ "bitcoinrpc-public" ];
    };
    users.groups.${cfg.group} = {};
    nix-bitcoin.operator.groups = [ cfg.group ];
  };
}
