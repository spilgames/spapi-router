-module(spr_util_eunit).

-include_lib("eunit/include/eunit.hrl").

differences_test_() ->
    [
        ?_assertEqual({[], []}, spr_util:differences([a,b,c], [a,b,c])),
        ?_assertEqual({[a], [c]}, spr_util:differences([a,b], [b,c])),
        ?_assertEqual({[], [a,b,c]}, spr_util:differences([], [a,b,c])),
        ?_assertEqual({[a,b,c],[]}, spr_util:differences([a,b,c], []))
    ].

pmap_test_() ->
    [
        ?_assertEqual([1, 2, 3, 4], spr_util:pmap(fun(X) -> X+1 end, [0,1,2,3])),
        %% every even argument will cause a sleep, but the order must still be the same
        ?_assertEqual([ I + 1 || I <- lists:seq(1,100)],
                      spr_util:pmap(
                                    fun(X) -> if
                                                  X rem 2 =:= 0 -> timer:sleep(100);
                                                    true -> ok
                                                end,
                                                X+1 end,
                                    lists:seq(1,100))),
        %% function errors are caught
        ?_assertEqual([{throw, 0}, {throw, 1}], spr_util:pmap(fun(X) -> throw({throw, X}) end, [0,1])),
        %% one timeout does not cause the whole request to fail
        ?_assertEqual([1,2,{error, timeout},{error,timeout},5],
                      spr_util:pmap(
                                    fun(X) -> if
                                                  X =:= 2 -> timer:sleep(100);
                                                  X =:= 3 -> timer:sleep(20);
                                                  X =:= 4 -> timer:sleep(1);
                                                  true -> ok
                                              end,
                                              X+1 end,
                                    [0,1,2,3,4], 15)),
        %% No processes remain alive after timeouts
        ?_test(begin
                PidsBefore = erlang:processes(),
                [{error, timeout}] = spr_util:pmap(
                        fun(_) -> timer:sleep(1000) end, [1], 10),
                PidsAfter = erlang:processes(),
                PossibleRemains = PidsAfter -- PidsBefore,
                ?assertMatch([], [P || P <- PossibleRemains, is_process_alive(P)])
            end),
        %% The total execution time does not deviate too much from the specified timeout
        %% (even when half the spawned processes time out and therefore are killed)
        ?_test(begin
                Processes = 40,
                SimpleError = 0.05,
                WorstCaseError = 0.15,
                Input = lists:seq(1, Processes),
                Timeout=1000,
                % Simple case, only 1 process times out
                SimpleJob = fun (1) -> timer:sleep(Timeout);(_) -> ok end,
                {TimeSpent0, Res0} = timer:tc(fun () -> spr_util:pmap(SimpleJob, Input, Timeout) end),
                ?assertEqual(true, round(TimeSpent0/1000) < ((1 + SimpleError) * Timeout)),
                ?assertEqual(Res0, [{error, timeout} | [ok || _ <- lists:seq(1, Processes-1)]]),
                % Tricky case, all of them do
                Job = fun (_) -> timer:sleep(2*Timeout) end,
                {TimeSpent, Res} = timer:tc(fun () -> spr_util:pmap(Job, Input, Timeout) end),
                ?debugFmt("TimeSpent0=~p, TimeSpent=~p", [TimeSpent0, TimeSpent]),
                ?assertEqual(true, round(TimeSpent/1000) < ((1 + WorstCaseError) * Timeout)),
                ?assertEqual(Res, [{error, timeout} || _ <- Input])
            end),
        %% When the pmap caller dies, the spawned processes are killed as well
        ?_test(begin
                Worker = fun (_) -> timer:sleep(1000) end,
                Controller = fun () -> spr_util:pmap(Worker, lists:seq(1, 5)) end,
                PidsBefore = erlang:processes(),
                Pid = erlang:spawn(Controller),
                exit(Pid, die),
                PidsAfter = erlang:processes(),
                PossibleRemains = PidsAfter -- PidsBefore,
                ?assertMatch([], [P || P <- PossibleRemains, is_process_alive(P)])
            end),
        % Ensure that when a semi-related process exits cleanly we do not kill the workers
        ?_test(begin
                Input = lists:seq(1, 5),
                Worker = fun (Value) -> timer:sleep(1000), Value end,
                erlang:spawn_link(fun() -> timer:sleep(100), exit(self(), normal) end),
                Results = spr_util:pmap(Worker, Input),
                ?assertEqual(Input, Results)
            end),
        % Check that an error in the worker causes the error to be returned
        ?_test(begin
                Input = lists:seq(1, 5),
                Worker = fun (1) -> exit(normal); (Value) -> Value end,
                Results = spr_util:pmap(Worker, Input),
                ?assertEqual([{'EXIT', normal}, 2, 3, 4, 5], Results)
            end),
        %% The trap_exti flag for the caller is kept as it was
        ?_test(begin
                Self=self(),
                {trap_exit, false} = process_info(Self, trap_exit),
                spr_util:pmap(fun (X) -> X end, lists:seq(1, 20)),
                {trap_exit, After1} = process_info(Self, trap_exit),
                ?assertEqual(false, After1),
                process_flag(trap_exit, true),
                spr_util:pmap(fun (X) -> X end, lists:seq(1, 20)),
                {trap_exit, After2} = process_info(Self, trap_exit),
                process_flag(trap_exit, false),
                ?assertEqual(true, After2)
            end)
    ].
