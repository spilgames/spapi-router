-module(spapi_router_callback_eunit).
-behaviour(spapi_router_callback).

-include_lib("eunit/include/eunit.hrl").

-export([dow/0, measure/3, success/2, failure/2, new_resource/2,
         lost_resource/2]).

-define(TAB, spapi_router_callback_eunit_call_time).

callback_test_() ->
    WriteTo = [{write_to, ?TAB}],
    {setup,
     fun setup/0,
     fun cleanup/1,
     [
      fun test_measure/0,

      {foreach,
       fun() ->
               ets:delete_all_objects(?TAB),
               application:set_env(spapi_router, callback_module_opts, WriteTo)
       end,
       fun(_) ->
               application:unset_env(spapi_router, callback_module_opts)
       end,
       [
        fun test_opts/0,
        fun test_opts_lost_resource/0
       ]
      }
     ]
    }.


test_measure() ->
    ?assertEqual(friday, spr_router:call(kernel, ?MODULE, dow, [])),
    CallTime = ets:lookup_element(?TAB, call_time, 2),
    ?assert(CallTime < 10000).  % local call must take <10ms.

test_opts() ->
    ?assertEqual(friday, spr_router:call(kernel, ?MODULE, dow, [])),
    ?assert(ets:lookup_element(?TAB, test_measure, 2)),
    ?assert(ets:lookup_element(?TAB, test_success, 2)).

test_opts_lost_resource() ->
    {ok, Slave1} = slave:start('127.0.0.1', 'kernel_2',"", no_link, erl),
    rpc:call(Slave1, application, start, [kernel]),
    pong = net_adm:ping(Slave1),
    spr_ets_handler:reload_world_list(),
    ?assert(ets:lookup_element(?TAB, test_new_resource, 2)),
    ok = slave:stop(Slave1),
    timer:sleep(100),
    ?assert(ets:lookup_element(?TAB, test_lost_resource, 2)).

dow() ->
    friday.

measure({kernel, ?MODULE, dow}, Fun, Opts) ->
    {Time, Ret} = timer:tc(Fun),
    ets:insert(?TAB, {call_time, Time}),
    write_to(Opts, {test_measure, true}),
    Ret.

success({_Service, _Module, _Function}, Opts) ->
    write_to(Opts, {test_success, true}),
    ok.

failure({_Service, _Module, _Function}, _Opts) ->
    ok.

new_resource({_Service, _Node}, Opts) ->
    write_to(Opts, {test_new_resource, true}),
    ok.

lost_resource({_Service, _Node}, Opts) ->
    write_to(Opts, {test_lost_resource, true}),
    ok.


setup() ->
    _ = os:cmd("epmd"),
    error_logger:tty(false),
    ets:new(?TAB, [named_table, public]),
    {ok, _} = net_kernel:start(['kernel_1@127.0.0.1', longnames]),
    ok = application:load(spapi_router),
    ok = application:set_env(spapi_router, callback_module, ?MODULE),
    ok = application:set_env(spapi_router, host_names, ['127.0.0.1']),
    ok = application:set_env(spapi_router, workers, [{"", ["stdlib", "kernel"]}]),
    spr_app:start().

cleanup(_) ->
    ets:delete(?TAB),
    ok = net_kernel:stop(),
    ok = application:stop(spapi_router),
    ok = application:unload(spapi_router).

write_to(Opts, What) ->
    case proplists:get_value(write_to, Opts) of
        undefined -> ok;
        T -> ets:insert(T, What)
    end.
