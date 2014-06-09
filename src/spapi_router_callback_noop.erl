%%% @doc Minimal spapi-router callback module example
-module(spapi_router_callback_noop).
-behaviour(spapi_router_callback).
-export([new_resource/2, lost_resource/2, measure/3, success/2, failure/2]).

measure({_Service, _Module, _Function}, Fun, _Opts) ->
    Fun().

success({_Service, _Module, _Function}, _Opts) ->
    ok.

failure({_Service, _Module, _Function}, _Opts) ->
    ok.

new_resource({_Service, _Node}, _Opts) ->
    ok.

lost_resource({_Service, _Node}, _Opts) ->
    ok.
