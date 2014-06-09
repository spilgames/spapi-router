-module(spr_sup).

-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type, StartOpts), {I, {I, start_link, StartOpts}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

%% @doc Start the supervisor tree.
-spec start_link(list()) -> {ok, pid()}.
%% @end
start_link(Config) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [Config]).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

%% @private
%% @doc Initialize the supervisor with spr_ets_handler as only child.
-spec init(list()) ->
    {ok, {
        {one_for_one, 5, 10},
        [{atom(), {atom(), start_link, [term()]}, permanent, 5000, worker, [atom()]}]
    }}.
%% @end
init([Config]) ->
    {ok, {
        {one_for_one, 5, 10},
        [?CHILD(spr_ets_handler, worker, Config)]
    }}.
