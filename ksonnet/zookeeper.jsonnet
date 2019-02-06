
//
// Definition for Zookeeper resources on Kubernetes.  This creates a ZK
// cluster consisting of several Zookeepers.
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
local pvcVol = volume.mixin.persistentVolumeClaim;
local svc = k.core.v1.service;
local sc = k.storage.v1.storageClass;
local svcPort = svc.mixin.spec.portsType;
local svcLabels = svc.mixin.metadata.labels;
local disrupt = k.policy.v1beta1.podDisruptionBudget;
local pvc = k.core.v1.persistentVolumeClaim;

local zookeeper(config) = {

    local version = import "zookeeper-version.jsonnet",

    name: "zookeeper",
    images: ["cybermaggedon/zookeeper:" + version],

    // Ports used by deployments
    local ports() = [
        containerPort.newNamed("internal1", 2888),
        containerPort.newNamed("internal2", 3888),
        containerPort.newNamed("service", 2181)
    ],

    // Volume mount points
    local volumeMounts(id) = [
        mount.new("data", "/data")
    ],

    // Environment variables
    local envs(id, zks) = [
        env.new("ZOOKEEPER_MYID", "%d" % (id + 1)),
        env.new("ZOOKEEPERS", zks)
    ],

    // Container definition.
    local containers(id, zks) = [
        container.new("zookeeper", self.images[0]) +
            container.ports(ports()) +
            container.volumeMounts(volumeMounts(id)) +
            container.env(envs(id, zks)) +
            container.mixin.resources.limits({
                memory: "768M", cpu: "0.5"
            }) +
            container.mixin.resources.requests({
                memory: "768M", cpu: "0.1"
            })
    ],

    // Volumes - this invokes a PVC
    local volumes(id) = [
        volume.name("data") + pvcVol.claimName("zookeeper-%d" % (id + 1))
    ],

    // Deployment definition.  id is the node ID, zks is number Zookeepers.
    local deployment(id, zks) =
        depl.new("zk%d" % (id + 1), 1,
                 containers(id, zks),
                 {app: "zk%d" % (id+1), component: "gaffer", disrupt: "zk"}) +
        depl.mixin.spec.template.spec.hostname("zk%d" % (id + 1)) +
        depl.mixin.spec.template.spec.subdomain("zk") +
        depl.mixin.spec.template.spec.volumes(volumes(id)) +
        depl.mixin.metadata.namespace(config.namespace),

    // Function, returns a Zookeeper list, comma separated list of ZK IDs.
    local zookeeperList(count) =
        std.join(",", std.makeArray(count, function(x) "zk%d" % (x + 1))),

    // Ports declared on the ZK service.
    local servicePorts = [
        svcPort.newNamed("internal1", 2888, 2888) + svcPort.protocol("TCP"),
        svcPort.newNamed("internal2", 3888, 3888) + svcPort.protocol("TCP"),
        svcPort.newNamed("service", 2181, 2181) + svcPort.protocol("TCP")
    ],

    deployments:: [

        // One deployment for each Zookeeper
        deployment(id, zookeeperList(config.zookeepers))
        for id in std.range(0, config.zookeepers-1)

    ],
    
    local service(name) =
        svc.new(name, {app: name}, servicePorts) +
            svc.mixin.metadata.namespace(config.namespace),

    services:: [

        // One service for each Zookeeper to allow it to be discovered by
        // Zookeeper name.
        service("zk%d" % id)
        for id in std.range(1, config.zookeepers)


    ],

    storageClasses:: [
        sc.new() + sc.mixin.metadata.name("zookeeper") +
            config.storageParams.hot +
            { reclaimPolicy: "Retain" } +
            sc.mixin.metadata.namespace(config.namespace)
    ],

    pvcs:: [
        tnw.pvc("zookeeper-%d" % (id), "zookeeper", config.zkDiskSize, config.namespace)
        for id in std.range(1, config.zookeepers)
    ],
    
    policies:: [

        // A disruption budget for the zk stack so only one zk is killed at
        // once.
        tnw.podDisruptionBudget("zk", 1, {disrupt: "zk"}, config.namespace),

    ],

    resources: self.deployments + self.services + self.policies +
        self.pvcs + self.storageClasses,

    createCommands: [
    ],

    deleteCommands: [
    ],

    diagram: [
    	"subgraph cluster_8 {",
        "zookeeper [label=\"zookeeper\"]",
        "zookeeper_svc [fontsize=8 label=\"zookeeper\\nservice\" shape=circle]",
	"}",
        "zookeeper_svc -> zookeeper [style=\"dotted\"]"
    ]

};

zookeeper
