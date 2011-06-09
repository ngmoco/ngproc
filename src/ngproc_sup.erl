
-module(ngproc_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    Manager = {mgr, {ngproc_mgr, start_link, [ngproc, ngproc_resolver]},
               permanent, 5000, worker, [ngproc_mgr]},
    {ok, { {one_for_one, 0, 1}, [Manager]} }.

