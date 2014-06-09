%%^ @doc spapi-router callback module template.
-module(spapi_router_callback_example).
-behaviour(spapi_router_callback).

-export([new_resource/2, lost_resource/2, measure/3, success/2, failure/2]).

-ignore_xref([{estatsd, increment, 1}, {estatsd, timing, 2}]).

%% =============================================================================
%% Callbacks
%% =============================================================================

measure({_, _, _}=Key, Fun, Opts) ->
    {Time, Ret} = timer:tc(Fun),
    estatsd:timing(key(Key, Opts), round(Time/1000)),
    Ret.

success({_, _, _}=Key, Opts) ->
    estatsd:increment(key(Key, Opts) ++ ".ok").

failure({_, _, _}=Key, Opts) ->
    estatsd:increment(key(Key, Opts) ++ ".error").

new_resource({Service, Node}, _Opts) ->
    lager:info("New resource: ~s/~s", [Service, Node]).

lost_resource({Service, Node}, _Opts) ->
    lager:info("Lost resource: ~s/~s", [Service, Node]).

%% =============================================================================
%% Helpers
%% =============================================================================

key({S, M, F}, Opts) ->
    Prefix = proplists:get_value(statsd_prefix, Opts, ""),
    Prefix ++ lists:flatten(io_lib:format("~s.~s.~s", [S, M, F])).
