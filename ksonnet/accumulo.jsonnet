
//
// Definition for Accumulo resources on Kubernetes.  This creates an Accumulo
// cluster consisting of:
// - A deployment for 'master'
// - A deployment for 'monitor'
// - A deployment for 'gc'
// - A deployment for 'tracer'
// - One deployment per Accumulo slave.
// - One service for each of the above.
//

// This is quite a complex set of resources - clearly Accumulo is not designed
// for Kubernetes.

// Import KSonnet library.
local k = import "ksonnet.beta.2/k.libsonnet";
local tnw = import "lib/tnw-common.libsonnet";

// Short-cuts to various objects in the KSonnet library.
local depl = k.extensions.v1beta1.deployment;
local container = depl.mixin.spec.template.spec.containersType;
local containerPort = container.portsType;
local resources = container.resourcesType;
local env = container.envType;
local svc = k.core.v1.service;
local svcPort = svc.mixin.spec.portsType;
local svcLabels = svc.mixin.metadata.labels;

local accumulo(config) = {

    local version = import "gaffer-version.jsonnet",

    name: "accumulo",
    images: ["cybermaggedon/accumulo-gaffer:" + version],

    // Ports used by deployments
    local ports() = [
        containerPort.newNamed("master", 9999),
        containerPort.newNamed("tablet-server", 9997),
        containerPort.newNamed("gc", 50091),
        containerPort.newNamed("monitor", 9995),
        containerPort.newNamed("monitor-log", 4560),
        containerPort.newNamed("tracer", 12234),
        containerPort.newNamed("proxy", 42424),
        containerPort.newNamed("slave", 10002),
        containerPort.newNamed("replication", 10001)
    ],

    // Function, returns a Zookeeper list, comma separated list of ZK IDs.
    local zookeeperList(count) =
        std.join(",", std.makeArray(count, function(x) "zk%d" % (x + 1))),

    // Returns an Accumulo slave list for the SLAVE_HOSTS environment variable.
    // count is the number of slaves, id is the slave number.  This is arranged
    // so that the slave list has the node name substituted for MY_IP which
    // gets replaced with the nodes IP address by the Accumulo container.
    local slaveList(count, id) =
        std.join(",", std.makeArray(count,
                                    function(x)
                                    "slave%04d.accumulo" % x)),

    // Environment variables
    local envs(slaves, zks, id, proc) = [

        // List of Zookeepers.
        env.new("ZOOKEEPERS", zookeeperList(zks)),

        // List of master, gc, monitor, tracer and slave hosts.  This does the
        // thing where MY_IP is used instead of a hostname when the node in
        // question supplies the function.
        env.new("MASTER_HOSTS", "master.accumulo"),
        env.new("GC_HOSTS", "gc.accumulo"),
        env.new("MONITOR_HOSTS", "monitor.accumulo"),
        env.new("TRACER_HOSTS", "tracer.accumulo"),

        // Slaves only need to know about the master, don't need to know about
        // all the other slaves.  This is only a deal, because in a big cluster,
        // this would generate a lot of config.
        if id >= 0 then
            env.new("SLAVE_HOSTS", "slave%04d.accumulo" % id)
        else
            env.new("SLAVE_HOSTS", slaveList(slaves, id)),

        // HDFS references.
        env.new("HDFS_VOLUMES", "hdfs://hadoop:9000/accumulo"),
        env.new("NAMENODE_URI", "hdfs://hadoop:9000/"),

        // Sizing parameters.
        env.new("MEMORY_MAPS_MAX", "300M"),
        env.new("CACHE_DATA_SIZE", "30M"),
        env.new("CACHE_INDEX_SIZE", "40M"),
        env.new("SORT_BUFFER_SIZE", "50M"),
        env.new("WALOG_MAX_SIZE", "512M"),

        // Over-ride Java mem settings on slaves
        env.new("ACCUMULO_TSERVER_OPTS", "-Xmx2g -Xms256m")

    ],

    // Container definition for non-slave containers.
    local containers(proc, slaves, xks) = [
        container.new("accumulo", self.images[0]) +
            container.ports(ports()) +
            container.command(["/start-process", proc]) +
            container.env(envs(slaves, xks, -1, proc)) +
            container.mixin.resources.limits({
                memory: "1G", cpu: "0.5"
            }) +
            container.mixin.resources.requests({
                memory: "1G", cpu: "0.1"
            })
    ],

    // Container definition for slave containers.
    local slaveContainers(id, slaves, xks) = [
        container.new("accumulo", self.images[0]) +
            container.ports(ports()) +
            container.command(["/start-process", "tserver"]) +
            container.env(envs(slaves, xks, id, "tserver")) +
            container.mixin.resources.limits({
                memory: "2.75G", cpu: "2"
            }) +
            container.mixin.resources.requests({
                memory: "2.75G", cpu: "1"
            })
    ],

    // Deployment definition for non-slave deployments.  proc is the process to
    // run, slaves is the number of slaves, zks is the number of Zookeepers.
    local deployment(proc, slaves, zks) =
        depl.new("accumulo-%s" % proc, 1,
                 containers(proc, slaves, zks),
                 {app: "accumulo", component: "gaffer"}) +
        depl.mixin.spec.template.spec.hostname(proc) +
        depl.mixin.spec.template.spec.subdomain("accumulo") +
        depl.mixin.metadata.namespace(config.namespace),

    // Deployment definition for non-slave deployments.  id is the slave number
    // slaves is the number of slaves, zks is the number of Zookeepers.
    local slaveDeployment(id, slaves, zks) =
        depl.new("accumulo-slave%04d" % id, 1,
            slaveContainers(id, slaves, zks),
            {app: "accumulo", component: "gaffer", disrupt: "accumulo"}) +
        depl.mixin.spec.template.spec.hostname("slave%04d" % id) +
        depl.mixin.spec.template.spec.subdomain("accumulo") +
        depl.mixin.metadata.namespace(config.namespace),

    // Ports declared on the other services.
    local servicePorts = [
        svcPort.newNamed("master", 9999, 9999) + svcPort.protocol("TCP"),
        svcPort.newNamed("gc", 50091, 50091) + svcPort.protocol("TCP"),
        svcPort.newNamed("monitor", 9995, 9995) + svcPort.protocol("TCP"),
        svcPort.newNamed("tracer", 12234, 12234) + svcPort.protocol("TCP"),
        svcPort.newNamed("proxy", 42424, 42424) + svcPort.protocol("TCP"),
        svcPort.newNamed("slave", 10002, 10002) + svcPort.protocol("TCP"),
        svcPort.newNamed("replication", 10001, 10001) + svcPort.protocol("TCP")
    ],

    // Ports declared on the slave services.
    local slavePorts = [
        svcPort.newNamed("slave", 9997, 9997) + svcPort.protocol("TCP")
    ],

    deployments::
        local c = config; [

        // Deployments for master, gc, tracer, monitor.
        deployment("master", c.accumulo_slaves, c.zookeepers),
        deployment("gc", c.accumulo_slaves, c.zookeepers),
        deployment("tracer", c.accumulo_slaves, c.zookeepers),
        deployment("monitor", c.accumulo_slaves, c.zookeepers),

    ],

    services:: local c = config; [

        // One deployment for each slave
        slaveDeployment(id, c.accumulo_slaves, c.zookeepers)
        for id in std.range(0, c.accumulo_slaves-1)

    ] + [

        // Services for the Accumulo master, gc, tracer, monitor.
        svc.new("accumulo", {app: "accumulo"}, servicePorts) +
            svcLabels({app: "accumulo", component: "gaffer"}) +
            svc.mixin.spec.clusterIp("None") +
            svc.mixin.metadata.namespace(config.namespace)

    ],

    policies:: [
        // disruption budget for the accumulo slaves
        tnw.podDisruptionBudgetMin("accumulo", 2, {disrupt: "accumulo"}, config.namespace)
    ],

    resources: self.deployments + self.services + self.policies,

    diagram: [
    	"subgraph cluster_8 {",
        "accumulo [label=\"accumulo\"]",
	"}",
        "accumulo -> hadoop_svc",
        "accumulo -> zookeeper_svc",
    ]

};

// Return the function which creates resources.
accumulo
