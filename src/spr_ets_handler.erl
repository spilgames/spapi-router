-module(spr_ets_handler).

-behaviour(gen_server).

-include("defs.hrl").

%% API
-export([
    get_one_node/1,
    get_all_nodes/1,
    update_host_names/0,
    update_host_names/1,
    get_host_node_names/1,
    set_node_down/1,
    reload_world_list/0,
    start_link/2
]).

%% TEST API
-ifdef('TEST').
    -export([
         create_ets_table/0,
         get_nodes_applications/1,
         get_nodes_applications/2,
         do_reload_workers_list/1,

         update_routing_table/3,
         get_current_nodes/2,

         get_host_names_config/0,
         resource_cb/2,

         compile_worker_nodes/1,
         gather_nodes/2,
         requested_hostname/2
        ]).
-endif.
-export([ rpc_call/4 ]). % test artifact

% GEN_SERVER API
-export([init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-compile({inline,[pick_random/1]}).


%% ====================================================================
%% TYPES
%% ====================================================================

-type resource_name() :: atom() .
-type resource_to_nodes() :: dict() .
-type nodes_to_resources() :: dict() .
-type hostname() :: atom() .
-type node_name() :: atom() .
-type nodes() :: [ atom() ] .

-type app_name() :: atom() .
-type app_description() :: string() .
-type app_version() :: string() .
-type application() :: {app_name(), app_description(), app_version()} .

% Values from the configuration
-type config_workers_node() :: string()|binary() .
-type config_workers_worker() :: string() | binary() | atom() .
-type config_workers() :: [{config_workers_node(), [config_workers_worker()]}].

% Config passed in:
-type worker_config() :: [{workers, config_workers() | undefined} |
    {worker_nodes, any()} | {worker_prefixes, any()}] .
-type interval_config() :: [{world_monitor_interval_ms | worker_monitor_interval_ms |
    hosts_monitor_interval_ms, non_neg_integer()}].

-type wn_mps() :: [re:mp() | {re:mp(), [atom()]}].

-type state() :: #state{}.

%% ====================================================================
%% API
%% ====================================================================

%% @doc Get one node that runs the requested Service
-spec get_one_node(atom()) -> {'error','no_node'} | {'ok',node_name()}.
%% @end
get_one_node(ServiceName) when is_atom(ServiceName) ->
    Nodes = ets:lookup(?ETS_NODES_TABLE_NAME, ServiceName),
    case Nodes of
        [] ->
            {error, no_node};
        [{ServiceName, [{_,OneNode}]}] ->
            {ok, OneNode};
        [{ServiceName, ManyNodes}]  ->
            %% TODO: efficient to recalculate local name everytime?
            [_, LocalHostName] = string:tokens(erlang:atom_to_list(node()), "@"),

            LocalNodes = proplists:get_all_values(LocalHostName, ManyNodes),

            case LocalNodes of
                [SingleLocalNode] ->
                    {ok, SingleLocalNode};
                [] ->
                    {_, E} = pick_random(ManyNodes),
                    {ok, E};
                _ ->
                    {ok, pick_random(LocalNodes)}
            end
    end.

%% @doc Get all the available nodes that run the requested Service
-spec get_all_nodes(atom()) -> {'ok', [node_name()]} | {error, no_node}.
%% @end
get_all_nodes(ServiceName) when is_atom(ServiceName) ->
    Nodes = ets:lookup(?ETS_NODES_TABLE_NAME, ServiceName),
    case Nodes of
        [] ->
            {error, no_node};
        [{ServiceName, ServiceNodes}] when is_list(ServiceNodes) ->
            FilteredServiceNodes = [N || {_, N} <- ServiceNodes],
            {ok, FilteredServiceNodes}
    end.

%% @doc Update the host names. Be careful when using this operation, as the
%% lists of hosts will periodically get reloaded from config.
-spec update_host_names([atom()]) -> ok.
%% @end
update_host_names(Hostnames) when is_list(Hostnames) ->
    gen_server:call(?MODULE, {update_host_names, Hostnames}).

%% @doc Force reloading of hostnames from the default source. This will only be applied
%% when the world is scanned again.
-spec update_host_names() -> ok.
%% @end
update_host_names() ->
    HostNames = get_host_names_config(),
    update_host_names(HostNames).

%% @doc Returns names of nodes on host.
-spec get_host_node_names(string() | atom()) ->
    {ok, [{string(), non_neg_integer()}]} | {error, any()}.
%% @end
get_host_node_names(Host) ->
    net_adm:names(Host).

%% @doc Removes a node from the routing table, thus immediately no requests
%% will be sent to the removed node.
-spec set_node_down(node()) -> ok.
%% @end
set_node_down(Node) ->
    gen_server:call(?MODULE, {set_node_down, Node}).

%% @doc Forces rescanning the whole world. This can be useful if you
%% updated the host_names and don't want to wait for the next world rescan.
%% Note that this is a blocking call (and can take a while).
-spec reload_world_list() -> ok.
%% @end
reload_world_list() ->
    gen_server:call(?MODULE, reload_world_list, infinity).

%% @doc Starts this gen_server.
%% To be called from the supervisor. ServiceMonitorFreq is in ms.
-spec start_link(interval_config(), worker_config()) ->
    'ignore' | {'error',_} | {'ok', pid()}.
%% @end
start_link(IntervalConfig, WorkerConfig) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE,
        [IntervalConfig, WorkerConfig], []).

%% ====================================================================
%% gen_server callbacks
%% ====================================================================

%% @private
-spec init([
            interval_config() | worker_config()
           ]) ->
        {'ok', #state{nodes::[],
               ets_nodes_table::atom() | ets:tid(),
               workers::[],
               host_names::maybe_improper_list(),
               reload_workers_tref::timer:tref(),
               reload_world_tref::timer:tref(),
               reload_hosts_tref::timer:tref()
        }
      }.
init([IntervalConfig, WorkerConfig]) ->
    % Create the ETS table
    EtsNodesTable = create_ets_table(),
    HostNames = get_host_names_config(),
    Workers = proplists:get_value(workers, WorkerConfig),
    CompiledWorkerNodes = compile_worker_nodes(Workers),
    %% Setup all the timers
    WorldMonInterval = proplists:get_value(world_monitor_interval_ms, IntervalConfig),
    WorkersMonInterval = proplists:get_value(worker_monitor_interval_ms, IntervalConfig),
    {ok, TrefWorld} = timer:send_interval(WorldMonInterval, ?MODULE, reload_world_list),
    {ok, TrefWorkers} = timer:send_interval(WorkersMonInterval, ?MODULE, reload_nodes_missing_apps),
    InitialState = #state{
        ets_nodes_table=EtsNodesTable,
        reload_workers_tref=TrefWorkers,
        reload_world_tref=TrefWorld,
        host_names=HostNames,
        re_worker_nodes=CompiledWorkerNodes,
        workers=[]
        },
    %% Load the initial state
    LoadedState = do_reload_world_list(InitialState),
    {ok, LoadedState}.

%% @private
-spec handle_call(_,_,_) -> {'noreply',_} | {'reply',_,#state{}}.
handle_call(list_workers, _From, #state{workers=Workers}=State) ->
    {reply, Workers, State};
handle_call({list_workers, App}, _From, #state{ets_nodes_table=Ets}=State) ->
    Workers = list_worker_nodes(Ets, App),
    {reply, Workers, State};
handle_call(list_nodes, _From, #state{nodes=Nodes}=State) ->
    {reply, Nodes, State};
handle_call(list_hosts, _From, #state{host_names=Hosts}=State) ->
    {reply, Hosts, State};
handle_call({set_node_down, Node}, _From, State) ->
    lager:notice("set_node_down invoked for node '~p'", [Node]),
    NewState = remove_nodedown(Node, State),
    {reply, ok, NewState};
handle_call(reload_world_list, _From, State) ->
    lager:notice("reload_world_list invoked", []),
    NewState = do_reload_world_list(State),
    {reply, ok, NewState};
handle_call({update_host_names, Hostnames}, _From, #state{host_names=OldHostnames}=State) ->
    _ = log_update_host_names(Hostnames, OldHostnames),
    {reply, ok, State#state{host_names=Hostnames}};
handle_call(_Request, _From, State) ->
    lager:error("ignored ~p", [_Request]),
    {noreply, State}.

%% @private
-spec handle_cast(_,_) -> {'noreply',_}.
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(reload_nodes_missing_apps, State) ->
    NewState = do_reload_nodes_missing_apps(State),
    {noreply, NewState};
handle_info(reload_workers_list, State) ->
    NewState = do_reload_workers_list(State),
    {noreply, NewState};
handle_info(reload_world_list, State) ->
    NewState = do_reload_world_list(State),
    {noreply, NewState};
handle_info({nodedown, Node}, State) ->
    lager:info("{nodedown: '~p'}", [Node]),
    NewState = remove_nodedown(Node, State),
    {noreply, NewState};
handle_info(Info, State) ->
    lager:error("Unhandled: ~p", [Info]),
    {noreply, State}.

%% @private
-spec terminate(_,_) -> 'ok'.
terminate(_Reason, _State) ->
    ok.

%% @private
-spec code_change(_,_,_) -> {'ok',_}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ====================================================================
%% Internal functions
%% ====================================================================

%% @private
%% @doc Pick a random element from a list of elements.
-spec pick_random([Element::term()]) -> Element::term().
%% @end
pick_random(List) ->
    _ = random:seed(os:timestamp()),
    lists:nth(random:uniform(length(List)), List).

%% @private
%% @doc List which Erlang nodes are running a particular application.
-spec list_worker_nodes(ets:tid(), atom()) -> [node()].
%% @end
list_worker_nodes(Ets, App) ->
    case ets:lookup(Ets, App) of
        [{App, L}] when is_list(L) ->
          [E || {_,E} <- L];
        [] ->
          []
    end.

%% @private
%% @doc Log when we update the hostnames.
-spec log_update_host_names(list(), list()) -> any().
%% @end
log_update_host_names(Hostnames, OldHostnames) ->
    if
        Hostnames =:= OldHostnames ->
            ok;
        true ->
            lager:notice("Updating host names: ~p -> ~p", [OldHostnames, Hostnames])
    end.

%% @private
%% @doc Create the ETS routing table.
-spec create_ets_table() -> ets:tid() | atom().
%% @end
create_ets_table() ->
    ets:new(?ETS_NODES_TABLE_NAME, [named_table, set, protected, {read_concurrency, true}]).

%% @private
%% @doc Compile regular expressions for worker_nodes. The REs are used
%% for matching nodes on hosts to requested worker_nodes.
-spec compile_worker_nodes(config_workers()) -> wn_mps().
%% @end
compile_worker_nodes(WorkerNodesReExpressions) ->
    lists:map(fun({WorkerNodeRE, Services}) ->
        {ok, MP} = re:compile(WorkerNodeRE),
        {MP, [ spr_util:atom(Service) || Service <- Services] }
    end, WorkerNodesReExpressions).

%% @private
%% @doc run application:which_applications() on each node and return
%%      the results. If the node is down, do not return the node.
-spec get_nodes_applications([atom()]) -> [{atom(), [ application() ]}] .
%% @end
get_nodes_applications(Nodenames) ->
    NodesApplications = lists:foldl(fun(Nodename, Acc) ->
            case safe_which_applications(Nodename) of
                [] ->
                    Acc;
                Apps ->
                    [{ Nodename, Apps }] ++ Acc
            end
        end,
        [],
        Nodenames),
    lists:reverse(NodesApplications).

%% @private
%% @doc Safe call of which_applications, to ensure a crashing node
%% doesn't bring down the whole gen_server. Crashes can happen when
%% the remote node shuts down exactly when we try to invoke
%% application:which_appplications/0 .
-spec safe_which_applications(atom()) -> [application()].
%% @end
safe_which_applications(Nodename) ->
    try
        case ?MODULE:rpc_call(Nodename, application, which_applications, []) of
            {badrpc, _} -> [];
            Result -> Result
        end
    catch
        _:_ ->
            []
    end.

%% @private
%% @doc Testing artifact, so it can be mocked.
-spec rpc_call(node(), atom(), atom(), list()) -> {badrpc, any()} | any().
%% @end
rpc_call(N, M, F, A) ->
    rpc:call(N, M, F, A).

%% @private
%% @doc Get node applications
%% returns {dict(), dict()} for all nodes where "service" is running
%% First dict() : Node        -> [Services]
%% Second dict(): Service     -> [Nodes]
%% See http://www.erlang.org/doc/apps/kernel/application.html#which_applications-0
-spec get_nodes_applications([{node_name(), [ application() ]}], wn_mps()) ->
          {nodes_to_resources(), resource_to_nodes()}.
%% @end
get_nodes_applications(NodesApplications, ReWorkerNodes) when is_list(ReWorkerNodes) ->
    lists:foldl(fun({Nodename, Applications}, {NodeToServicesAcc, ServiceToNodesAcc}) ->
            Services = case requested_hostname(Nodename, ReWorkerNodes) of
                {true, RequestedApps} ->
                    RevServices = lists:foldl(fun({Appname, _, _}, ServiceAcc) ->
                                case lists:member(Appname, RequestedApps) of
                                    true -> [Appname|ServiceAcc];
                                    _ -> ServiceAcc
                                end
                        end,
                        [],
                        Applications),
                    lists:reverse(RevServices);    %keep the order the same
                {false, _} ->
                    []
            end,
            case Services of
                [] ->
                    {NodeToServicesAcc, ServiceToNodesAcc};
                _ ->
                    {
                        dict:store(Nodename, Services, NodeToServicesAcc),
                        lists:foldl(fun(Serv, DictAcc) ->
                                            dict:append(Serv, Nodename, DictAcc)
                                  end,
                                ServiceToNodesAcc,
                                Services)
                    }
            end
    end,
    {dict:new(), dict:new()},
    NodesApplications).

%% @private
%% @doc Quick check that does nothing if no down nodes are detected and
%% all nodes are running all applications.
%% Otherwise it will attempt to reload the workers list.
-spec do_reload_nodes_missing_apps( #state{} ) -> #state{}.
%% @end
do_reload_nodes_missing_apps(#state{nodes_down=[], nodes_missing_workers=[]} = State) ->
    State;
do_reload_nodes_missing_apps(#state{nodes_down=NodesDown,
        nodes_missing_workers=NodesMissingWorkers} = State) ->
    lager:warning("Triggering reload of workers list; nodes_down: ~p; nodes_missing_workers: ~p",
        [NodesDown, NodesMissingWorkers]),
    do_reload_workers_list(State).

%% @private
%% @doc checks all nodes for running services and
%%         stores them in an ETS table. See Eunit tests for examples
-spec do_reload_workers_list( #state{} ) -> #state{}.
%% @end
do_reload_workers_list(#state{nodes=Nodes, nodes_down=NodesDown} = State) ->
    NodesDownCheck = [Node || {Node, X} <- NodesDown, X < 10],
    NodesDownClean = [{Node,X+1} || {Node, X} <- NodesDown, X < 10],
    do_reload_workers_list(NodesDownCheck ++ Nodes, State#state{nodes_down=NodesDownClean}).

%% @private
%% @doc checks all nodes for running services and
%%      stores them in an ETS table. See Eunit tests for examples
-spec do_reload_world_list( #state{} ) -> #state{}.
%% @end
do_reload_world_list(#state{re_worker_nodes=[]} = State) ->
    State;
do_reload_world_list(#state{host_names=HostNames, re_worker_nodes=ReWorkerNodes} = State) ->
    Nodes = gather_nodes(HostNames, ReWorkerNodes),
    % Use ping to connect the nodes.
    lists:foreach(fun(Node) ->
        case net_adm:ping(Node) of
          pong ->
            ok;
          pang ->
            lager:warning("Couldn't connect to node ~p", [Node])
        end
      end, Nodes),
    do_reload_workers_list(Nodes, State).

%% @private
%% @doc Gather nodes that match the requested worker_nodes specifications on all configured hosts.
-spec gather_nodes([string() | atom()], wn_mps()) -> [atom()].
%% @end
gather_nodes(HostNames, ReWorkerNodes) ->
    lists:foldl(fun(HostName, Acc) ->
          AtHostNameString = "@" ++ spr_util:str(HostName),
          case ?MODULE:get_host_node_names(HostName) of
            {ok, NodeNamesOnHost} ->
                lists:flatmap(fun({NodeName, _}) ->
                    case requested_hostname(NodeName, ReWorkerNodes) of
                        {true, _} ->
                            [spr_util:atom(spr_util:str(NodeName) ++ AtHostNameString)];
                        {false, _} ->
                            []
                    end
                  end,
                  NodeNamesOnHost) ++ Acc;
            {error, Reason} ->
                lager:error("Problem reloading nodes from host ~p : ~p", [HostName, Reason]),
                Acc
          end
      end,
      [],
      HostNames).

%% @private
%% @doc check if this NodeName is requested.
-spec requested_hostname(string() | atom(), wn_mps()) -> {boolean(), [resource_name()]}.
%% @end
requested_hostname(NodeName, ReWorkerNodes) when is_atom(NodeName) ->
    requested_hostname(spr_util:str(NodeName), ReWorkerNodes);
requested_hostname(NodeName, ReWorkerNodes) ->
    lists:foldl(
          fun(NodeToWorkers, Acc) ->
              check_nodename(NodeName, NodeToWorkers, Acc)
          end,
          {false, []},
          ReWorkerNodes).

%% @private
%% @doc Check if a nodename is required and if so, which workers are running on it.
-spec check_nodename(string() | atom(), [atom()], {boolean(), [resource_name()]}) ->
    {boolean(), [resource_name()]}.
%% @end
check_nodename(_, _, {true, Workers}) -> {true, Workers};
check_nodename(NodeName, {RequestedNodeName, RequestedWorkers}, {false, _}) ->
    case re:run(NodeName, RequestedNodeName) of
      {match, _} -> {true, RequestedWorkers};
      _ -> {false, []}
    end.

%% @private
%% @doc Reload workers:
%%  * Find which applications run on which nodes
%%  * Check if there are new nodes, if so update the routing table (ETS)
%%  * Check which nodes do not have all requested applications
%%  * Update the state with the set of current nodes and nodes with missing workers.
-spec do_reload_workers_list([node()], state()) -> state().
%% @end
do_reload_workers_list(Nodes, #state{nodes=OldNodes,
                              workers=OldWorkers,
                              ets_nodes_table=EtsNodesTable,
                              re_worker_nodes=ReWorkerNodes} = State) ->
    NodesApplications = get_nodes_applications(Nodes),
    % lookup workers
    {NodesToWorkers, WorkersToNodes} = get_nodes_applications(NodesApplications, ReWorkerNodes),
    % log new nodes
    CurrentNodes = get_current_nodes([NodesToWorkers], OldNodes),
    CurrentWorkers = update_routing_table(WorkersToNodes, OldWorkers, EtsNodesTable),
    % check which nodes do not have all of the requested apps running
    NodesMissingWorkers = get_nodes_missing_workers(NodesToWorkers, ReWorkerNodes),
    State#state{nodes=CurrentNodes,
                nodes_missing_workers=NodesMissingWorkers,
                workers=CurrentWorkers}.

%% @private
%% @doc Figure out which nodes are not running all desired applications.
-spec get_nodes_missing_workers(nodes_to_resources(), wn_mps()) -> ok.
%% @end
get_nodes_missing_workers(NodesToWorkers, ReWorkerNodes) ->
    dict:fold(fun(Node, Workers, Acc) ->
        case requested_hostname(Node, ReWorkerNodes) of
          {true, ReWorkers} ->
             AllRequestedWorkersRunning = length(ReWorkers) =:= length(Workers),
             if
                AllRequestedWorkersRunning ->
                    Acc;
                true ->
                    {MissingReWorkers, _} = spr_util:differences(ReWorkers, Workers),
                    [{Node, MissingReWorkers}|Acc]
             end;
          _ ->
            Acc
        end
    end,
    [],
    NodesToWorkers).

%% @private
%% @doc Remove a down node. Normally this is called because a monitored
%%      node went offline and received a 'nodedown'. It just removes the
%%      node from the ETS table and updates the state. Doesn't force
%%      rescanning the network.
-spec remove_nodedown( atom() , #state{} ) -> #state{}.
%% @end
remove_nodedown(RemoveNode, #state{nodes=OldNodes,
        nodes_down=OldNodesDown,
        re_worker_nodes=ReWorkerNodes,
        ets_nodes_table=EtsResourceTable} = State) ->
    NewNodes = [Node || Node <- OldNodes, Node =/= RemoveNode],
    NodesDown = lists:usort(fun({A,_}, {B,_}) -> A =:= B end, [{RemoveNode, 0} | OldNodesDown]),
    case requested_hostname(RemoveNode, ReWorkerNodes) of
        {true, Applications} ->
            remove_nodes_routing_table({RemoveNode, Applications},
                EtsResourceTable),
            State#state{nodes=NewNodes, nodes_down=NodesDown};
        {false, _} ->
            State
    end.

%% @private
%% @doc get current nodes
-spec get_current_nodes( [ nodes_to_resources() ] , [ nodes() ]) -> [ nodes() ].
%% @end
get_current_nodes(NewNodesDicts, OldNodes) ->
    %log added / removed nodes
    CurrentNodesTemp = [dict:fetch_keys(NewNodesDict) || NewNodesDict <- NewNodesDicts],
    CurrentNodes = lists:usort(lists:flatten(CurrentNodesTemp)),

    {AddedNodes, RemovedNodes} = spr_util:differences(CurrentNodes, OldNodes),
    _ = case AddedNodes of
        [] ->
            ok;
        _ ->
            _ = [ erlang:monitor_node(AddedNode, true) || AddedNode <- AddedNodes ],
            lager:info("Added nodes: ~p", [AddedNodes])
    end,
    _ = case RemovedNodes of
        [] ->
            ok;
        _ ->
            lager:info("Removed nodes: ~p", [RemovedNodes])
    end,
    CurrentNodes.

%% @private
%% @doc Remove nodes from the routing table and notifies the callback-module.
-spec remove_nodes_routing_table({node(), [resource_name()]}, ets:tab()) -> ok.
%% @end
remove_nodes_routing_table({RemovedNode, AppsOnRemovedNode}, EtsResourceTable) ->
    %Figure out which applications it was possibly running
    {Callbacks, ToUpdateAppsHostNodes} = lists:foldl(fun(AppOnRemovedNode,{CbAcc, AppNodesAcc}=Acc) ->
        % Lookup all nodes for this application
        HostNodes = case ets:lookup(EtsResourceTable, AppOnRemovedNode) of
            [{_, L}] when is_list(L) ->
                L;
            [] ->
                []
        end,
        % Test if the node that is down was used for that application in the ets table
        {LostCbs, NewHostNodes} = lists:foldl(fun({_, Node}=Entry, {LostAcc, RemainingAcc}) ->
              case Node of
                RemovedNode -> {[{lost, {AppOnRemovedNode, RemovedNode}}|LostAcc], RemainingAcc};
                _ -> {LostAcc, [Entry | RemainingAcc]}
              end
          end,
          {[], []},
          HostNodes
          ),
        % Only if we lost something (it was used) we need to write to ETS
        case LostCbs of
            [] ->
              Acc;
            _ ->
              { LostCbs ++ CbAcc, [{AppOnRemovedNode, NewHostNodes} | AppNodesAcc] }
        end
      end,
      {[], []},
      AppsOnRemovedNode),
    lists:foreach(fun(ToUpdateAppHostNodes) ->
        true = ets:insert(EtsResourceTable, ToUpdateAppHostNodes)
    end,
    ToUpdateAppsHostNodes),
    % We invoke the callbacks after the ets has been properly updated
    lists:foreach(fun ({Type, {_, _}=Res}) ->
                resource_cb(Type, Res)
        end, Callbacks),
    ok.

%% @doc returns current resources and updates ETS routing table
-spec update_routing_table(resource_to_nodes(), [resource_name()], ets:tab()) -> [ atom() ].
%% @private
update_routing_table(ResourceToNodes, OldResources, EtsResourceTable) ->
    CurrentResources = dict:fetch_keys(ResourceToNodes),
    {_AddedResources, RemovedResources} = spr_util:differences(CurrentResources, OldResources),
    % We update the ets for everything we have found on the network. We accumulate the callbacks
    Callbacks1=lists:foldl( fun({Resource, NodesRunningResource}, CallbacksAcc) ->
                Cbs = case ets:lookup(EtsResourceTable, Resource) of
                    [] ->
                        lists:foldl(fun (Node, Acc) ->
                                lager:info("Added resource: ~p",[{Resource, Node}]),
                                [{new, {Resource, Node}} | Acc]
                            end, [], NodesRunningResource);
                    [{Resource, OldNodesForResource}] ->
                        AllOldNodesForResource = [ N || {_, N} <- OldNodesForResource],
                        {AddedNodes, RemovedNodes} = spr_util:differences(NodesRunningResource,
                            AllOldNodesForResource),
                        AddedCallbacks=lists:foldl(fun (Node, Acc) ->
                                lager:info("Added resource: ~p",[{Resource, Node}]),
                                [{new, {Resource, Node}}|Acc]
                            end, [], AddedNodes),
                        LostCallbacks=lists:foldl(fun (Node, Acc) ->
                                lager:info("Lost resource: ~p",[{Resource, Node}]),
                                [{lost, {Resource, Node}}|Acc]
                            end, [], RemovedNodes),
                        AddedCallbacks ++ LostCallbacks
                end,
                NodesRunningResource2 = lists:map(fun(ANode) ->
                    [_, HostName] = string:tokens(erlang:atom_to_list(ANode), "@"),
                    {HostName, ANode}
                  end,
                  NodesRunningResource),
                ets:insert(EtsResourceTable, {Resource, NodesRunningResource2}),
                Cbs ++ CallbacksAcc
            end, [], dict:to_list(ResourceToNodes)),
    % We remove from the ets the entries for resources that are not available anymore (not a lost
    % node for a resource, but a whole resource lost). We accumulate the callbacks
    Callbacks2 = lists:foldl(fun (Res, CallbacksAcc) ->
                [{Res, Nodes}] = ets:lookup(EtsResourceTable, Res),
                Cbs = lists:foldl(fun ({_,N}, Acc) ->
                            lager:info("Lost resource: ~p", [{Res, N}]),
                            [{lost, {Res, N}}|Acc]
                    end, [], Nodes),
                ets:delete(EtsResourceTable, Res),
                Cbs ++ CallbacksAcc
            end, [], RemovedResources),
    % We invoke the callbacks after the ets has been properly updated
    lists:foreach(fun ({Type, {_, _}=Res}) ->
                resource_cb(Type, Res)
        end, Callbacks1++Callbacks2),
    CurrentResources.

%% @private
%% @doc Executes callbacks in the callback module for new or lost resources.
-spec resource_cb(new | lost, {atom(), node()}) -> any().
%% @end
resource_cb(Type, Resource) ->
    lager:debug("running ~p resource callback for ~p", [Type, Resource]),
    case Type of
        new -> spr_util:maybe_callback(new_resource, [Resource]);
        lost -> spr_util:maybe_callback(lost_resource, [Resource])
    end.

%% @private
%% @doc returns a list of hostnames, either directly from config (host_names) or via an HTTP call
%% returning them line separated or by reading an erlang consultable file.
-spec get_host_names_config() -> [ hostname() ].
%% @end
get_host_names_config() ->
    case application:get_env(spapi_router, host_names) of
        undefined ->
            default_hostnames();
        {ok, []} ->
            default_hostnames();
        {ok, Hosts} when is_list(Hosts) ->
            Hosts;
        {ok, {file, File}} ->
            {ok, [Hosts]} = file:consult(File),
            Hosts
    end.

%% @private
%% @doc Get the localhost's domain name as an atom().
-spec default_hostnames() -> [hostname()].
%% @end
default_hostnames() ->
    H = net_adm:localhost(),
    [spr_util:atom(H)].
