
local zk = import "zookeeper.jsonnet";
local hadoop = import "hadoop.jsonnet";
local accumulo = import "accumulo.jsonnet";
local gaffer = import "gaffer.jsonnet";

local all(config) = {

    local net_graph =
	gaffer("net", "netgraph", importstr "netgraph-schema.json", config),

    local risk_graph =
	gaffer("risk", "riskgraph", importstr "riskgraph-schema.json", config),

    local threat_graph =
	gaffer("threat", "threatgraph",
	       importstr "threatgraph-schema.json", config),

    resources:
        if config.options.includeAnalytics then
      	    zk(config).resources + hadoop(config).resources
 	    	+ accumulo(config).resources
		+ net_graph.resources
		+ risk_graph.resources
                + threat_graph.resources
	else [],

    images:
        if config.options.includeAnalytics then
      	    zk(config).images + hadoop(config).images
 	    	+ accumulo(config).images
		+ net_graph.images
		+ risk_graph.images
                + threat_graph.images
	else [],

};

[all]
