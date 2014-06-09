-record(state, {
	    nodes = [],
        nodes_down = [],                    % {Node, Tref}
	    ets_nodes_table = undefined,
	    workers = [],
        nodes_missing_workers = [],         % [atom()] nodes that do not run all requested workers
        host_names = undefined,             % [atom()] representing valid names for localhost
        reload_workers_tref,                %
        reload_hosts_tref,
        reload_world_tref,
        re_worker_nodes = []                % which nodes to scan. Empty list means scan nothing
}).

-define(spapi_router_state, #state{}).

-define(ETS_NODES_TABLE_NAME, worker_nodes).

-define(DEFAULT_WORLD_SCAN_INTERVAL_MS,     20000).     % 20 seconds
-define(DEFAULT_WORKER_SCAN_INTERVAL_MS,     4000).     % 4 seconds
-define(DEFAULT_HOSTS_SCAN_INTERVAL_MS,     30000).     % 30 seconds
