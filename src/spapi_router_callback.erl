%%% @doc Spapi-router callback module.
%%%
%%% If set, all callbacks must be implemented.
%%%
%%% For an example implementation see {@link spapi_router_callback_example}.
-module(spapi_router_callback).

-type opts() :: term().

%% Called when a new resource is detected
-callback new_resource({Service :: atom(), node()}, opts()) -> any().

%% Called when an existing resource is lost (node disconnect, shutdown, etc).
-callback lost_resource({Service :: atom(), node()}, opts()) -> any().

-type log_spec() :: {Service :: atom(), Module :: atom(), Function :: atom()}.
-export_type([log_spec/0]).

%% Function that wraps the synchronous call to do the instrumentation.
%% Must call the function (2nd argument) with zero arguments and return the result.
-callback measure(log_spec(), fun(() -> A), opts()) -> A when A :: term().

%% Called on success/failure of a function call.
-callback success(log_spec(), opts()) -> term().
-callback failure(log_spec(), opts()) -> term().
