-module(spr_router).

-export([list_workers/0, list_workers/1, list_nodes/0, list_hosts/0,
         call/1, call/4, call/5, call_all/5, invoke/2]).

-ifdef('TEST').
    -export([
        get_call_type/1,
        to_run/1,
        log_call/6,
        invoke_by_type/8
    ]).
-endif.


-define(DEFAULT_TIMEOUT, 4500).             %   integer()
-define(DEFAULT_RESPONSE, optional).        %   optional | required | never

%% This module routes requests to services
%% It periodically scans for running applications and parses
%% Application names and keeps routing information in an ETS table
%% That way other applications (running in the same Erlang VM) can
%% access routing information without going through a gen_server

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% @doc Lists currently available services
%% @end
%%--------------------------------------------------------------------
-spec list_workers() -> [ atom() ].
list_workers() ->
	gen_server:call(spr_ets_handler, list_workers).

%%--------------------------------------------------------------------
%% @doc Lists currently available nodes for a given app
%% @end
%%--------------------------------------------------------------------
-spec list_workers(App::atom()) -> [ atom() ].
list_workers(App) ->
	gen_server:call(spr_ets_handler, {list_workers, App}).

%%--------------------------------------------------------------------
%% @doc Lists current nodes. If no workers are
%%      detected, then this is empty
%% @end
%%--------------------------------------------------------------------
-spec list_nodes() -> [ atom() ].
list_nodes() ->
    gen_server:call(spr_ets_handler, list_nodes).

%%--------------------------------------------------------------------
%% @doc Lists hosts, read from config file
%% @end
%%--------------------------------------------------------------------
-spec list_hosts() -> [ atom() ].
list_hosts() ->
    gen_server:call(spr_ets_handler, list_hosts).


-type call_opts() :: [time_opts() | response_opts() | log_opts() | ignored_opts() ] .
-type call_all_opts() :: [{nodes_matching, re:mp() | iodata() | io:charlist()}
                          | call_opts()] .
-type time_opts() :: {timeout, integer()} | {percentage, non_neg_integer()}. % 'percentage' only applies to 'cast' calls
-type response_opts() :: {response, required | never} .     % optional is deprecated
-type log_opts() :: {log_result, boolean()}.
-type ignored_opts() :: {atom(), any()}.
-type call_error() :: {error, no_response | not_executed |
    backend_timeout | spapi_router_no_node | {spapi_router_badrpc, any()}}.
-type call_spec() :: {atom(), module(), atom(), [any()], call_opts()} .
%%--------------------------------------------------------------------
%% @doc Calls a remote function in a particular service
%%      by default a timeout of 4500 ms is used.
-spec call(atom(), module(), atom(), [any()]) -> any() | call_error() .
%% @end
%%--------------------------------------------------------------------
call(ServiceName, Module, Function, Args) ->
    [H|_] = call([{ServiceName, Module, Function, Args,
        [{timeout, ?DEFAULT_TIMEOUT}, {response, ?DEFAULT_RESPONSE}]}]),
    H.

%%--------------------------------------------------------------------
%% @doc same as call/4 but with call options
-spec call(atom(), module(), atom(), [any()], call_opts()) -> any() | call_error() .
%% @end
%%--------------------------------------------------------------------
call(ServiceName, Module, Function, Args, CallOpts) ->
    [H|_] = call([{ServiceName, Module, Function, Args, CallOpts}]),
    H.

%%--------------------------------------------------------------------
%% @doc
-spec call_all(atom(), module(), atom(), [any()], call_all_opts()) ->
    {uniform, any()} | {non_uniform, [{node(), any()}]}.
%% @end
%%--------------------------------------------------------------------
call_all(ServiceName, Module, Function, Args, CallAllOpts) ->
    case spr_ets_handler:get_all_nodes(ServiceName) of
        {ok, ServiceNodes} ->
            RE = proplists:get_value(nodes_matching, CallAllOpts, ""),
            NodesToUse = [N || N <- ServiceNodes,
                               re:run(spr_util:str(N), RE) /= nomatch],
            case NodesToUse of
                [_|_] ->
                    RequestId=get_request_id(),
                    CallType = get_call_type(CallAllOpts),
                    RequestOneFun = fun (Node) ->
                        invoke_by_type(CallType, ServiceName, Node, Module,
                            Function, Args, RequestId, CallAllOpts)
                    end,
                    Timeout = proplists:get_value(timeout, CallAllOpts, ?DEFAULT_TIMEOUT),
                    spr_util:measure({ServiceName, Module, Function}, fun () ->
                                Results = spr_util:pmap(RequestOneFun,
                                                           NodesToUse, Timeout),
                                SetRes = sets:from_list(Results),
                                case sets:size(SetRes) =< 1 of
                                    true ->
                                        [H|_] = Results,
                                        {uniform, H};
                                    false ->
                                        {non_uniform, lists:zip(NodesToUse, Results)}
                                end
                        end);
                [] ->
                    lager:notice("No node available matching the given regexp: ~p", [RE]),
                    {error, spapi_router_no_node}
            end;
        {error, no_node} ->
            {error, spapi_router_no_node}
    end.

%%--------------------------------------------------------------------
%% @doc same as call/5 but as a list
-spec call([ call_spec() ]) -> [any() | call_error()].
%% @end
%%--------------------------------------------------------------------
call([Call|[]]) when is_tuple(Call)->
    RequestId=get_request_id(),
    [invoke(RequestId, Call)];
call(Calls) when is_list(Calls) ->
    RequestId=get_request_id(),
    MaxTimeout = lists:max([proplists:get_value(timeout, O, ?DEFAULT_TIMEOUT) ||
                            {_, _, _, _, O} <- Calls]),
    spr_util:pmap(
      fun(E) -> erlang:apply(?MODULE, invoke, [RequestId, E]) end,
      Calls,
      MaxTimeout
     ).

%%--------------------------------------------------------------------
%% Internal functions
%%--------------------------------------------------------------------

-spec get_request_id() -> pos_integer().
get_request_id() ->
    {A, B, C} = os:timestamp(),
    A*100000000000 + B*1000000 + C.

-spec invoke(pos_integer(), call_spec()) -> any() | call_error() .
invoke(RequestId, {ServiceName, Module, Function, Args, CallOpts}) ->
    Ret = case spr_ets_handler:get_one_node(ServiceName) of
        {error, no_node} -> {error, spapi_router_no_node};
        {ok, Node} ->
            CallType = get_call_type(CallOpts),
            spr_util:measure({ServiceName, Module, Function}, fun () ->
                        case invoke_by_type(CallType, ServiceName, Node, Module, Function, Args, RequestId, CallOpts) of
                            {badrpc, timeout} -> {error, backend_timeout};
                            {badrpc, Details} ->
                                {error, Parsed} = spr_util:parse_error(Details),
                                {error, {spapi_router_badrpc, Parsed}};
                            Res ->
                                Res
                        end
                end)
	end,
    case Ret of
        {error, _} ->
            spr_util:maybe_callback(failure, [{ServiceName, Module, Function}]);
        _ ->
            spr_util:maybe_callback(success, [{ServiceName, Module, Function}])
    end,
    Ret.

%%--------------------------------------------------------------------
%% @doc  Get the call type
%% @end
%%--------------------------------------------------------------------
-spec get_call_type(call_opts() | call_all_opts()) -> calltype() .
-type calltype() :: {cast, non_neg_integer()} | {call, pos_integer()} .
get_call_type(CallOpts) when is_list(CallOpts) ->
    Timeout = proplists:get_value(timeout, CallOpts, ?DEFAULT_TIMEOUT),
    Percentage=proplists:get_value(percentage, CallOpts, 100),
    NeedResponseFromOpts = proplists:get_value(response, CallOpts, ?DEFAULT_RESPONSE),
    NeedResponse = case NeedResponseFromOpts of
        required    -> true;
        never       -> false;
        optional    -> true     % DEPRECATED
    end,
    if
        NeedResponse =:= false ->
            {cast, Percentage};
        true ->
            {call, Timeout}
    end.

%%--------------------------------------------------------------------
%% @doc  Do the actual rpc call. Bad call_type will result in crash
%% @end
%%--------------------------------------------------------------------
-spec invoke_by_type(calltype(), atom(), node(), module(), atom(), [any()], pos_integer(), call_opts()) ->
    term() | call_error() .
invoke_by_type({cast, Percentage}, _ServiceName, Node, Module, CallFunction, Args, RequestId, CallOpts) ->
    case to_run(Percentage) of
        true ->
            F = fun () ->
                    Res=rpc:call(Node, Module, CallFunction, Args),
                    _ = log_call(RequestId, Node, Module, CallFunction, Res, CallOpts),
                    Res
            end,
            spawn(F),
            {error, no_response};
        false ->
            _ = log_call(RequestId, Node, Module, CallFunction, not_executed, CallOpts),
            {error, not_executed}
    end;
invoke_by_type({call, Timeout}, _ServiceName, Node, Module, CallFunction, Args, RequestId, CallOpts) ->
    Res=rpc:call(Node, Module, CallFunction, Args, Timeout),
    _ = log_call(RequestId, Node, Module, CallFunction, Res, CallOpts),
    case Res of
        {badrpc, timeout} -> {error, backend_timeout};
        {badrpc, Details} ->
            {error, Parsed} = spr_util:parse_error(Details),
            {error, {spapi_router_badrpc, Parsed}};
        Res ->
            Res
    end.

-spec log_call(any(), atom(), atom(), atom(), any(), call_opts()) -> ok.
log_call(RequestId, Node, Module, Function, Res, CallOpts) ->
    case proplists:get_value(log_result, CallOpts, undefined) of
        undefined ->
            ok;
        false ->
            lager:debug("invoke_by_type, cn:''~p'', cm:''~p'', cf:''~p'', i:''~p'', r:''~p''",
                [Node, Module, Function, RequestId, result_not_shown]);
        true ->
            lager:debug("invoke_by_type, cn:''~p'', cm:''~p'', cf:''~p'', i:''~p'', r:''~p''",
                [Node, Module, Function, RequestId, Res])
    end.

-spec to_run(non_neg_integer()) -> boolean().
to_run(100) ->
    true;
to_run(0) ->
    false;
to_run(Percentage) ->
    _ = random:seed(os:timestamp()),
    random:uniform(99) =< Percentage.
