Partially-connected Erlang clustering
=====================================

For the impatient
=================

1. Add ``spapi_router`` to your rebar.config and ``application.app.src``::

      {application, myapp, [
              ...
              {applications, [kernel, stdlib, spapi_router]}
          ]
      }
2. Configure ``spapi_router`` hostnames and worker_nodes::

    {spapi_router, [
        {host_names, [
            "host001.fqdn", "host002.fqdn", "host003.fqdn"
            ]},
        {workers, [
                {"^nodename_regexp$", [piqi_rpc]}
            ]}
        ]}

3. Now spapi-router will automatically connect to EPMD of ``host00[1-3]``,
   check if nodename matching regexp and with ``piqi_rpc`` running. If so,
   it will establish an Erlang connection.
4. Call your service::

    > spr_router:call(piqi_rpc, application, which_applications, []).
    [kernel, stdlib, cowboy, piqi, piqi_rpc]

First argument (``piqi_rpc``) is your service name. It is used to find the
worker configured above. Three remaining arguments are MFA, identical to
last three arguments of ``rpc:call/4``.

Now when you have a taste how it works, read below.

Abstract
========

It is impossible to have a large (100+ nodes) Erlang cluster connected naïvely
in fully connected network because amount of keepalive traffic grows
exponentially with cluster size. This is a pity, because native node-to-node
Erlang communication is very useful in application programming. With a smart
library we developed and some knowledge about communication channels it is
possible to create Erlang clusters of unbounded size. This allows application
scalability without dramatically changing the paradigm of communication (still
utilizing message passing provided by Erlang).

Introduction
============

In an Erlang cluster, every node sends regular messages to all other nodes in the
cluster to monitor their health. If the node does not reply in time, it is
considered to be 'DOWN'. This works great for most setups where number of nodes
is smallish. However, problems appear when number of nodes go up. In default
scenario, fully connected Erlang topology can handle 50-100 nodes[1]_. To
overcome this problem, we have to create a partially connected network
connecting only nodes which *need* to communicate with each other. Note that
partially connected network works only for applications which do not require
fully connected network. This consequence is obvious, but very important, must
be noted twice.

Erlang provides low-level machinery for creating custom cluster topologies.
However, it is too low level for convenient usage in production applications
(as explained later in *background*). Library presented here abstracts details
of network structure maintenance and provides communication abstractions on top
of message passing, so we can conveniently connect and call necessary services
without knowing full details of the network topology.

What exactly does the library do?

* Provides high-level way to configure node inter-dependencies.
* Maintains cluster topology according the configuration.
* Provides convenience functions for inter-node communication and load
  balancing.

Glossary
========

* *Application* is an OTP application.
* *Service* is an instance of Erlang application running on many nodes.

Configuration
=============
There are 2 required and 4 optional parameters for spapi-router:

Required:
 * ``workers :: [{NodenameRegEx, [WorkerApplicationName]}]``. Default ``[]``.
   ``NodeNameregEx :: string()``,
   ``WorkerApplicationName :: string() | atom()``.
 * ``host_names``: ``[Hostname:string()|atom()]``.
   Default ``[net_adm:localhost()]``.

Optional:
 * ``hosts_monitor_interval_ms :: pos_integer()``. Default ``30000 ms``.
 * ``world_monitor_interval_ms :: pos_integer()``. Default ``20000 ms``.
 * ``worker_monitor_interval_ms :: pos_integer()``. Default ``4000 ms``.
 * ``callback_module :: [Callback:module()]``. Default ``undefined``.

Remarks:
 * only workers and host_names are required for normal operation
 * callback modules are required to implement the ``spapi_router_callback`` behaviour
   This means implementing ``new_resource/1``, ``lost_resource/1``, ``measure/2``,
   ``success/1``, ``failure/1``. Callback documentation is described below.
 * the various intervals are desribed in *internals*.


Instrumentation and callbacks
=============================

Using spapi-router you can measure and log how much time it takes to execute a
command. For example, to log it to graphite using `estatsd`::

    {spapi_router, [
        ...
        {callback_module, spapi_router_callback_example},
        {callback_module_opts, [{statsd_prefix, "services."}]}
    ]}.

The documentation for callback module can be found in
``src/spapi_router_callback.erl``.

Two example callback implementations are available in the source tree:
``src/spapi_router_callback_example.erl`` and
``src/spapi_router_callback_noop.erl``.


Background
==========

Consider building a page on the website. A single page is composed of many
different sub-pages: header (includes user profile), navigation (includes
recommendations for user) and something even less cacheable for main section.
In service oriented architecture, every component (in this case, header,
navigation and main section) render independently::

   .           +---------------+
               |  Page Builder |
               |    service    |
               +---------------+
              /       |         \
             /        |          \
   +---------+   +------------+  +--------------+
   | Header  |   | Navigation |  | Main Section |
   | service |   |  service   |  |   service    |
   +---------+   +------------+  +--------------+

In our case, we treat every "service" as an independent Erlang node. Let's call
Header, Navigation and Main Section services workers, because their sole reason
is to serve Page Builder. Notably Header does not communicate with neither
navigation nor main section. Therefore it makes sense for Page Builder service
to have 3 connections, whereas workers should have 1 connection each.

In order to connect two nodes in the cluster, the following command must be
issued: ``net_kernel:connect_node('nodename@hostname.fqdn').``. Both node name
and hostname have to be known. A straightforward solution would be to put this
call into an application code or a library. However, calling a remote service
also requires to know the host name of the application (assume application
names reflect their purpose, therefore we know nodename beforehand).
Application should not worry about host names of the workers when it wants to
issue a call to the worker. It needs to send the message to a particular
service, but should not care on which host the call ends up.

We present a library which forms the network and abstracts calling a 'worker'.

Forming partially-connected network
===================================

Spapi-router is an Erlang application that maintains network topology and helps
to send the requests to the designated nodes. It consists of two parts:

1. Network topology maintenance from a convenient configuration source.
2. Sending and load-balancing requests to workers (connected nodes) while
   abstracting the destination hostname.

In our example case, Page Builder service would have spapi-router running and 3
workers configured: Header, Navigation and Main Section. Here is how example
spapi-router configuration could look like::

  [
    {spapi_router, [
        {workers, [
            {"^header",  [header_srv]},
            {"^navigation", [navigation_srv]},
            {"^mainsection", [mainsection_srv]}
        ]},
        {host_names, [
            "har001.fqdn", "har002.fqdn", "har003.fqdn"
        ]}
    ]}
  ].

Spapi-router automatically connects to EPMD (Erlang Port Mapper Daemon) on
``har00{1,2,3}.fqdn`` and asks for the available nodes in every host. It will
connect to all nodes which name matches the nodename in ``workers``.
More how it works is covered in *internals* section.

At this stage we have a desired network topology. But how do we use it in the
application?

Giving workers work
===================

A typical line in application code utilizing spapi-router::

  spr_router:call(header_srv, header_facade, render, [1]).

Spapi-router picks a hostname which has this application running and executes
this call::

  rpc:call('header@har001.fqdn', header_facade, render, [1]).


As we can see, it also does load balancing: if more than one node exists with
the same name, spapi-router will prefer to send the request to a node on the
same host. If no local host is available, it will pick the host randomly.
``spr_router`` module has more convenience functions similar to ones in ``rpc``.

Internals
=========

Upon startup, spapi-router connects to EPMD of all the configured hosts (by
default localhost) and asks for nodes runing on every host. It then connects to
relevant nodes (which match the regular expressions from the workers), adds
application name to an ETS table and starts monitoring it (``erlang:monitor_node/2``).
It periodically asks EPMD for list of active nodes in all hosts for new node
discovery.

When ``spr_router:call(Nodename, ...)`` is executed, spapi-monitor looks in its
ETS table to find the relevant nodename/hostname, and simply forwards the
request to low-level built-in Erlang ``rpc`` module. Local nodes are preferred
and care is taken to make the node-selection as efficient as possible.

When a node that spapi-router is monitoring stops responding, ``'DOWN'``
message is received and spapi-router removes the offending node from its ETS
table. It also records the fact that a node went down, but it does not immediately
rescan to see if the node got back online.

Periodically spapi-router will rescan for missing workers according to the
configuration ``worker_monitor_interval_ms``. If it does not get back after a
number of checks, it is considered to be dead. This operation will not do anything
if no down nodes or missing applications were detected. Each node that matches
the regular expression in ``workers`` is expected to run an identical set of workers.

Besides periodically scanning for missing nodes as described above, spapi-router
also periodically rescans the world to detect new nodes. This is called the
world-scan and is configured by ``world_monitor_interval_ms``. The default value
of 20 seconds means new nodes will be picked up after maximal 20 seconds.

Above description of internals follows interesting discussion in *Further work*
section.


Related work
============

Spapi-monitor provides two pieces of functionality: forming a mesh network and
efficiently routing requests to the relevant workers. This section will cover
alternative means of what spapi-router accomplishes.

pg2
---

``pg2`` is a built-in module for making Distributed Named Process Groups. It
allows creating pools of processes on distributed nodes. In our example, we
could create a pool named ``header_srv``, which would contain a process
per ``"header"`` service node. In other words, every Header Renderer service
worker would have a single process which would be in the ``header_srv`` pool.

Then client code could ask for a random process from that pool and call that
node using built-in Erlang ``rpc`` module::

  Pid = pg2:get_closest_pid(header_srv),
  Node = node(Pid),
  rpc:call(Node, header_facade, render, [1]).

We almost have spapi-router. The only thing missing is making sure network does
not fully connect. And this is the culprit: pg2 works by broadcasting all
members of all groups to all participating nodes, therefore node relationship
becomes transitive, consequently, we eventually end up with a fully connected
network.

gproc
-----

gproc[3]_ can also be used as a distributed named process list. It uses a
leader (via gen_leader) to update the process map; all distributed state
updates go through the leader. Therefore, if node B sees process A and C, but A
does not see C and A happens to be the leader, C neither can get state updates
nor alter the global state. Therefore leader approach does not work by design;
a more distributed approach is necessary.

CloudI
------

CloudI[2]_ is an open source cloud computing platform with a focus on
connecting heterogenous technologies. It is similar to spapi-router in a way
that it allows to create partially-connected application networks and abstracts
call destinations. While CloudI would work, most of our application stack is
Erlang and for this purpose we are looking for a much simpler component.

RELEASE
-------

RELEASE project is a much bigger project aiming to improve distributed Erlang:

  Evolving the language to Scalable Distributed (SD) Erlang, and adapting the
  OTP framework to provide both constructs like locality control, and reusable
  coordination patterns to allow SD Erlang to effectively describe computations
  on large platforms, while preserving performance portability.

However, currently it is still in research phase and not yet ready for
production use.

``.hosts.erlang``
-----------------

``.hosts.erlang`` is a way to connect to other nodes on different machines,
regardless of their name. When this file contains a list of hostnames,
``net_adm:names()`` returns all nodes on mentioned hosts, and
``net_adm:world()`` connects to all of them. It is possible to specify target
hostnames in this file (and keep spapi-router slightly smaller), however,
target application name prefixes also have to be configured. Single, standard
configuration place was chosen to keep host names for consistency.

Further work
============

If application is suitable to be connected in mesh network and the
communication patterns are clear before hand, spapi-router will most likely be
useful. Though current approach has a few points for improvement. When a worker
is intentionally shut down, this is what happens on the node:

1. all applications are stopped
2. node is shutdown
3.  ``'DOWN'`` message is sent to the listeners.

The time between the application shutdown and ``'DOWN'`` message is downtime:
spapi-router thinks the application is up, but in reality it is stopped, and
the call goes unservised. This can be overcome easily by introducing a
worker-side supplement of spapi-router (remember, worker does not need
spapi-router to function; only the calling side does). That supplementary
application would send messages 'shutting down, now forget about me' to
spapi-router listeners, which would mean a clean drain and no unserviced calls.

.. [1] http://erlang.org/pipermail/erlang-questions/2012-February/064294.html
.. [2] http://cloudi.org/
.. [3] http://github.com/uwiger/gproc
