{
    description = "resonite-dominion";

    inputs = {};

    outputs = { ... }: {
        nixosModules = {
            default = { ... }: {
                imports = [ ./service.nix ];
            };
        };
    };
}
