-module(spr_router_eunit).
-include_lib("eunit/include/eunit.hrl").

get_call_type_test_() ->
    [
        ?_assertEqual({call, 2500} , spr_router:get_call_type([{timeout, 2500}, {response, required}])),
        ?_assertEqual({cast, 100} , spr_router:get_call_type([{timeout, 500}, {response, never}])),
        ?_assertEqual({call, 500} , spr_router:get_call_type([{timeout, 500}, {response, optional}])),
        ?_assertEqual({cast, 36} , spr_router:get_call_type([{response, never}, {percentage, 36}])),
        ?_assertEqual({call, 750} , spr_router:get_call_type([{timeout, 750}]))         %optional default, but no wrq set
    ].

list_workers_test_() ->
    {setup,
        fun() ->
                setup_logging(),
                setup_epmd(),
                ok = application:set_env(spapi_router, workers, []),
                ok = application:start(spapi_router),
                []
        end,
        fun cleanup/1,
        fun (_) ->
                [
                    ?_assertEqual([],   spr_router:list_workers()),
                    ?_assertEqual([],   spr_router:list_workers(myapp)),
                    ?_assertEqual([],   spr_router:list_nodes()),
                    ?_assertMatch([_|_],  spr_router:list_hosts())
                ]
        end}.

cleanup(Slaves) ->
    lists:foreach(fun slave:stop/1, Slaves),
    net_kernel:stop(),
    application:stop(spapi_router),
    application:unload(spapi_router).

%% This test relies on epmd already running, thus is starts an epmd daemon.
%% Note that this epmd daemon is NOT cleaned up.
call_test_() ->
    {setup,
        fun() ->
                setup_logging(),
                setup_epmd(),
                application:set_env(spapi_router, host_names, ['127.0.0.1']),
                application:set_env(spapi_router, workers, [{"", ["stdlib", "kernel"]}]),
                net_kernel:start(['kernel_1@127.0.0.1', longnames]),
                {ok, Slave1} = slave:start('127.0.0.1', 'kernel_2',"", no_link, erl),
                rpc:call(Slave1, application, start, [kernel]),
                pong = net_adm:ping(Slave1),
                ok = application:start(spapi_router),
                [Slave1]
        end,
        fun cleanup/1,
        fun (_) ->
                CallSpecFun = fun(X) -> {kernel, kernel, module_info, [X], [{timeout, 100}]} end,
                KernelExports = CallSpecFun(exports),
                ResultKernelExports = [{start,2}, {stop,1},{config_change,3},{init,1}, {module_info,0}, {module_info,1}],
                KernelImports = CallSpecFun(imports),
                ResultKernelImports = [],
                KernelAttributes = CallSpecFun(attributes),
                %ResultKernelAttributes = [{vsn,[_]}, {behaviour,[supervisor]}],
                KernelFunctions = CallSpecFun(functions),
                ResultKernelFunctions = [{start,2}, {stop,1}, {config_change,3}, {get_error_logger_type,0}, {init,1},
                                        {get_code_args,0}, {start_dist_ac,0}, {start_boot_server,0}, {get_boot_args,0},
                                        {start_disk_log,0}, {start_pg2,0}, {start_timer,0}, {do_distribution_change,3},
                                        {is_dist_changed,3}, {do_global_groups_change,3}, {is_gg_changed,3},
                                        {module_info,0}, {module_info,1}],
                CallSpecs = [ KernelExports, KernelImports, KernelAttributes, KernelFunctions ],
                [
                    ?_assertEqual({error,spapi_router_no_node}, spr_router:call(dummy_service, module, function, [])),
                    % kernel is always running, so let's try to call it via the router (even though local node)
                    ?_assertEqual([{start,2},{stop,1},{config_change,3},{init,1},{module_info,0},{module_info,1}],
                                  spr_router:call(kernel, kernel, module_info, [exports], [{timeout, 100}])),
                    ?_assertEqual({uniform, [{start,2},{stop,1},{config_change,3},{init,1},{module_info,0},{module_info,1}]},
                                  spr_router:call_all(kernel, kernel, module_info, [exports], [{timeout, 100}])),
                    ?_assertEqual({error,spapi_router_no_node},
                                  spr_router:call_all(kernel, kernel, module_info,
                                                      [exports],
                                                      [{timeout, 100},
                                                       {nodes_matching, "none"}])),
                    ?_assertEqual({uniform, [{start,2},{stop,1},{config_change,3},{init,1},{module_info,0},{module_info,1}]},
                                  spr_router:call_all(kernel, kernel, module_info,
                                                      [exports],
                                                      [{timeout, 100},
                                                       {nodes_matching, "ernel"}])),
                    ?_assertMatch({non_uniform, [{'kernel_1@127.0.0.1', List1}, {'kernel_2@127.0.0.1', List2}]}
                        when is_list(List1) andalso is_list(List2),
                                  spr_router:call_all(kernel, application, which_applications,
                                                      [], [{timeout, 100}, {nodes_matching, "kern"}])),
                    ?_assertEqual({error, spapi_router_no_node},
                                  spr_router:call_all(unknown, kernel, module_info,
                                                      [exports], [{timeout, 100}])),
                    % we also need to test call with several targets
                    ?_assertMatch([ResultKernelExports, ResultKernelImports,
                                   [{vsn,_}, {behaviour,[supervisor]}], ResultKernelFunctions],
                                  spr_router:call(CallSpecs))
                ]
        end}.

to_run_test_() ->
    [
        ?_assertEqual(true, spr_router:to_run(100)),
        ?_assertMatch(Bool when is_boolean(Bool), spr_router:to_run(50)),
        ?_assertEqual(false, spr_router:to_run(0))
    ].

log_call_test_() ->
    [
        ?_assertEqual(ok, spr_router:log_call(1, node, module, function, [], [])),
        ?_assertMatch(_, spr_router:log_call(1, node, module, function, [], [{log_result, false}])),
        ?_assertMatch(_, spr_router:log_call(1, node, module, function, [], [{log_result, true}]))
    ].

invoke_by_type_cast_test_() ->
    [
        ?_assertEqual({error, not_executed},
            spr_router:invoke_by_type({cast, 0}, compiler, 'nonode@nohost', module, function, [], 1, [])),
        ?_assertEqual({error, no_response},
            spr_router:invoke_by_type({cast, 100}, compiler, 'nonode@nohost', module, function, [], 1, []))
    ].

invoke_by_type_call_test_() ->
    [
        ?_assertEqual({error,backend_timeout},
            spr_router:invoke_by_type({call, 0}, compiler, 'nonode@nohost', module, function, [], 1, [])),
        ?_assertMatch({error,{spapi_router_badrpc,{undef, _}}},
            spr_router:invoke_by_type({call, 100}, compiler, 'nonode@nohost', module, function, [], 1, []))
    ].

setup_logging() ->
    error_logger:tty(false).

setup_epmd() ->
    _ = os:cmd("epmd").
