
//
// Definition for Gaffer HTTP API / Wildfly on Kubernetes.  This creates a set
// of Wildfly replicas.
//

// Import KSonnet library.
local k = import "ksonnet.beta.2/k.libsonnet";
local tnw = import "lib/tnw-common.libsonnet";

// Short-cuts to various objects in the KSonnet library.
local depl = k.extensions.v1beta1.deployment;
local container = depl.mixin.spec.template.spec.containersType;
local containerPort = container.portsType;
local mount = container.volumeMountsType;
local volume = depl.mixin.spec.template.spec.volumesType;
local resources = container.resourcesType;
local env = container.envType;
local svc = k.core.v1.service;
local svcPort = svc.mixin.spec.portsType;
local svcLabels = svc.mixin.metadata.labels;
local configMap = k.core.v1.configMap;

local gaffer(id, table, schema, config) = {

    local version = import "gaffer-version.jsonnet",

    name: "gaffer-" + id,
    images: ["cybermaggedon/wildfly-gaffer:" + version],

    // Ports used by deployments
    local ports = [
        containerPort.newNamed("rest", 8080)
    ],

    // Constructs a list of Zookeeper hostnames, comma separated.
    local zookeeperList(count) =
        std.join(",", std.makeArray(count, function(x) "zk%d" % (x + 1))),
    
    // Environment variables
    local envs(zookeepers) = [
        // List of Zookeepers.
        env.new("ZOOKEEPERS", zookeeperList(zookeepers)),

	// Accumulo table name
	env.new("ACCUMULO_TABLE", table)
    ],

    // Volume mount points
    local volumeMounts = [
        mount.new(id + "-schema", "/usr/local/wildfly/schema") +
	    mount.readOnly(true),
    ],

    // Container definition.
    local containers(zookeepers) = [
        container.new("gaffer", self.images[0]) +
            container.ports(ports) +
            container.env(envs(zookeepers)) +
            container.volumeMounts(volumeMounts) +
            container.mixin.resources.limits({
                memory: "2G", cpu: "2.5"
            }) +
            container.mixin.resources.requests({
                memory: "2G", cpu: "2.0"
            }) +
            container.mixin.readinessProbe.initialDelaySeconds(15) +
            container.mixin.readinessProbe.periodSeconds(5) +
            container.mixin.readinessProbe.httpGet.port("rest") +
            container.mixin.readinessProbe.httpGet.path("/rest/v2/graph/config/schema") +
            container.mixin.livenessProbe.initialDelaySeconds(45) +
            container.mixin.livenessProbe.periodSeconds(10) +
            container.mixin.livenessProbe.httpGet.port("rest") +
            container.mixin.livenessProbe.httpGet.path("/rest/v2/graph/config/schema")
    ],

    configMaps: [
    	configMap.new() +
        configMap.mixin.metadata.name(id + "-schema") +
        configMap.mixin.metadata.namespace(config.namespace) +
        configMap.data({"example-schema.json": schema}),
    ],

    // Volumes - this invokes a secret containing the web cert/key
    local volumes = [
	volume.fromConfigMap(id + "-schema",
	                     id + "-schema", [{
 	    key: "example-schema.json",
 	    path: "example-schema.json",
        }]),
    ],

    // Deployment definition.  id is the node ID.
    local deployment(gaffers, zookeepers) = 
        depl.new("gaffer-" + id, gaffers,
                 containers(zookeepers),
                 {app: "gaffer-" + id, component: "gaffer"}) +
            depl.mixin.metadata.namespace(config.namespace) +
            depl.mixin.spec.template.spec.volumes(volumes),
    
    // Ports declared on the service.
    local servicePorts = [
        svcPort.newNamed("rest", 8080, 8080) + svcPort.protocol("TCP")
    ],

    autoScalers:: [
        tnw.horizontalPodAutoscaler("gaffer-" + id, "gaffer", config.gaffers, config.gaffers * 3, 80, config.namespace),
    ],

    deployments:: [
        // One deployment, with a set of replicas.
        deployment(config.gaffers, config.zookeepers)
    ],
    services:: [
        // One service load-balanced across the replicas
        svc.new("gaffer-" + id, {app: "gaffer-" + id}, servicePorts) +
            svcLabels({app: "gaffer-" + id, component: "gaffer"}) +
            svc.mixin.metadata.namespace(config.namespace)
    ],

    resources: self.deployments + self.services + self.configMaps +
         self.autoScalers,

    diagram: [
    	"subgraph cluster_8 { label=\"gaffer\"",
        "gaffer [label=\"gaffer\"]",
	"}",
        "gaffer -> accumulo"
    ]
           
};

// Return the function which creates resources.
gaffer

