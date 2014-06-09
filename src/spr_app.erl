-module(spr_app).

-behaviour(application).

%% API
-export([start/0]).

%% Application callbacks
-export([start/2, stop/1, config_change/3]).

-include("defs.hrl").

%% ===================================================================
%% API
%% ===================================================================

%% @doc Starts the application
-spec start() -> ok | {error, any()}.
%% @end
start() ->
    lager:start(),
    application:start(spapi_router).

%% ===================================================================
%% Application callbacks
%% ===================================================================

%% @private
-spec start(normal | {takeover | failover, Node::node()}, term()) ->
    {ok, Pid::pid()} | {ok, Pid::pid(), State::term()} | {error, Reason::any()}.
start(_StartType, _StartArgs) ->
    case application:get_env(callback_module, undefined) of
        undefined ->
            ok;
        {ok, Mod} ->
            ok = validate_callback_module(Mod)
    end,
    WorldMonitorInterval = default_env(
            world_monitor_interval_ms, ?DEFAULT_WORLD_SCAN_INTERVAL_MS),
    ServicesMonitorInterval = default_env(
            worker_monitor_interval_ms, ?DEFAULT_WORKER_SCAN_INTERVAL_MS),
    HostsMonitorInterval = default_env(
            hosts_monitor_interval_ms, ?DEFAULT_HOSTS_SCAN_INTERVAL_MS),
    Workers = default_env(workers, []),
	Config=[
        [
            {world_monitor_interval_ms, WorldMonitorInterval},
            {worker_monitor_interval_ms, ServicesMonitorInterval},
            {hosts_monitor_interval_ms, HostsMonitorInterval}
        ],
        [
            {workers, Workers}
        ]
    ],
    spr_sup:start_link(Config).

%% @doc checks whether the Mod is loaded, exports the needed callbacks and asks
%% it to validate its own options
validate_callback_module(Mod) ->
    LoadedRes = code:ensure_loaded(Mod),
    MissingExports =
        lists:dropwhile(fun ({Fun, Ar}) -> erlang:function_exported(Mod, Fun, Ar) end,
            spapi_router_callback:behaviour_info(callbacks)
        ),
    case {LoadedRes, MissingExports} of
        {{module, _}, []} ->
            ok;
        {{error, _}, _} ->
            {error, {module_not_loaded, Mod}};
        {_, Exps} ->
            {error, {missing_callbacks, Exps}}
    end.

%% @private
-spec stop(State::term()) -> ok.
stop(_State) ->
    ok.

default_env(Key, Default) ->
    case application:get_env(spapi_router, Key) of
        undefined -> Default;
        {ok, Val} -> Val
    end.


config_change(_, _, _) ->
    spr_ets_handler:update_host_names().
