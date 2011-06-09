%%%-------------------------------------------------------------------
%% @copyright Geoff Cant
%% @author Geoff Cant <nem@erlang.geek.nz>
%% @version {@vsn}, {@date} {@time}
%% @doc
%% @end
%%%-------------------------------------------------------------------
-module(ngproc_resolver).

-include("ng_log.hrl").

%% API
-export([resolve/3,
         behaviour_info/1]).

%%====================================================================
%% API
%%====================================================================

behaviour_info(callbacks) ->
    [{resolve,3}];
behaviour_info(_) ->
    undefined.

-spec resolve(ngproc:name(), pid(), pid()) -> pid().
resolve(Name, PidA, PidB) ->
    ?INFO("Resolved ~p in favour of ~p. ~p bites the dust.",
          [Name, PidB, PidA]),
    exit(PidA, kill),
    PidB.

%%====================================================================
%% Internal functions
%%====================================================================
