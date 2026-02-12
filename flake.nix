{
  description = "Nixinate your systems";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };
  outputs = { self, nixpkgs, ... }:
    let
      # some basic carte-blance tooling to handle valid archtectures.
      version = builtins.substring 0 8 self.lastModifiedDate;
      # this is still better than flake-utils, long game wins.
      forSystems = systems: f:
        nixpkgs.lib.genAttrs systems
        (system: f system nixpkgs.legacyPackages.${system});
      #  If you need to shim in your alien-nixpkgs-overlays override flakeExposed in the input nixpkgs follows packageset; not here. 
      forAllSystems = forSystems nixpkgs.lib.systems.flakeExposed;
      nixpkgsFor = forAllSystems (system: pkgs: import nixpkgs { inherit system; overlays = [ self.overlays.default ]; });
    in rec
    {
      lib.genDeploy = forAllSystems (system: pkgs: nixpkgsFor.${system}.generateApps);
      overlays.default = final: prev: {
        nixinate = {
          nix = prev.pkgs.writeShellScriptBin "nix"
            ''${final.nixVersions.latest}/bin/nix --experimental-features "nix-command flakes" "$@"''; #TODO: appropriately allow passing of nix-version per-machine
          nixos-rebuild = prev.nixos-rebuild.override { inherit (final) nix; };
        };
        generateApps = flake:
          let
            machines = builtins.attrNames flake.nixosConfigurations;
            validMachines = final.lib.remove "" (final.lib.forEach machines (x: final.lib.optionalString (flake.nixosConfigurations."${x}"._module.args ? nixinate) "${x}" ));
            mkDeployScript = { machine }: let
              inherit (final.lib) getExe getExe' optionalString concatStringsSep;
              nix = "${getExe final.nix}";
              nixos-rebuild = "${getExe final.nixos-rebuild}";
              openssh = "${getExe final.openssh} -p ${port} -t ${target_host}";
              lolcat_cmd = "${getExe final.lolcat} -p 3 -F 0.02";
              figlet = "${getExe final.figlet}";
              sem = "${getExe' final.parallel "sem"} --will-cite --line-buffer";
              parameters = flake.nixosConfigurations.${machine}._module.args.nixinate;
              hermetic = parameters.hermetic or true;
              user = if (parameters ? sshUser && parameters.sshUser != null) then parameters.sshUser else (builtins.abort "sshUser must be set in _module.args.nixinate");
              host = parameters.host;
              debug = if (parameters ? debug && parameters.debug) then "set -x;" else "";
              port = toString (parameters.port or 22);
              where = parameters.buildOn or "local";
              target = "${flake}#${machine}";
              target_host = "${user}@${host}";
              ssh_options = "NIX_SSHOPTS=\"-p ${port}\"";
              remote = if where == "remote" then true else if where == "local" then false else builtins.abort "_module.args.nixinate.buildOn is not either 'local' or 'remote'";
              substituteOnTarget = parameters.substituteOnTarget or false;
              nixOptions = concatStringsSep " " (parameters.nixOptions or []);
              header = ''
                  set -e
                  sw=''${1:-test}
                  echo "Deploying nixosConfigurations.${machine} from ${flake}" | ${lolcat_cmd}
                  echo "SSH Target: ${user}@${host}" | ${lolcat_cmd}
                  echo ${if port != 22 then "SSH Port: ${port}" else ""} | ${lolcat_cmd} 
                  echo "Rebuild Command:"
                  echo "${where} build : mode $sw  ${if hermetic then "hermetic active" else ""}" | ${figlet} | ${lolcat_cmd}
                '';

                remoteCopy = if remote then ''
                  echo "Sending flake to ${machine} via nix copy:"
                  ( ${debug} ${ssh_options} ${nix} ${nixOptions} copy ${flake} --to ssh://${target_host} )
                '' else "";

                hermeticActivation = if hermetic then ''
                  echo "Activating configuration hermetically on ${machine} via ssh:"
                    ( ${debug} ${ssh_options} nix ${nixOptions} copy --derivation ${nixos-rebuild} --derivation ${final.parallel} --to ssh://${target_host} )
                    ( ${debug} ${openssh} "sudo nix-store --realise ${nixos-rebuild} --realise ${getExe' final.parallel "sem"} && sudo ${sem} --id \"nixinate-${machine}\" --semaphore-timeout 60 --fg \"${nixos-rebuild} ${nixOptions} $sw --flake ${target}\"" ) #TODO: this does not work cross-archtectures
                '' else ''
                  echo "Activating configuration non-hermetically on ${machine} via ssh:"
                    ( ${openssh} "sudo ${sem} --id \"nixinate-${machine}\" --semaphore-timeout 60 --fg \"nixos-rebuild $sw --flake ${target}\"" )
                '';

                activation = if remote then remoteCopy + hermeticActivation else ''
                  echo "Building system closure locally, copying it to remote store and activating it:"
                    ( ${debug} ${ssh_options} ${sem} --id "nixinate-${machine}" --semaphore-timeout 60 --fg "nixos-rebuild ${nixOptions} \"$sw\" --flake ${target} --target-host ${target_host} --sudo ${optionalString substituteOnTarget "-s"}" )             
                '';
            in 
	    	final.writeShellApplication 
	    	{
	    		name = "deploy-${machine}.sh"; 
	    		meta.description = "nixinate deploy script for ${machine}";
          text = header + activation;
          runtimeInputs = with final; [  ];
	    	};
          in
          nixpkgs.lib.genAttrs
            validMachines (x:
            {
                type = "app";
                meta = {
                  description = "Deployment Application for $x";
                };
                program = nixpkgs.lib.getExe (mkDeployScript { machine = x; });
              });
        };
    };
}
