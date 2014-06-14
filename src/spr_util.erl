-module(spr_util).


-export([maybe_callback/2, measure/2,
         atom/1, str/1, differences/2, pmap/2, pmap/3,
         parse_error/1]).

maybe_callback(F, Args) ->
    case application:get_env(spapi_router, callback_module) of
        {ok, M} -> apply(M, F, Args ++ [callback_opts()]);
        undefined -> ok
    end.

measure(Key, Fun) ->
    case application:get_env(spapi_router, callback_module) of
        undefined -> Fun();
        {ok, M} -> M:measure(Key, Fun, callback_opts())
    end.


atom(Atom) when is_atom(Atom) ->
    Atom;
atom(Str) when is_list(Str) ->
    list_to_atom(Str);
atom(Bin) when is_binary(Bin) ->
    atom(str(Bin));
atom(Val) ->
    throw({error, {param, {conv, atom, Val}}}).


str(Str) when is_list(Str) ->
    Str;
str(Atom) when is_atom(Atom) ->
    atom_to_list(Atom);
str(Binary) when is_binary(Binary) ->
    unicode:characters_to_list(Binary).


%%--------------------------------------------------------------------
%% @doc
%% Returns the differences between both lists. First element of the
%% returned tuple are elements that are only in the first list
%% second element are the elements that are only in the second list
-spec differences([term()], [term()]) -> {[term()], [term()]}.
%% @end
%%--------------------------------------------------------------------
differences(L1, L2) ->
    S1 = ordsets:from_list(L1),
    S2 = ordsets:from_list(L2),
    Diff1 = ordsets:subtract(S1, S2),
    Diff2 = ordsets:subtract(S2, S1),
    {ordsets:to_list(Diff1), ordsets:to_list(Diff2)}.


%% @doc Performs a lists parallel map. The output is guaranteed to
%%  be ordered as the input. Note that exceptions will be caught
%%  in the started processes, so they will appear in the output.
%%
%%  Timeout is per function call. If one function triggers
%%  a timeout, the next function calls will only wait for 1 ms.
%%  The upper bound for waiting can still be roughly Timeout*length(List)
%%  (if each function returns just before timing out on its turn),
%%  but the expected time the pmap takes is now much closer to Timeout.
%%
%%  If one element triggers the timeout, the whole request can still
%%  succeed, but that element's result will be {error, timeout}. This
%%  needs to be handled in the caller, just like caught errors.
-spec pmap(fun((term()) -> term()), [term()], timeout()) -> [term()].
%% @end
pmap(Fun, List, Timeout) ->
    S=self(),
    TE = process_flag(trap_exit, true),
    Ref = erlang:make_ref(),
    Pids = lists:map(fun(I) ->
        spawn(fun() -> do_f(S, Ref, Fun, I) end)
        end, List),
    Res = gather(Pids,Ref, Timeout, []),
    wait_until_dead(Pids),
    process_flag(trap_exit, TE),
    Res.

%% @equiv pmap(Fun,List, 10000)
-spec pmap(fun((term()) -> term()), [term()]) -> [term()].
%% @end
pmap(Fun,List) ->
    pmap(Fun,List, 10000).


%%--------------------------------------------------------------------
%% @doc
%% Parses error message (for example caught exits) and returns them in
%% uniform format. Useful for logging purposes where you don't want a
%% full stacktrace or logging sensitive arguments.
-spec parse_error(any()) -> {error, {undef | badarith | unknown, any()}}.
%% @end
%%--------------------------------------------------------------------
parse_error({'EXIT',{undef,[{Module,Function,Args,_}|_]}}) ->
    {error, {undef, {Module, Function, [{args, length(Args)}]}}};
parse_error({'EXIT',{badarith,[{Module,Function,_,[_,{line,Line}]}|_]}}) ->
    {error, {badarith, {Module, Function, [{line, Line}]}}};
parse_error(Unknown) ->
    {error, {unknown, Unknown}}.

%% =============================================================================
%% Internal functions
%% =============================================================================

-spec do_f(pid(), reference(), fun((term()) -> term()), term()) -> {pid(), reference(), term()}.
do_f(Parent, Ref, F, I) ->
    Parent ! {self(), Ref, (catch F(I)) }.

-spec gather([pid()], reference(), timeout(), list()) -> [term()].
gather([Pid|T]=L, Ref, Timeout, Acc) ->
    receive
        {Pid, Ref, Ret} -> gather(T, Ref, Timeout, [Ret|Acc]);
        {'EXIT', _, Reason} ->
            _ = [exit(P, Reason) || P <- L],
            wait_until_dead(L),
            exit(Reason)
    after
        Timeout ->
            catch(exit(Pid, timeout)),
            gather(T, Ref, 1, [{error,timeout}|Acc])
    end;
gather([], _, _, Acc) ->
    lists:reverse(Acc).

-spec wait_until_dead([pid()]) -> ok.
wait_until_dead([]) -> ok;
wait_until_dead([H|T]=Pids) ->
    case is_process_alive(H) of
        false ->
            wait_until_dead(T);
        true ->
            timer:sleep(1),
            wait_until_dead(Pids)
    end.

%% @private
%% @doc get callack opts. Returns [[]] (if no opts) or [Option].
callback_opts() ->
    case application:get_env(spapi_router, callback_module_opts) of
        undefined -> [];
        {ok, X} -> X
    end.
