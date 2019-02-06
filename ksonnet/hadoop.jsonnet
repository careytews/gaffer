//
// Definition for Hadoop HDFS resources on Kubernetes.  This creates a Hadoop
// cluster consisting of a master node (running namenode and datanode) and
// slave datanodes.
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

local hadoop(config) = {

    local version = import "hadoop-version.jsonnet",

    name: "hadoop",
    images: ["cybermaggedon/hadoop:" + version],

    // Ports used by master/main name node.
    local mports = [
        containerPort.newNamed("namenode-http", 50070),
        containerPort.newNamed("namenode-rpc", 9000)
    ],

    // Volume mount points
    local volumeMounts(id) = [
        mount.new("data", "/data")
    ],

    // Master environment variables
    local menvs(replication) = [
		//set hadoop replication to config.hadoop_replication
        env.new("DFS_REPLICATION", std.toString(replication)),
    ],

    // Slave environment variables
    local envs() = [
        env.new("NAMENODE_URI", "hdfs://hadoop:9000")
    ],

	// Master container definition.
	local mcontainer(replication) = [
		container.new("hadoop", self.images[0]) +
			container.ports(mports) +
			container.volumeMounts(mount.new("data", "/data")) +
			container.env(menvs(replication)) +
			container.mixin.resources.limits({
                memory: "1500M", cpu: "1"
            }) +
            container.mixin.resources.requests({
                memory: "1500M", cpu: "0.5"
            }) +
			container.command("/start-namenode")
	],

	// Secondary container definition.
	local scontainer() = [
		container.new("hadoop", self.images[0]) +
			container.ports(containerPort.newNamed
				("secondary-http", 50090)) +
			container.volumeMounts(mount.new("data", "/data")) +
			container.env(envs()) +
			container.mixin.resources.limits({
                memory: "512Mi", cpu: "500m"
            }) +
            container.mixin.resources.requests({
                memory: "512Mi", cpu: "200m"
            }) +
			container.command("/start-secondarynamenode")
	],
    // Slave container definition.
    local containers(id) = [
        container.new("hadoop", self.images[0]) +
            container.ports(containerPort.newNamed("datanode", 50075)) +
            container.volumeMounts(volumeMounts(id)) +
            container.env(envs()) +
    	    container.mixin.resources.limits({
                memory: "1024M", cpu: "0.5"
            }) +
            container.mixin.resources.requests({
                memory: "1024M", cpu: "0.2"
            }) +
			container.command("/start-datanode")
    ],

    // Master volume - this invokes a PVC disk.
    local mvolume = [
        volume.name("data") + pvcVol.claimName("hadoop-master")
    ],

    // secondary volume - this invokes a PVC disk.
    local svolume = [
        volume.name("data") + pvcVol.claimName("hadoop-second")
    ],

    // Slave volumes - this invokes a GCE permanent disk.
    local volumes(id) = [
        volume.name("data") + pvcVol.claimName("hadoop-%04d" % id)
    ],
    // Master deployment definition.
    local mdeployment(replication) =
        depl.new("hadoop-master", 1, mcontainer(replication),
        {app: "hadoop-master", component: "gaffer", disrupt: "hadmast"}) +
        depl.mixin.spec.template.spec.volumes(mvolume) +
        depl.mixin.metadata.namespace(config.namespace),

    // Secondary deployment definition.
    local sdeployment() =
 	depl.new("hadoop-second", 1, scontainer(),
        {app: "hadoop-second", component: "gaffer", disrupt: "hadmast"}) +
        depl.mixin.spec.template.spec.volumes(svolume) +
        depl.mixin.metadata.namespace(config.namespace),

    // Slave deployment definition.  id is the node ID.
    local deployment(id) =
        depl.new("hadoop%04d" % id, 1,
             containers(id),
             {app: "hadoop%04d" % id, component: "gaffer", disrupt: "hadoop"}) +
        depl.mixin.spec.template.spec.volumes(volumes(id)) +
        depl.mixin.metadata.namespace(config.namespace),

    // Ports declared on the service.
    local servicePorts = [
        svcPort.newNamed("rpc", 9000, 9000) + svcPort.protocol("TCP"),
        svcPort.newNamed("http", 50070, 50070) + svcPort.protocol("TCP")
    ],

    deployments:: [
        // One deployment per slave node.
        deployment(id)
        for id in std.range(0, config.hadoops-1)

    ] + [
		// One deployment for the master.
		mdeployment(config.hadoop_replication)
    ] + [
		// One deployment for the secondary master.
		sdeployment()
	],

    services:: [

        // One service for the first node (name node).
        svc.new("hadoop", {app: "hadoop-master"}, servicePorts) +
            svcLabels({app: "hadoop-master", component: "gaffer"}) +
            svc.mixin.metadata.namespace(config.namespace)

    ],

    storageClasses:: [
        sc.new() + sc.mixin.metadata.name("hadoop") +
            config.storageParams.hot +
            sc.mixin.metadata.namespace(config.namespace) +
            { reclaimPolicy: "Retain" }
    ],

    pvcs:: [
        tnw.pvc("hadoop-master", "hadoop", config.hadoopDiskSize, config.namespace),
        tnw.pvc("hadoop-second", "hadoop", config.hadoopDiskSize, config.namespace)
    ] + [
        tnw.pvc("hadoop-%04d" % id, "hadoop", config.hadoopDiskSize, config.namespace)
        for id in std.range(0, config.hadoops-1)
    ],
    
    policies:: [
        //disruption budgets to keep quorum.
        tnw.podDisruptionBudgetMin("hadoop", 2, {disrupt: "hadoop"},config.namespace),
        tnw.podDisruptionBudgetMin("hadmast", 1, {disrupt: "hadmast"},config.namespace)
     ],

    resources: self.deployments + self.services + self.policies + self.pvcs +
        self.storageClasses,

    createCommands: [
    ],

    deleteCommands: [
    ],

    diagram: [
    	"subgraph cluster_8 {",
        "hadoop [label=\"hadoop\"]",
        "hadoop_svc [fontsize=8 label=\"hadoop\\nservice\" shape=circle]",
	"}",
        "hadoop_svc -> hadoop [style=\"dotted\"]"
    ]

};

// Return the function which creates resources.
hadoop
