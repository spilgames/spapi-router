-module(spr_ets_handler_eunit).

-behaviour(spapi_router_callback).

-include_lib("eunit/include/eunit.hrl").
-include("defs.hrl").

-define(DEMO_TABLE, demo_table).
-define(DEMO_CALLBACK_TABLE, demo_callback_table).


-export([new_resource/2, lost_resource/2, measure/3, success/2, failure/2]).

%% Dummy test to ensure epmd is running
ensure_epmd_test_() ->
    [
        ?_assertEqual(ok, ensure_epmd())
    ].

requested_hostname_test_() ->
    Workers1 = [{<<"">>, ["desired-app"]}],
    ReWorkerNodes1 = spr_ets_handler:compile_worker_nodes(Workers1),
    Workers2 = [{<<"^startlikethis">>, ["desired-app"]}],
    ReWorkerNodes2 = spr_ets_handler:compile_worker_nodes(Workers2),
    [
        ?_assertEqual({true,['desired-app']},
            spr_ets_handler:requested_hostname('bla@some.host', ReWorkerNodes1)),
        ?_assertEqual({false,[]},
            spr_ets_handler:requested_hostname('bla@some.host', [])),
        ?_assertEqual({true,['desired-app']},
            spr_ets_handler:requested_hostname('startlikethis@some.host', ReWorkerNodes2)),
        ?_assertEqual({true,['desired-app']},
            spr_ets_handler:requested_hostname('startlikethisandmore@some.host', ReWorkerNodes2)),
        ?_assertEqual({false,[]},
            spr_ets_handler:requested_hostname('notstartlikethis@some.host', ReWorkerNodes2))
    ].

gather_nodes_test_() ->
    {setup,
        fun () ->
                ok = meck:new(spr_ets_handler, [passthrough]),
                meck:expect(spr_ets_handler, get_host_node_names,
                            fun
                                ("host_badaddress") ->
                                    {error, address};
                                (_HostName) ->
                                    {ok, [{"node_a", 40001}, {"node_b", 40002}]}
                            end
                           )
        end,
        fun (_) ->
                ok = meck:unload(spr_ets_handler)
        end,
        fun (_) ->
                ReWorkerNodesA = spr_ets_handler:compile_worker_nodes([{"node_a.*", []}]),
                ReWorkerNodesB = spr_ets_handler:compile_worker_nodes([{"node_b.*", []}]),
                ReWorkerNodesAB1 = spr_ets_handler:compile_worker_nodes([{"node_.*", []}]),
                ReWorkerNodesAB2 = spr_ets_handler:compile_worker_nodes([{"node_a.*", []}, {"node_b.*", []}]),
                [
                    ?_assertEqual([], spr_ets_handler:gather_nodes(["host_badaddress"], [])),
                    % Note this test should not be called in code, because scan-world-code path is followed
                    ?_assertEqual([], spr_ets_handler:gather_nodes(["host1", "host2"], [])),
                    ?_assertEqual(['node_a@host2', 'node_a@host1'],
                      spr_ets_handler:gather_nodes(["host1", "host2"], ReWorkerNodesA)),
                    ?_assertEqual(['node_b@host2', 'node_b@host1'],
                      spr_ets_handler:gather_nodes(["host1", "host2"], ReWorkerNodesB)),
                    ?_assert(same_elements(['node_a@host2', 'node_a@host1', 'node_b@host2', 'node_b@host1'],
                      spr_ets_handler:gather_nodes(["host1", "host2"], ReWorkerNodesAB1))),
                    ?_assert(same_elements(['node_a@host2.nl', 'node_a@host1.nl', 'node_b@host2.nl', 'node_b@host1.nl'],
                      spr_ets_handler:gather_nodes(["host1.nl", "host2.nl"], ReWorkerNodesAB2)))
                ]
        end
    }.

get_one_node_locally_test_() ->
    {setup,
        fun () ->
                EtsNodesTable = spr_ets_handler:create_ets_table(),
                Service = 'demoservice',
                Node1 = 'demo@nohost',
                Node2 = 'demo@somehost',
                NodesRunningService = [{"nohost", Node1}, {"somehost", Node2}],
                ets:insert(EtsNodesTable, {Service, NodesRunningService}),
                []
        end,
        fun (_) ->
                remove_ets_table(),
                ok
        end,
        fun (_) ->
                %% Try 100 times: ensure always returns nohost (not somehost)
                Result = lists:usort(
                  lists:map(fun(_) ->
                      spr_ets_handler:get_one_node('demoservice')
                    end,
                    lists:seq(0,100))),
                [
                    ?_assertEqual([{ok,'demo@nohost'}], Result)
                ]
        end
    }.

get_one_from_several_local_nodes_test_() ->
    {setup,
        fun () ->
                EtsNodesTable = spr_ets_handler:create_ets_table(),
                Service = 'demoservice',
                Node1 = 'demo_1@nohost',
                Node2 = 'demo_2@somehost',
                Node3 = 'demo_3@nohost',
                NodesRunningService = [{"nohost", Node1}, {"nohost", Node3}, {"somehost", Node2}],
                ets:insert(EtsNodesTable, {Service, NodesRunningService}),
                []
        end,
        fun (_) ->
                remove_ets_table(),
                ok
        end,
        fun (_) ->
                %% Try 100 times: ensure it only picks demo_1 and demo_3 at nohost
                Result = lists:usort(
                  lists:map(fun(_) ->
                      spr_ets_handler:get_one_node('demoservice')
                    end,
                    lists:seq(0,100))),
                [
                    ?_assertEqual([{ok,'demo_1@nohost'}, {ok,'demo_3@nohost'}], Result)
                ]
        end
    }.

get_one_node_invalidapp_test_() ->
    {setup,
        fun () ->
                EtsNodesTable = spr_ets_handler:create_ets_table(),
                State = #state{ets_nodes_table = EtsNodesTable, host_names=['127.0.0.1']},
                spr_ets_handler:do_reload_workers_list(State),
                []
        end,
        fun (_) ->
                remove_ets_table(),
                ok
        end,
        fun (_) ->
                [
                    ?_assertEqual({error, no_node}, spr_ets_handler:get_one_node(invalid_app))
                ]
        end
    }.

get_all_nodes_invalidapp_test_() ->
    {setup,
        fun () ->
                EtsNodesTable = spr_ets_handler:create_ets_table(),
                State = #state{ets_nodes_table = EtsNodesTable, host_names=['127.0.0.1']},
                spr_ets_handler:do_reload_workers_list(State),
                []
        end,
        fun (_) ->
                remove_ets_table(),
                ok
        end,
        fun (_) ->
                [
                    ?_assertEqual({error, no_node}, spr_ets_handler:get_all_nodes(invalid_app))
                ]
        end
    }.

get_one_node_oneservice_twonodes_test_() ->
    {setup,
        fun () ->
                EtsNodesTable = spr_ets_handler:create_ets_table(),
                Service = 'demoservice',
                Node1 = 'demo@127.0.0.1',
                Node2 = 'demo@127.0.0.1',
                NodesRunningService = [{"127.0.0.1", Node1}, {"127.0.0.1", Node2}],
                ets:insert(EtsNodesTable, {Service, NodesRunningService}),
                []
        end,
        fun (_) ->
                remove_ets_table(),
                ok
        end,
        fun (_) ->
                [
                    ?_assertEqual({error, no_node}, spr_ets_handler:get_one_node(invalid_app)),
                    ?_assertEqual({ok,'demo@127.0.0.1'}, spr_ets_handler:get_one_node('demoservice'))
                ]
        end
    }.

get_all_nodes_test_() ->
    {setup,
        fun () ->
                EtsNodesTable = spr_ets_handler:create_ets_table(),
                Service = 'demoservice',
                Node1 = 'demo@127.0.0.1',
                Node2 = 'demo2@127.0.0.1',
                NodesRunningService = [{"127.0.0.1", Node1}, {"127.0.0.1", Node2}],
                ets:insert(EtsNodesTable, {Service, NodesRunningService}),
                []
        end,
        fun (_) ->
                remove_ets_table(),
                ok
        end,
        fun (_) ->
                [
                    ?_assertEqual({error, no_node}, spr_ets_handler:get_one_node(invalid_app)),
                    ?_assertEqual({ok, ['demo@127.0.0.1', 'demo2@127.0.0.1']},
                                  spr_ets_handler:get_all_nodes('demoservice'))
                ]
        end
    }.

get_nodes_applications_crashing_test_() ->
    {setup,
        fun () ->
                ok = meck:new(rpc, [unstick, passthrough]),
                meck:expect(rpc, call,
                            fun
                                ('crashdemo@127.0.0.1', _ , _ ,_) ->
                                    throw(unexpected_crash);
                                (_,_,_,_) ->
                                    meck:passthrough()
                            end),
                []
        end,
        fun(_) -> ok = meck:unload(rpc) end,
        fun (_) ->
                NodeApps = spr_ets_handler:get_nodes_applications(['crashdemo@127.0.0.1']),
                [
                    ?_assertEqual([], NodeApps)
                ]
        end
    }.

get_nodes_applications_no_node_test_() ->
     NodesApplications = [],
     NodeToServices = [],
     ServiceToNodes = [],
     {DictA, DictB} = spr_ets_handler:get_nodes_applications(NodesApplications, []),

     [
        ?_assertEqual(NodeToServices , dict:to_list(DictA)),
        ?_assertEqual(ServiceToNodes , dict:to_list(DictB))
     ].


get_nodes_applications_no_services_test_() ->
     NodesApplications = [{'demo@127.0.0.1', []}],
     ReWorkerNodes = spr_ets_handler:compile_worker_nodes([{<<"">>, ["service"]}]),  % one service

     NodeToServices = [],
     ServiceToNodes = [],
     {DictA, DictB} = spr_ets_handler:get_nodes_applications(NodesApplications, ReWorkerNodes),

     [
        ?_assertEqual(NodeToServices , dict:to_list(DictA)),
        ?_assertEqual(ServiceToNodes , dict:to_list(DictB))
     ].


get_nodes_applications_no_matching_services_test_() ->
     NodesApplications = [{'demo@127.0.0.1', [
            {stdlib,          "ERTS  CXC 138 10",   "1.18"},
            {twig,            "Logger",             "0.2.1"},
            {service_filter,  "Service Filter",     "0.0.1"},
            {service_echo,    "Service Echo",       "0.0.1"}
        ]}],
     ReWorkerNodes = spr_ets_handler:compile_worker_nodes([{<<"">>, ["^undefined"]}]),  % all nodes, undefined wanted

     NodeToServices = [],
     ServiceToNodes = [],
     {DictA, DictB} = spr_ets_handler:get_nodes_applications(NodesApplications, ReWorkerNodes),

     [
        ?_assertEqual(NodeToServices , dict:to_list(DictA)),
        ?_assertEqual(ServiceToNodes , dict:to_list(DictB))
     ].


get_nodes_applications_one_node_test_() ->
     NodesApplications = [{'demo@127.0.0.1', [
            {stdlib,          "ERTS  CXC 138 10",   "1.18"},
            {twig,            "Logger",             "0.2.1"},
            {service_filter,  "Service Filter",     "0.0.1"},
            {service_echo,    "Service Echo",       "0.0.1"}
        ]}],
     ReWorkerNodes = spr_ets_handler:compile_worker_nodes([{<<".*">>,
        ["service_filter", "service_echo"]}]),  % all nodes, service_filter + service_echo wanted

     NodeToServices = [{'demo@127.0.0.1', [service_filter, service_echo]}],
     ServiceToNodes = [
            {service_filter,    ['demo@127.0.0.1']},
            {service_echo,      ['demo@127.0.0.1']}
        ],
     {DictA, DictB} = spr_ets_handler:get_nodes_applications(NodesApplications, ReWorkerNodes),
     [
        ?_assertEqual(NodeToServices , dict:to_list(DictA)),
        ?_assertEqual(ServiceToNodes , dict:to_list(DictB))
     ].


%note that the order of the keys is undetermined, hence the strange assertion comparisons
get_nodes_applications_multiple_node_test_() ->
     NodesApplications = get_example_nodes_applications(),
     ReWorkerNodes = spr_ets_handler:compile_worker_nodes([{<<".*">>,
        ["service_filter", "service_echo", "service_blaat"]}]),

     NodeToServices = [
              {'demo_two@127.0.0.1',     [service_filter, service_blaat]},
              {'demo_one@127.0.0.1',     [service_filter, service_echo]}
          ],
     ServiceToNodes = [
              {service_filter,    ['demo_one@127.0.0.1', 'demo_two@127.0.0.1']},
              {service_blaat,     ['demo_two@127.0.0.1']},
              {service_echo,      ['demo_one@127.0.0.1']}
          ],
     {DictA, DictB} = spr_ets_handler:get_nodes_applications(NodesApplications, ReWorkerNodes),

     [
        ?_assertEqual(NodeToServices , dict:to_list(DictA)),
        ?_assertEqual(ServiceToNodes , dict:to_list(DictB))
     ].


get_nodes_applications_not_requested_host_test_() ->
     NodesApplications = get_example_nodes_applications(),
     ReWorkerNodes = spr_ets_handler:compile_worker_nodes([{<<"demo_three">>, ["service_echo"]}]),
     {DictA, DictB} = spr_ets_handler:get_nodes_applications(NodesApplications, ReWorkerNodes),
     [
        ?_assertEqual([] , dict:to_list(DictA)),
        ?_assertEqual([] , dict:to_list(DictB))
     ].


get_nodes_applications_test_() ->
     Nodenames = [
            'demo_one@127.0.0.1',
            'demo_two@127.0.0.1'
        ],
     [
        ?_assertEqual([] , spr_ets_handler:get_nodes_applications(Nodenames))   %illegal nodes, should not result in {badrpc,}
     ].


get_current_nodes_test_() ->
     {setup,
        fun() ->
            NodesApplications = get_example_nodes_applications(),
            ReWorkerNodesServicesAdapters = spr_ets_handler:compile_worker_nodes([{<<".*">>,
                ["service_filter", "service_echo", "adapter_profilar", "adapter_gamatar"]}]),
            ReWorkerNodesSpapiInterfaces = spr_ets_handler:compile_worker_nodes([{<<".*">>,
                ["spapi_interface_account", "spapi_interface_user"]}]),
            {NodesToWorkers, _} = spr_ets_handler:get_nodes_applications(NodesApplications, ReWorkerNodesServicesAdapters),
            {NodesToInterfaces, _} = spr_ets_handler:get_nodes_applications(NodesApplications, ReWorkerNodesSpapiInterfaces),
            net_kernel:start(['spr_ets_handler_eunit@127.0.0.1', longnames]),   %this is need because we use monitor_node/2
            {NodesToWorkers, NodesToInterfaces}
        end,
        fun (_) ->
            net_kernel:stop()
        end,
        fun ({NodesToWorkers, NodesToInterfaces}) ->
            [
                ?_assertMatch([], spr_ets_handler:get_current_nodes([], [])),
                ?_assertEqual(['demo_one@127.0.0.1','demo_two@127.0.0.1']
                                , spr_ets_handler:get_current_nodes([NodesToWorkers, NodesToInterfaces], [])),
                ?_assertEqual(['demo_one@127.0.0.1','demo_two@127.0.0.1']
                                , spr_ets_handler:get_current_nodes([NodesToWorkers, NodesToInterfaces], ['demo_two@127.0.0.1']))
            ]
        end
    }.

node_disconnection_test_() ->
    {setup,
     fun () ->
            setup_logging(),
            net_kernel:start(['spr_ets_handler_eunit@127.0.0.1', longnames]),
            {ok, Slave1} = slave:start('127.0.0.1', 'spr_ets_handler_eunit_1',
                                       "", no_link, erl),
            rpc:call(Slave1, application, start, [compiler]),
            {ok, Slave2} = slave:start('127.0.0.1', 'spr_ets_handler_eunit_2',
                                       "", no_link, erl),
            {ok, Slave3} = slave:start('127.0.0.1', 'spr_ets_handler_eunit_3',
                                       "", no_link, erl),
            pong = net_adm:ping(Slave1),
            pong = net_adm:ping(Slave2),
            pong = net_adm:ping(Slave3),
            application:load(spapi_router),
            ok = application:set_env(spapi_router, host_names, ['127.0.0.1']),
            ok = application:set_env(spapi_router, workers, [{"^spr_ets_handler_eunit_", ["compiler"]}]),
            ok = spr_app:start(),
            [Slave1, Slave2, Slave3]
        end,
     fun cleanup/1,
     fun ([S1, S2, S3]) ->
            [?_assertEqual([S1], spr_router:list_workers(compiler)),
             % The following assertion proves spapi_router doesn't disconnect from undesired nodes
             ?_assertEqual([S1, S2, S3], nodes())]
        end
    }.

cleanup(Slaves) ->
    lists:foreach(fun slave:stop/1, Slaves),
    net_kernel:stop(),
    ok = application:stop(spapi_router),
    ok = application:unload(spapi_router).


%% Note that this test doesn't test that only the required connections were
%% setup, but it does test that we can correctly select only a subset of nodes.
node_selective_connect_test_() ->
    {setup,
     fun () ->
            setup_logging(),
            net_kernel:start(['spr_ets_handler_eunit@127.0.0.1', longnames]),
            {ok, Slave1} = slave:start('127.0.0.1', 'spr_ets_handler_eunit_1',
                                       "", no_link, erl),
            rpc:call(Slave1, application, start, [compiler]),
            {ok, Slave2_1} = slave:start('127.0.0.1', 'spr_ets_handler_eunit_2_1',
                                       "", no_link, erl),
            rpc:call(Slave2_1, application, start, [compiler]),
            {ok, Slave2_2} = slave:start('127.0.0.1', 'spr_ets_handler_eunit_2_2',
                                       "", no_link, erl),
            rpc:call(Slave2_2, application, start, [compiler]),
            rpc:call(Slave2_2, application, start, [runtime_tools]),
            {ok, Slave3} = slave:start('127.0.0.1', 'spr_ets_handler_eunit_3',
                                       "", no_link, erl),
            pong = net_adm:ping(Slave1),
            pong = net_adm:ping(Slave2_1),
            pong = net_adm:ping(Slave2_2),
            pong = net_adm:ping(Slave3),
            application:load(spapi_router),
            ok = application:set_env(spapi_router, host_names, ['127.0.0.1']),
            ok = application:set_env(spapi_router, workers,
                [{<<"^spr_ets_handler_eunit_2.*">>, ["compiler", "runtime_tools", "kernel"]}]),
            ok = spr_app:start(),
            [Slave1, Slave2_1, Slave2_2, Slave3]
        end,
     fun cleanup/1,
     fun ([_, S21, S22, _]) ->
            [
                ?_assertEqual([S21, S22], spr_router:list_workers(compiler)),
                ?_assertEqual([S22], spr_router:list_workers(runtime_tools)),
                ?_assertEqual([S21, S22], spr_router:list_workers(kernel)),
                ?_assertEqual([], spr_router:list_workers(notstarted))
            ]
        end
    }.

%% Note that this test doesn't test that only the required connections were
%% setup, but it does test that we can correctly select only a subset of nodes.
nonexisting_node_requested_test_() ->
    {setup,
     fun () ->
            setup_logging(),
            net_kernel:start(['spr_ets_handler_eunit@127.0.0.1', longnames]),
            {ok, Slave1} = slave:start('127.0.0.1', 'spr_ets_handler_eunit_1',
                                       "", no_link, erl),
            rpc:call(Slave1, application, start, [compiler]),
            {ok, Slave2_1} = slave:start('127.0.0.1', 'spr_ets_handler_eunit_2_1',
                                       "", no_link, erl),
            rpc:call(Slave2_1, application, start, [compiler]),
            {ok, Slave2_2} = slave:start('127.0.0.1', 'spr_ets_handler_eunit_2_2',
                                       "", no_link, erl),
            rpc:call(Slave2_2, application, start, [compiler]),
            rpc:call(Slave2_2, application, start, [runtime_tools]),
            {ok, Slave3} = slave:start('127.0.0.1', 'spr_ets_handler_eunit_3',
                                       "", no_link, erl),
            pong = net_adm:ping(Slave1),
            pong = net_adm:ping(Slave2_1),
            pong = net_adm:ping(Slave2_2),
            pong = net_adm:ping(Slave3),
            application:load(spapi_router),
            ok = application:set_env(spapi_router, host_names, ['127.0.0.1']),
            ok = application:set_env(spapi_router, workers,
                [{<<"nonexisting_node">>, ["compiler", "runtime_tools", "kernel"]}]),
            ok = spr_app:start(),
            [Slave1, Slave2_1, Slave2_2, Slave3]
        end,
     fun cleanup/1,
     fun (_) ->
            [
                ?_assertEqual([], spr_router:list_workers(compiler)),
                ?_assertEqual([], spr_router:list_workers(runtime_tools)),
                ?_assertEqual([], spr_router:list_workers(kernel)),
                ?_assertEqual([], spr_router:list_workers(notstarted))
            ]
        end
    }.

%% Nodedown : slave 3 goes down, ensure it gets removed correctly.
set_node_down_test_() ->
    {setup,
     fun () ->
            setup_logging(),
            net_kernel:start(['spr_ets_handler_eunit@127.0.0.1', longnames]),
            {ok, Slave1} = slave:start('127.0.0.1', 'spr_ets_handler_eunit_1',
                                       "", no_link, erl),
            rpc:call(Slave1, application, start, [compiler]),
            {ok, Slave2_1} = slave:start('127.0.0.1', 'spr_ets_handler_eunit_2_1',
                                       "", no_link, erl),
            rpc:call(Slave2_1, application, start, [compiler]),
            {ok, Slave2_2} = slave:start('127.0.0.1', 'spr_ets_handler_eunit_2_2',
                                       "", no_link, erl),
            rpc:call(Slave2_2, application, start, [compiler]),
            rpc:call(Slave2_2, application, start, [runtime_tools]),
            {ok, Slave3} = slave:start('127.0.0.1', 'spr_ets_handler_eunit_3',
                                       "", no_link, erl),
            pong = net_adm:ping(Slave1),
            pong = net_adm:ping(Slave2_1),
            pong = net_adm:ping(Slave2_2),
            pong = net_adm:ping(Slave3),
            application:load(spapi_router),
            ok = application:set_env(spapi_router, host_names, ['127.0.0.1']),
            ok = application:set_env(spapi_router, workers,
                [{<<"^spr_ets_handler_eunit_">>, ["compiler", "runtime_tools", "kernel"]}]),
            ok = spr_app:start(),
            [Slave1, Slave2_1, Slave2_2, Slave3]
        end,
     fun cleanup/1,
     fun ([S1, S21, S22, _S3]) ->
            [
                ?_assertEqual(ok, spr_ets_handler:set_node_down('spr_ets_handler_eunit_3@127.0.0.1')),
                ?_assertEqual([S1, S21, S22], spr_router:list_workers(compiler)),
                ?_assertEqual([S22], spr_router:list_workers(runtime_tools)),
                ?_assert(same_elements([S1, S21, S22], spr_router:list_workers(kernel))),
                ?_assertEqual([], spr_router:list_workers(notstarted)),
                ?_assertEqual(ok, spr_ets_handler:set_node_down('not_requested@127.0.0.1'))
            ]
        end
    }.

update_routing_table_test_() ->
    {setup, local,
        fun() ->
            application:set_env(spapi_router, callback_module, ?MODULE),
            EtsDemoTable = ets:new(?DEMO_TABLE, []),
            EtsCallbackDemoTable = ets:new(?DEMO_CALLBACK_TABLE, [set, public, named_table]),
            [EtsDemoTable, EtsCallbackDemoTable]
        end,
        fun ([EtsDemoTable, EtsCallbackDemoTable]) ->
            application:unset_env(spapi_router, callback_module),
            ets:delete(EtsDemoTable),
            ets:delete(EtsCallbackDemoTable)
        end,
        fun ([EtsDemoTable, EtsCallbackDemoTable]) ->
            NodesApplications = get_example_nodes_applications(),
            ReWorkerNodes = spr_ets_handler:compile_worker_nodes([{<<"^demo_">>,
                ["service_filter", "service_echo", "service_blaat"]}]),

            {_, ServicesToNodes} = spr_ets_handler:get_nodes_applications(NodesApplications, ReWorkerNodes),
            CurrentResources = spr_ets_handler:update_routing_table(ServicesToNodes, [],
                                                                    EtsDemoTable),
            ResourcesList=ets:tab2list(EtsDemoTable),
            NewCallbacks = ets:match(EtsCallbackDemoTable, {'$1', new_demo}),
            OldResources = ets:foldl(fun ({K, _}, Acc) -> [K | Acc] end, [], EtsDemoTable),
            NewResources = spr_ets_handler:update_routing_table(
                        dict:store(service_filter, ['demo_two@127.0.0.1'], dict:new()),
                        OldResources, EtsDemoTable),
            LostCallbacks = ets:match(EtsCallbackDemoTable, {'$1', lost_demo}),
            [
                % Resources were there before removal
                ?_assertEqual([service_filter,service_blaat,service_echo],  CurrentResources),
                ?_assertEqual([{"127.0.0.1",'demo_one@127.0.0.1'}, {"127.0.0.1",'demo_two@127.0.0.1'}],
                              proplists:get_value(service_filter, ResourcesList)),
                ?_assertEqual([{"127.0.0.1", 'demo_one@127.0.0.1'}],
                              proplists:get_value(service_echo, ResourcesList)),
                ?_assertEqual([{"127.0.0.1", 'demo_two@127.0.0.1'}],
                              proplists:get_value(service_blaat, ResourcesList)),
                % They are not there anymore
                ?_assertEqual([service_filter], NewResources),
                ?_assertEqual([{service_filter,[{"127.0.0.1",'demo_two@127.0.0.1'}]}],
                              ets:lookup(EtsDemoTable, service_filter)),
                ?_assertEqual([], ets:lookup(EtsDemoTable, service_echo)),
                ?_assertEqual([], ets:lookup(EtsDemoTable, service_blaat)),
                % The callbacks were called when adding the resources
                ?_assertEqual(true, lists:member([{service_filter, 'demo_one@127.0.0.1'}],
                                                 NewCallbacks)),
                ?_assertEqual(true, lists:member([{service_filter, 'demo_two@127.0.0.1'}],
                                                 NewCallbacks)),
                ?_assertEqual(true, lists:member([{service_echo, 'demo_one@127.0.0.1'}],
                                                 NewCallbacks)),
                ?_assertEqual(true, lists:member([{service_blaat, 'demo_two@127.0.0.1'}],
                                                 NewCallbacks)),
                % The callbacks were called when removing the resources
                ?_assertEqual(true, lists:member([{service_filter, 'demo_one@127.0.0.1'}],
                                                 LostCallbacks)),
                ?_assertEqual(false, lists:member([{service_filter, 'demo_two@127.0.0.1'}],
                                                 LostCallbacks)),
                ?_assertEqual(true, lists:member([{service_echo, 'demo_one@127.0.0.1'}],
                                                 LostCallbacks)),
                ?_assertEqual(true, lists:member([{service_blaat, 'demo_two@127.0.0.1'}],
                                                 LostCallbacks))
            ]
        end
    }.



%internal demo data
get_example_nodes_applications() ->
    NodesApplications = [
        {'demo_one@127.0.0.1', [
            {stdlib,          "ERTS  CXC 138 10", "1.18"},
            {twig,            "Logger",           "0.2.1"},
            {service_filter,  "Service Filter",   "0.0.1"},
            {service_echo,    "Service Echo",     "0.0.1"},
            {spapi_interface_user,    "Interface User", "0.0.1"},
            {spapi_interface_account, "Interface Account", "0.0.1"},
            {adapter_profilar,    "Adapter Profilar", "0.0.1"},
            {adapter_gamatar,    "Adapter Gamatar", "0.0.1"}
        ]},
        {'demo_two@127.0.0.1', [
            {stdlib,          "ERTS  CXC 138 10", "1.18"},
            {service_filter,  "Service Filter",   "0.0.1"},
            {service_blaat,   "Service Blaat",    "0.0.1"},
            {spapi_interface_account, "Interface User", "0.0.1"},
            {adapter_profilar,    "Adapter Profilar", "0.0.1"}
        ]}
    ],
    NodesApplications.

get_host_names_test_() ->
    {setup,
        fun() ->
                application:load(spapi_router),
                ok = application:set_env(spapi_router, host_names, ['myname.here.is'])
        end,
        fun(_) -> ok = application:unset_env(spapi_router, host_names) end,
        fun (_) ->
                MyName=spr_ets_handler:get_host_names_config(),
                application:unset_env(spapi_router, host_names),
                DefaultNames=spr_ets_handler:get_host_names_config(),
                [
                    ?_assertEqual(['myname.here.is'], MyName),
                    ?_assertEqual([list_to_atom(net_adm:localhost())], DefaultNames)
                ]
        end}.

get_host_names_empty_list_test_() ->
    {setup,
        fun() ->
                application:load(spapi_router),
                ok = application:set_env(spapi_router, host_names, [])
        end,
        fun(_) -> ok = application:unset_env(spapi_router, host_names) end,
        fun (_) ->
                [
                    ?_assertEqual([list_to_atom(net_adm:localhost())],
                        spr_ets_handler:get_host_names_config())
                ]
        end}.

get_host_names_from_file_test_() ->
    {setup,
        fun() ->
            setup_logging(),
            application:load(spapi_router),
            ok = file:write_file("hosts_sample", "['myname.is.this', 'myname.is.that']."),
            ok = application:set_env(spapi_router, host_names, {file, "hosts_sample"})
        end,
        fun (_) ->
                ok = file:delete("hosts_sample"),
                ok = application:unset_env(spapi_router, host_names)
        end,
        fun (_) ->
                Hosts = spr_ets_handler:get_host_names_config(),
                [?_assertEqual(['myname.is.this', 'myname.is.that'], Hosts)]
    end}.


update_host_names_test_() ->
    {setup,
     fun () ->
            setup_logging(),
            net_kernel:start(['spr_ets_handler_eunit@127.0.0.1', longnames]),
            {ok, Slave1} = slave:start('127.0.0.1', 'spr_ets_handler_eunit_1',
                                       "", no_link, erl),
            rpc:call(Slave1, application, start, [compiler]),
            {ok, Slave2_1} = slave:start('127.0.0.1', 'spr_ets_handler_eunit_2_1',
                                       "", no_link, erl),
            rpc:call(Slave2_1, application, start, [compiler]),
            {ok, Slave2_2} = slave:start('127.0.0.1', 'spr_ets_handler_eunit_2_2',
                                       "", no_link, erl),
            rpc:call(Slave2_2, application, start, [compiler]),
            rpc:call(Slave2_2, application, start, [runtime_tools]),
            {ok, Slave3} = slave:start('127.0.0.1', 'spr_ets_handler_eunit_3',
                                       "", no_link, erl),
            pong = net_adm:ping(Slave1),
            pong = net_adm:ping(Slave2_1),
            pong = net_adm:ping(Slave2_2),
            pong = net_adm:ping(Slave3),
            application:load(spapi_router),
            ok = application:set_env(spapi_router, host_names, ['127.0.0.1']),
            ok = application:set_env(spapi_router, workers,
                [{<<"^spr_ets_handler_eunit_">>, ["compiler", "runtime_tools", "kernel"]}]),
            ok = spr_app:start(),
            [Slave1, Slave2_1, Slave2_2, Slave3]
        end,
     fun cleanup/1,
     fun (_) ->
            [
                % Get from config, baseline
                ?_assertEqual(ok, spr_ets_handler:update_host_names()),
                ?_assertEqual(ok, spr_ets_handler:reload_world_list()),
                ?_assertEqual(['127.0.0.1'], spr_router:list_hosts()),

                % Explicitly only use 127.0.0.1 ; normal baseline
                ?_assertEqual(ok, spr_ets_handler:update_host_names(['127.0.0.1'])),
                ?_assertEqual(ok, spr_ets_handler:reload_world_list()),
                ?_assertEqual(['127.0.0.1'], spr_router:list_hosts()),
                ?_assertEqual({ok, ['spr_ets_handler_eunit_1@127.0.0.1',
                                 'spr_ets_handler_eunit_2_1@127.0.0.1',
                                 'spr_ets_handler_eunit_2_2@127.0.0.1']},
                                 spr_ets_handler:get_all_nodes(compiler)),

                % Adding 127.0.0.2 but there are no nodes there
                ?_assertEqual(ok, spr_ets_handler:update_host_names(['127.0.0.1', '240.0.0.0'])),
                ?_assertEqual(['127.0.0.1', '240.0.0.0'], spr_router:list_hosts()),
                %{timeout, 20, ?_assertEqual(ok, spr_ets_handler:reload_world_list())},
                % ?_assertEqual({ok,['spr_ets_handler_eunit_1@127.0.0.1',
                %                  'spr_ets_handler_eunit_2_1@127.0.0.1',
                %                  'spr_ets_handler_eunit_2_2@127.0.0.1']},
                %                  spr_ets_handler:get_all_nodes(compiler)),

                % With only 127.0.0.2 we should not find any nodes
                ?_assertEqual(ok, spr_ets_handler:update_host_names(['240.0.0.0'])),
                ?_assertEqual(['240.0.0.0'], spr_router:list_hosts())
                %?_assertEqual(ok, spr_ets_handler:reload_world_list())
                % ?_assertEqual({ok,[]}, spr_ets_handler:get_all_nodes(compiler))
            ]
        end
    }.


handle_info_test_() ->
    {setup,
     fun () ->
            setup_logging(),
            net_kernel:start(['spr_ets_handler_eunit@127.0.0.1', longnames]),
            {ok, Slave1} = slave:start('127.0.0.1', 'spr_ets_handler_eunit_1',
                                       "", no_link, erl),
            rpc:call(Slave1, application, start, [kernel]),
            pong = net_adm:ping(Slave1),
            application:load(spapi_router),
            ok = application:set_env(spapi_router, host_names, ['127.0.0.1']),
            ok = application:set_env(spapi_router, workers,
                [{<<"^spr_ets_handler_eunit_">>, ["compiler", "runtime_tools", "kernel"]}]),
            ok = spr_app:start(),
            [Slave1]
        end,
     fun cleanup/1,
     fun (_) ->
            [
                ?_assertMatch(_, whereis(spr_ets_handler) ! update_host_names),
                ?_assertMatch(_, whereis(spr_ets_handler) ! reload_nodes_missing_apps),
                ?_assertMatch(_, whereis(spr_ets_handler) ! reload_workers_list),
                ?_assertMatch(_, whereis(spr_ets_handler) ! reload_world_list),
                ?_assertMatch(_, whereis(spr_ets_handler) ! {nodedown, 'fakenode@127.0.0.3'}),
                ?_assertMatch(_, whereis(spr_ets_handler) ! unhandled),
                ?_assertMatch(Pid when is_pid(Pid), whereis(spr_ets_handler))   %simply ensure it didnt crash
            ]
        end
    }.

%%-------------------------------------------------------------------------
%% Internal functions
%%-------------------------------------------------------------------------

%% ignore is used in resource_cb_test_
new_resource(ignore, _Opts) ->
    {new, ignore};
new_resource(Res, _Opts) ->
    ets:insert(?DEMO_CALLBACK_TABLE, {Res, new_demo}),
    {new, Res}.

lost_resource(ignore, _Opts) ->
    {lost, ignore};
lost_resource(Res, _Opts) ->
    ets:insert(?DEMO_CALLBACK_TABLE, {Res, lost_demo}),
    {lost, Res}.

success(_Key, _Opts) ->
    ok.

failure(_Key, _Opts) ->
    ok.

measure(_, Fun, _Opts) ->
    Fun().

remove_ets_table() ->
    true=ets:delete(?ETS_NODES_TABLE_NAME),
    ok.

setup_logging() ->
    error_logger:tty(false),
    [].

ensure_epmd() ->
    _ = os:cmd("epmd -daemon"),     %% ugly hack to start epmd
    ok.

%%--------------------------------------------------------------------
%% @doc
%% Checks if 2 lists contain the same elements. The result of this function is
%% order independent, but lists can still contain repeated items;
%% that is the reason why sets where not used in the implementation.
%% This should only be used for testing; keep in mind the complexity of the current
%% implementation is O(n2).
-spec same_elements([term()], [term()]) -> boolean().
%% @end
%%--------------------------------------------------------------------
same_elements(L1, L2) ->
    case length(L1) == length(L2) of
        true ->
            lists:all(fun (X) -> lists:member(X, L1) end, L2)
                and lists:all(fun (X) -> lists:member(X, L2) end, L1);
        false ->
            false
    end.
